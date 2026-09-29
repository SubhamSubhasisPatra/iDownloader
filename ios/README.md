# iDownloader for iOS / iPadOS / Mac

A native SwiftUI download manager for iPhone, iPad and Apple Silicon Mac (Mac Catalyst).
The desktop and Android apps share a Python engine (Chaquopy) that cannot run on iOS,
so this folder re-implements the core natively in Swift:

- **Dynamic file segmentation** — IDM-style: the un-downloaded part of the file is a
  shared pool of byte ranges; every idle connection takes the largest slice, sized
  `remaining / active connections` (clamped 1–16 MiB). Fast connections never wait
  for slow ones, and the tail is bounded by 1 MiB.
- **Connection reuse** — all connections of a run share one URLSession, so HTTP/1.1
  keep-alive connections are reused and HTTP/2 servers multiplex every range over a
  single warm TCP connection (no slow-start penalty per segment).
- **Stall recovery** — a connection that stalls (request timeout) or fails returns its
  unfinished range to the pool for the next connection.
- **Segment map persistence** — a `map.json` (equivalent of IDM's `.idm` part files)
  records completed ranges every 3 seconds; resume and automatic retries continue
  exactly where the bytes stopped.
- **Automatic retries** — 429 / 408 / 5xx and transient network errors retry with
  exponential backoff, honoring `Retry-After`; `If-Range` guards against the remote
  file changing between sessions.
- **BitTorrent** (magnet + .torrent) based on [swift-torrent](https://github.com/warppipe/swift-torrent)
  (pure Swift, BEP-3/5/9/10/11/15: DHT, UDP/HTTP trackers, metadata exchange, PEX).
  **Vendored** at `Vendor/SwiftTorrent` (upstream revision `79ab342`) with local patches:
  - per-peer request pipeline depth 5 → 32 (main download-throughput fix on high-RTT links)
  - DHT `get_peers` loop wired into each torrent (peers no longer come from trackers alone)
  - BEP-11 ut_pex peer exchange (discover peers from connected peers)
  - extended handshake sent on every torrent, not just magnets
  - `removeTorrent(deleteFiles: true)` deletes only that torrent's files, not the whole save root
  - **v5.2.0 engine overhaul** — fixes that made torrents actually download:
    peer messages no longer dropped when they beat connection registration (the
    stall-at-0 bug); extension support detected via a handshake callback (NIO
    decoder copies had eaten it, so magnets never resolved); inbound `.request`
    upload serving + listener socket (the app can now seed and accept peers);
    ut_metadata routed by payload type, not guessed ids; NIO futures bridged
    without `.get()` thread blocking; TCP_NODELAY + 4 MiB socket buffers.
    Speed ceilings removed: fills request across pieces until the pipeline is
    full; piece buffers preallocated with per-block dedupe (no COW copies);
    endgame mode with a 250 ms re-fire cooldown; one-request-per-generation
    guard (blocks are never re-requested while in flight — kills duplicate
    request storms); rate-limit knob now enforced; live download/upload rates
    reported; trackers announced in parallel; DHT re-lookup 90 s → 45 s.
    Verified by loopback swarm tests: two seeders + leecher complete
    byte-exact, magnet resolves metadata over a real connection.
- **GitHub acceleration** — 21 proxy sites plus auto site racing (first response wins).
- Categories (Videos / Music / Documents / Compressed / Programs / APKs / Images) with
  optional category subfolders, native sidebar, multi-column table on wide screens,
  compact rows on iPhone, search, Properties, QuickLook, rename.

## Building

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen). SwiftTorrent is
vendored, so only swift-nio / swift-crypto / swift-nio-extras come from the network on first
build.

```sh
cd ios
xcodegen generate          # generates iDownloader.xcodeproj
```

**Simulator**

```sh
xcodebuild -project iDownloader.xcodeproj -scheme iDownloader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**Unsigned IPA** (for Sideloadly / AltStore)

```sh
xcodebuild -project iDownloader.xcodeproj -scheme iDownloader -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData build
mkdir -p build/Payload && cp -R build/DerivedData/Build/Products/Release-iphoneos/iDownloader.app build/Payload/
(cd build && zip -qry iDownloader.ipa Payload) && mv build/iDownloader.ipa dist/
```

**Mac (Catalyst)**

```sh
xcodebuild -project iDownloader.xcodeproj -scheme iDownloader -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO -derivedDataPath build/Catalyst build
codesign --force --deep --sign - build/Catalyst/Build/Products/Release-maccatalyst/iDownloader.app
(cd build/Catalyst/Build/Products/Release-maccatalyst && zip -qry dist/iDownloader-mac.zip iDownloader.app)
```

The Mac bundle is ad-hoc signed; on first launch right-click → Open (or run
`xattr -cr iDownloader.app`) to pass Gatekeeper.

## Layout

- `App/engine/` — TaskService (single entry point of the task workflow), DownloadRun
  (dynamic-segment HTTP engine), TorrentRun + TorrentEngine (BitTorrent session),
  GitHubProxy (site racing), Category (extension → category → subfolder), TaskRecord
  (persistence model, backward compatible with older records)
- `App/view/` — TasksPage (sidebar + filters), TaskListView (table / compact rows,
  search, footer), TaskRow, TaskPropertiesView + QuickLookView, AddSheet, SettingsPage

## Data locations on device

- Finished files: `Documents/<category subfolder>/<name>` (visible in the Files app)
- HTTP staging + segment map: `Application Support/TaskFiles/<taskId>/` (`data`, `map.json`)
- BitTorrent staging: `Application Support/BTFiles/<taskId>/`; archived `.torrent`
  files in `Application Support/Torrents/`
- Task records: `Application Support/tasks.json`

## Known limitations

- Downloads run while the app is alive (idle-timer is disabled during activity);
  true background continuation is a future step
- BitTorrent resume re-adds the torrent (piece-level resume data persistence is a
  future step); BT throughput depends on the swarm
- HTTP downloads are not rate-limited; the speed limit setting applies to BitTorrent only
- Rename is disabled while a task is running; name conflicts keep both files
  (`name(1).ext`)
