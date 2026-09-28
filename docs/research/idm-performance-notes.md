# What makes Internet Download Manager fast — binary-level research notes

Research-only, non-commercial, for the open-source community. Method: static
analysis of the official public trial installer (idman643build11.exe, PE32,
built 2026-09-23). No code was copied, no license checks were touched, and no
DRM was circumvented — only algorithmic ideas were extracted, which is what
this project re-implements natively.

## 1. Unpacking

The installer is a small PE launcher (110 KB, MSVC 9.0) with a 12.4 MB custom
overlay. The overlay is a sequence of entries whose payload is a zlib stream
(`78 DA`); a scan-and-inflate pass recovers 191 files: the main binary, browser
bridge DLLs (x86 / x64 / ARM64), language files, bitmaps, certificates.

The download engine is a single 6.2 MB 32-bit GUI binary (`idman.exe`,
MFC/ATL-era C++). Analysis used import tables (`rabin2 -i`) and string tables.

## 2. Binary findings

### 2.1 The transport is raw winsock, not WinInet

`idman.exe` imports `ws2_32.dll` (`connect`, `send`, `recv`, `select`,
`gethostbyname`, `ioctlsocket`) and `wininet.dll` — but WinInet is used only
for URL cracking and cookies (`InternetCrackUrl*`, `InternetGetCookie*`).
`HttpSendRequest`/`InternetOpenUrl` are absent.

IDM writes HTTP by hand. The strings table contains the request templates:

```
%s %s HTTP/1.1
Connection: Keep-Alive
&bytes=%I64d-%I64d          (Range header construction, 64-bit)
Authorization: Basic %s
Authorization: Digest username="%s", realm="%s", nonce="%s", uri="%s", ...
CONNECT %s:%ld HTTP/1.1     (proxy tunneling)
```

Consequences: IDM is not limited by WinInet's per-host connection limits or
handle semantics, controls every byte of every request, and owns its own
connection pool.

### 2.2 TLS is its own statically-linked OpenSSL

```
Cannot init openssl, res=%ld, lastError=%ld
Openssl handshake ok
ossl_err=%ld, reason=%ld
SSL_CTX_new / SSL_CTX_free / SSL_CIPHER_get_name
SSL_CTX_set_alpn_protos
```

So HTTPS runs over raw sockets with an embedded OpenSSL. The only request-line
template is `HTTP/1.1` — despite ALPN support, there is no HTTP/2 request
path. This is an h1.1 keep-alive pipeline.

### 2.3 Stall recovery is graded and narrated

```
Connection %d, downloaded %I64d.
Connection restarted because of timeout (1)
Connection restarted because of timeout (2)
Connection failed, restarting...
Connection is restarted...
Connection has been closed by the server.
```

Each connection has byte accounting; timeouts trigger graded restarts — the
connection is re-established and its unfinished range is re-fetched.

### 2.4 Configuration surface

`MaxConnectionsNumber` (registry, `HKCU\Software\DownloadManager`), with MFC
dialog classes `CMaxConnNumbers` / `CAddMaxConnDlg`. Dial-up-era connectivity
checks (`RasEnumConnectionsA`, `InternetGetConnectedState`). HLS support has
its own parser (`CMediaSegment@CM3UParser`, `Segment-Count`,
`Segment-Durations-Ms`, `SegmentURL`).

### 2.5 What is NOT there

- No `Retry-After` / `429` handling strings — rate-limit responses are treated
  as generic restarts.
- No HTTP/2 multiplexing.
- No mirror/multi-source logic visible in the main binary strings.

## 3. Synthesis: why IDM is hard to beat on Windows

1. Raw-socket pool: no OS HTTP stack limits; full header and timing control.
2. Keep-alive reuse: segments reuse warm connections — no TCP slow-start or
   TLS handshake per range. This is the single biggest throughput trick.
3. Dynamic file segmentation (documented by Tonec; visible as the per-range
   download accounting and restart logic): the un-downloaded region is a pool;
   connections take the largest remaining slice; slow/stalled connections
   return their slice.
4. A segment map on disk (`.idm` files) making downloads resumable at byte
   granularity across sessions and crashes.
5. Two decades of Windows-specific tuning around the above.

## 4. Mapping to iDownloader

### 4.1 iOS / iPadOS / Mac Catalyst (Swift engine)

| IDM technique | iDownloader implementation |
|---|---|
| Raw-socket HTTP/1.1 pool | Shared `URLSession` across all runs (system connection pool, warm across tasks) |
| Keep-alive reuse | Same pool; plus **HTTP/2 multiplexing** on modern servers — every range rides one warm TCP connection, which h1.1-only IDM cannot do |
| Dynamic file segmentation | `SegmentPool`: shared pool of ranges, chunk = `remaining / activeConnections` clamped 1–16 MiB, largest-first |
| Stall restarts | Request timeout (30 s) returns the unfinished range to the pool; another connection picks it up |
| `.idm` segment map | `map.json` per task: completed ranges persisted every 3 s (sparse preallocated `data` file) |
| Restart on failure | Automatic retries with exponential backoff honoring `Retry-After` (IDM lacks this); `If-Range`/ETag guards resume correctness |

### 4.2 Desktop & Android (Python engine, `features/http_pack/task.py`)

The Python engine closes the same gap this file describes: it used to build and
close a fresh `wreq` client for every range request attempt, paying a TCP +
TLS handshake and slow-start on every retry and every work steal — the exact
cost §3 item 2 names as IDM's biggest throughput trick. One client per step
run is now shared by the probe and all subworkers.

| IDM technique | iDownloader implementation |
|---|---|
| Raw-socket pool | One pooled `wreq` Client per step run, shared by probe + all subworkers; idle connections survive between ranges, retries and steals. HTTP/2 multiplexing comes free on modern servers — h1.1-only IDM cannot do this |
| Keep-alive reuse | A fully-read body returns its connection to the pool automatically; `Response.close()` force-discards the connection, so it runs only on error paths (verified empirically against a local server). The probe reads its 1-byte `bytes=0-0` body to completion, donating a warm connection to the first range |
| Dynamic file segmentation | Static initial split; a finished worker splits the slowest worker's remaining tail; `_autoSpeedUp` adds workers while speed stays stable. Approximates the pool; the Swift engine (4.1) implements it natively |
| Stall restarts | 30 s read timeout per stream, then infinite 5 s retries resuming at the exact byte offset |
| `.idm` segment map | `{output}.ghd`: 24 bytes per subworker, rewritten every 1 s by the supervisor |
| Restart on failure | Permanent-status detection, single-stream degradation on 200-for-range, `Retry-After`-aware outer backoff (ahead of IDM per §2.5) |

Verified by `tests/test_http_subworker.py::TestConnectionReuse`: a run with
probe + initial ranges + a post-steal range completes on fewer TCP
connections than range requests.

### 4.3 Slow-connection stealing and retirement (v5.2)

The pool-level design of §4.1 still let one slow connection hold a large
in-flight range until the end (the "long tail" only shrank via chunk sizing).
Two IDM-grade mechanisms complete the picture, both in `SegmentPool`:

1. **Stealing** — a monitor samples every connection's rate once per second.
   Any connection below 25% of the fastest one hands half of its remaining
   range back to the pool (cooldown 2 s, floor 512 KiB); the coordinator
   self-cancels the connection's request at the stolen boundary and reports
   the valid prefix as complete.
2. **Retirement** — a connection that stays below the threshold stops
   receiving new work entirely (at least two connections stay active), so the
   end game is split among fast connections only.

Benchmark (48 MiB file, 8 connections, localhost server with per-connection
rate caps; median of runs; throughput as measured through the full engine
stack including disk writes):

| Scenario | fixed 8-way split (pre-v5.1) | dynamic + steal + retire |
|---|---|---|
| Uniform connections (4 MiB/s each) | 4.14 s (11.6 MiB/s) | **3.24 s (14.8 MiB/s)** |
| Two stragglers at 0.5 MiB/s | 13.35 s (3.6 MiB/s) | **7.86 s (6.1 MiB/s)** |

The straggler gain is bounded by the harness: the Python test server itself
cannot push 4 MiB/s per connection under the GIL, so both engines are
server-limited in the uniform case. The relative gap in the straggler case
matches the theory: fixed split ties the tail to the slowest connection's
remaining range, while steal+retire hands that range to faster connections.

## 5. Reproducing the analysis

```sh
curl -LO https://download.internetdownloadmanager.com/idman643build11.exe
7zz l idman.exe                                   # PE overview (launcher stub)
python3 - <<'EOF'                                 # carve overlay
import struct
data = open("idman.exe","rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
coff = pe + 4
n = struct.unpack_from("<H", data, coff+2)[0]
optsz = struct.unpack_from("<H", data, coff+16)[0]
sec = coff + 20 + optsz
end = 0
for i in range(n):
    s = sec + i*40
    rs, rp = struct.unpack_from("<II", data, s+16)
    if rs: end = max(end, rp+rs)
open("overlay.bin","wb").write(data[end:])
EOF
# then scan overlay.bin for zlib streams (78 01/9c/da) and inflate
```

Binaries never leave the research context; nothing derived from the binary is
included in this repository except the algorithmic descriptions above.
