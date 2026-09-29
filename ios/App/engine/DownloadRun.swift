import Foundation

/// Thread-safe byte counter (aggregated across all connections of one run).
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func reset(_ newValue: Int64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func add(_ delta: Int64) {
        lock.lock()
        value += delta
        lock.unlock()
    }

    var current: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A half-open-free inclusive byte range used by the segment map.
struct ByteRange: Codable, Equatable {
    var start: Int64
    var end: Int64

    var length: Int64 { end - start + 1 }
}

/// IDM-style dynamic file segmentation.
///
/// The un-downloaded part of the file is a shared pool of byte ranges. Every idle
/// connection takes the largest range, sized `remaining / activeConnections`
/// (clamped to 1–16 MiB), so:
/// - fast connections never wait for slow ones (the long tail is bounded by 1 MiB),
/// - as the download progresses the chunks shrink and the tail finishes evenly,
/// - a stalled or failed connection returns its unfinished range to the pool
///   and another connection picks it up.
final class SegmentPool {
    final class Claim {
        let start: Int64
        let end: Int64
        private let lock = NSLock()
        private var _written: Int = 0
        private var _effectiveEnd: Int64

        init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
            self._effectiveEnd = end
        }

        var written: Int {
            get { lock.lock(); defer { lock.unlock() }; return _written }
            set { lock.lock(); _written = newValue; lock.unlock() }
        }

        /// IDM-style slow-connection stealing shrinks this; the tail beyond it
        /// returns to the pool for a faster connection.
        var effectiveEnd: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return _effectiveEnd }
            set { lock.lock(); _effectiveEnd = newValue; lock.unlock() }
        }

        /// Bytes of this claim not yet downloaded.
        var remainingBytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return _effectiveEnd - start - Int64(_written)
        }

        var expectedLength: Int64 { end - start + 1 }
    }

    private let lock = NSLock()
    private let size: Int64
    private var done: [ByteRange]       // merged, sorted, completed byte ranges
    private var unclaimed: [ByteRange]  // ranges nobody is working on
    private var claims: [Claim] = []
    private var claimsByWorker: [Int: Claim?] = [:]
    private var retiredWorkers: Set<Int> = []
    private let minChunk: Int64 = 1 << 20
    private let maxChunk: Int64 = 16 << 20

    init(size: Int64, done: [ByteRange] = []) {
        self.size = size
        self.done = Self.normalize(done)
        self.unclaimed = Self.complement(of: self.done, size: size)
    }

    /// Claims the next chunk of work. Returns nil while the pool is momentarily
    /// empty but other connections may still return ranges. Retired (slow) workers
    /// get nothing: their throughput drags the end game.
    func take(worker: Int, activeWorkers: Int) -> Claim? {
        lock.lock()
        defer { lock.unlock() }
        if retiredWorkers.contains(worker) {
            return nil
        }

        guard let index = unclaimed.indices.max(by: { unclaimed[$0].length < unclaimed[$1].length }) else {
            return nil
        }
        let segment = unclaimed[index]
        let remaining = size - doneBytesLocked() - claimsWritten
        var chunk = max(minChunk, remaining / Int64(max(1, activeWorkers)))
        chunk = min(chunk, maxChunk, segment.length)

        let claim = Claim(start: segment.start, end: segment.start + chunk - 1)
        if segment.start + chunk <= segment.end {
            unclaimed[index] = ByteRange(start: segment.start + chunk, end: segment.end)
        } else {
            unclaimed.remove(at: index)
        }
        claims.append(claim)
        return claim
    }

    /// Merges the written prefix of a claim into the completed map and returns the
    /// rest (up to the claim's current effective end) to the pool. Called on
    /// completion, failure, pause and after a steal.
    func finish(_ worker: Int, _ claim: Claim) {
        let written = claim.written
        let effectiveEnd = claim.effectiveEnd
        claimsByWorker[worker] = nil
        lock.lock()
        defer { lock.unlock() }
        claims.removeAll { $0 === claim }

        if written > 0 {
            mergeIntoDone(ByteRange(start: claim.start, end: claim.start + Int64(written) - 1))
        }
        let restStart = claim.start + Int64(written)
        if restStart <= effectiveEnd {
            unclaimed.append(ByteRange(start: restStart, end: effectiveEnd))
        }
    }

    /// IDM-style slow-connection stealing: shrinks the claim's effective end so the
    /// slow connection keeps only half of what is left; the other half goes back to
    /// the pool. Returns false when there is not enough left to bother.
    func steal(_ claim: Claim) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stealLocked(claim)
    }


    var activeClaims: [Claim] {
        lock.lock()
        defer { lock.unlock() }
        return claims
    }

    var activeClaimsByWorker: [(worker: Int, claim: SegmentPool.Claim)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(worker: Int, claim: SegmentPool.Claim)] = []
        for (worker, claim) in claimsByWorker {
            if let claim {
                result.append((worker, claim))
            }
        }
        return result
    }

    /// Registers which claim a worker is streaming (nil when between chunks).
    func setWorkerClaim(_ worker: Int, _ claim: Claim?) {
        lock.lock()
        defer { lock.unlock() }
        claimsByWorker[worker] = claim
    }

    /// The monitor retires workers measured far below the fastest connection;
    /// at least two connections always stay active.
    func updateWorkerRate(_ worker: Int, rate: Double, fastest: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fastest > 0, rate < fastest * 0.25,
              claimsByWorker.filter { $0.value != nil }.count - retiredWorkers.count > 2 else { return false }
        if retiredWorkers.insert(worker).inserted {
            if let claim = claimsByWorker[worker], let unwrapped = claim {
                stealLocked(unwrapped)
            }
            return true
        }
        return false
    }

    @discardableResult
    private func stealLocked(_ claim: Claim) -> Bool {
        let remaining = claim.remainingBytes
        guard remaining > 512 << 10 else { return false }
        let keep = max(256 << 10, remaining / 2)
        let newEnd = claim.start + Int64(claim.written) + keep - 1
        let oldEnd = claim.effectiveEnd
        guard newEnd < oldEnd else { return false }
        claim.effectiveEnd = newEnd
        unclaimed.append(ByteRange(start: newEnd + 1, end: oldEnd))
        return true
    }

    /// Completed bytes (excluding in-flight claims).
    var doneBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return doneBytesLocked()
    }

    /// Caller must hold `lock`.
    private func doneBytesLocked() -> Int64 {
        done.reduce(0) { $0 + $1.length }
    }

    var isComplete: Bool {
        doneBytes >= size
    }

    var outstandingClaims: Int {
        lock.lock()
        defer { lock.unlock() }
        return claims.count
    }

    /// Completed ranges including the written prefixes of in-flight claims,
    /// ready to persist as a segment map.
    func mapSnapshot(url: String, etag: String?) -> SegmentMap? {
        lock.lock()
        defer { lock.unlock() }
        var ranges = done
        for claim in claims where claim.written > 0 {
            ranges.append(ByteRange(start: claim.start, end: claim.start + Int64(claim.written) - 1))
        }
        return SegmentMap(url: url, size: size, etag: etag, done: Self.normalize(ranges))
    }

    private var claimsWritten: Int64 {
        claims.reduce(0) { $0 + Int64($1.written) }
    }

    private func mergeIntoDone(_ range: ByteRange) {
        done.append(range)
        done = Self.normalize(done)
    }

    /// Sorts and coalesces overlapping or adjacent ranges.
    private static func normalize(_ ranges: [ByteRange]) -> [ByteRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var result: [ByteRange] = []
        for range in sorted {
            guard !result.isEmpty else {
                result.append(range)
                continue
            }
            let last = result[result.count - 1]
            if range.start <= last.end + 1 {
                if range.end > last.end {
                    result[result.count - 1].end = range.end
                }
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// The gaps inside 0..<size that are not covered by `ranges`.
    private static func complement(of ranges: [ByteRange], size: Int64) -> [ByteRange] {
        var gaps: [ByteRange] = []
        var cursor: Int64 = 0
        for range in ranges {
            if range.start > cursor {
                gaps.append(ByteRange(start: cursor, end: range.start - 1))
            }
            cursor = max(cursor, range.end + 1)
        }
        if cursor < size {
            gaps.append(ByteRange(start: cursor, end: size - 1))
        }
        return gaps
    }
}

/// Persisted segment map — the equivalent of IDM's `.idm` part files.
struct SegmentMap: Codable {
    var url: String
    var size: Int64
    var etag: String?
    var done: [ByteRange]
}

/// One task run: dynamic-segment multi-connection download with connection reuse.
///
/// All runs share the service-wide URLSession, so HTTP/1.1 keep-alive connections
/// are reused and HTTP/2 servers multiplex every range over one warm TCP
/// connection — no slow-start penalty per segment, and the pool stays warm
/// across tasks (the same trick IDM's raw-socket pool uses).
actor DownloadRun: TaskRun {
    private let record: TaskRecord
    private let subworkerCount: Int
    private let counter = ByteCounter()
    private let httpSession: URLSession
    private let httpCoordinator: SegmentCoordinator
    private var activeTasks: [Int: URLSessionDataTask] = [:]
    private var probedSize: Int64 = 0
    private var segmentsKnown: Int = 0

    init(record: TaskRecord, subworkerCount: Int, httpSession: URLSession, httpCoordinator: SegmentCoordinator) {
        self.record = record
        self.subworkerCount = subworkerCount
        self.httpSession = httpSession
        self.httpCoordinator = httpCoordinator
    }

    func writtenBytes() -> Int64 {
        counter.current
    }

    func knownSize() -> Int64 {
        probedSize
    }

    func knownSegments() -> Int {
        segmentsKnown
    }

    func stop() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    /// Runs the download. Returns (final size, final file name — may be renumbered
    /// on a name conflict). Re-invoking after a failure resumes from the segment map.
    func execute() async throws -> (size: Int64, name: String) {
        guard let url = URL(string: record.url) else {
            throw DownloadError(message: "Invalid URL")
        }
        let folder = Paths.partFolder(record.taskId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dataURL = folder.appending(path: "data")
        let mapURL = folder.appending(path: "map.json")

        // Load the segment map from a previous run, or probe the server fresh.
        var size: Int64 = 0
        var etag: String?
        var canRange = true
        var pool: SegmentPool?
        let savedMap = SegmentMap.load(from: mapURL)
        if let map = savedMap, map.url == record.url, map.size > 0,
           FileManager.default.fileExists(atPath: dataURL.path) {
            size = map.size
            etag = map.etag
            pool = SegmentPool(size: map.size, done: map.done)
            probedSize = map.size
        } else {
            let probe = try await Self.probe(url)
            size = probe.size
            etag = probe.etag
            canRange = probe.canRange && probe.size > 0
            if canRange {
                pool = SegmentPool(size: probe.size)
            }
            probedSize = probe.size
        }
        if !canRange {
            return try await runSingleStream(folder: folder, url: url)
        }
        guard let pool else {
            throw DownloadError(message: "Invalid server response")
        }
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: dataURL)
        try handle.truncate(atOffset: UInt64(size))
        try? handle.close()

        let workerCount = min(max(subworkerCount, 1), max(1, Int(size / (1 << 20))))
        segmentsKnown = workerCount
        counter.reset(pool.doneBytes)

        // Persist the segment map periodically so a hard kill loses at most a few seconds.
        let persistTask = Task { [mapURL, record] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if let map = pool.mapSnapshot(url: record.url, etag: etag) {
                    map.save(to: mapURL)
                }
            }
        }
        defer { persistTask.cancel() }

        // IDM's slow-connection handling, two layers:
        // 1. steal: a connection far below the fastest hands half of its remaining
        //    range back to the pool every second;
        // 2. retire: persistently slow connections stop receiving work entirely so
        //    the end game is split among fast connections only.
        let stealMonitor = Task {
            var history: [Int: (written: Int, at: ContinuousClock.Instant)] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = ContinuousClock.now
                let pairs = pool.activeClaimsByWorker
                var rates: [Int: Double] = [:]
                for (worker, claim) in pairs {
                    if let previous = history[worker] {
                        let elapsed = now - previous.at
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        if seconds > 0 {
                            rates[worker] = Double(claim.written - previous.written) / seconds
                        }
                    }
                    history[worker] = (claim.written, now)
                }
                guard let fastest = rates.values.max(), fastest > 0 else { continue }
                for (worker, rate) in rates where rate < fastest * 0.25 {
                    if pool.updateWorkerRate(worker, rate: rate, fastest: fastest) {
                        history[worker] = nil
                    }
                }
            }
        }
        defer { stealMonitor.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<workerCount {
                group.addTask { [url] in
                    try await self.workerLoop(worker, pool, self.httpCoordinator, folder, url, etag, workerCount)
                }
            }
            try await group.waitForAll()
        }
        guard pool.isComplete else {
            throw DownloadError(message: "Download incomplete, retry to continue")
        }

        if let map = pool.mapSnapshot(url: record.url, etag: etag) {
            map.save(to: mapURL)
        }
        return try await finalize(folder: folder, dataURL: dataURL, mapURL: mapURL, size: size)
    }

    // MARK: - Workers

    private func workerLoop(_ worker: Int, _ pool: SegmentPool, _ coordinator: SegmentCoordinator,
                            _ folder: URL, _ url: URL, _ etag: String?, _ workerCount: Int) async throws {
        let dataURL = folder.appending(path: "data")
        let handle = try FileHandle(forWritingTo: dataURL)
        defer { try? handle.close() }

        var transientErrors = 0
        while true {
            try Task.checkCancellation()
            guard let claim = pool.take(worker: worker, activeWorkers: workerCount) else {
                if pool.outstandingClaims == 0 {
                    return
                }
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            pool.setWorkerClaim(worker, claim)
            do {
                let complete = try await downloadRange(claim, httpCoordinator, handle, url, etag)
                pool.finish(worker, claim)
                if complete {
                    transientErrors = 0
                } else {
                    // Server closed the connection early: the unfinished part is
                    // back in the pool, count it as a transient failure.
                    transientErrors += 1
                    guard transientErrors <= 5 else {
                        throw DownloadError(message: "Server keeps closing the connection early")
                    }
                }
            } catch {
                pool.finish(worker, claim)
                if Task.isCancelled {
                    throw CancellationError()
                }
                transientErrors += 1
                guard (error as? DownloadError)?.isRetryable == true, transientErrors <= 3 else {
                    throw error
                }
                try? await Task.sleep(for: .seconds(Double(1 << min(transientErrors, 4))))
            }
        }
    }

    /// Streams one claimed byte range into the staged file at its exact offset.
    /// Returns false when the server closed early (partial range).
    private func downloadRange(_ claim: SegmentPool.Claim, _ coordinator: SegmentCoordinator,
                               _ handle: FileHandle, _ url: URL, _ etag: String?) async throws -> Bool {
        let offset = claim.start + Int64(claim.written)
        let endAtRequest = claim.effectiveEnd
        let expected = endAtRequest - offset + 1
        if expected <= 0 {
            return true
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(endAtRequest)", forHTTPHeaderField: "Range")
        // No transparent compression: byte ranges and progress count raw bytes only.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag {
            // Guard against the server-side file changing between sessions.
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let task = httpSession.dataTask(with: request)
        activeTasks[task.taskIdentifier] = task
        defer { activeTasks[task.taskIdentifier] = nil }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    coordinator.register(taskIdentifier: task.taskIdentifier, handle: handle,
                                         startOffset: offset, claim: claim, counter: counter, task: task,
                                         continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            coordinator.abandon(taskIdentifier: task.taskIdentifier)
            throw error
        }
        return Int64(claim.written) >= claim.effectiveEnd - claim.start
    }

    /// Moves the finished staged file into Documents under a unique name.
    private func finalize(folder: URL, dataURL: URL, mapURL: URL, size: Int64) throws -> (size: Int64, name: String) {
        let writeHandle = try FileHandle(forWritingTo: dataURL)
        try? writeHandle.synchronize()
        try? writeHandle.close()

        let category = Category.match(record.name)
        let folderURL = Paths.finalFile("", in: record.relativeFolder).deletingLastPathComponent()
        let finalName = uniqueName(record.name, in: folderURL)
        let destination = Paths.finalFile(finalName, in: record.relativeFolder)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: dataURL, to: destination)
        try FileManager.default.removeItem(at: folder)
        return (size, finalName)
    }

    /// Fallback for servers without byte-range support: one streaming connection.
    private func runSingleStream(folder: URL, url: URL) async throws -> (size: Int64, name: String) {
        let dataURL = folder.appending(path: "data")
        FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dataURL)
        defer { try? handle.close() }
        counter.reset(0)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = httpSession.dataTask(with: request)
        activeTasks[task.taskIdentifier] = task
        defer { activeTasks[task.taskIdentifier] = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                httpCoordinator.registerSingleStream(taskIdentifier: task.taskIdentifier, handle: handle,
                                                 counter: counter, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        let size = fileSize(at: dataURL)
        return try await finalize(folder: folder, dataURL: dataURL,
                                  mapURL: folder.appending(path: "map.json"), size: size)
    }

    private static func probe(_ url: URL) async throws -> (size: Int64, canRange: Bool, etag: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DownloadError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError(message: "Invalid server response")
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        switch http.statusCode {
        case 206:
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            if let total = contentRange.split(separator: "/").last,
               let parsed = Int64(total.trimmingCharacters(in: .whitespaces)), parsed > 0 {
                return (parsed, true, etag)
            }
            return (0, false, etag)
        case 200:
            return (max(0, http.expectedContentLength), false, etag)
        default:
            throw DownloadError.server(http.statusCode, retryAfter: Self.retryAfter(http))
        }
    }

    private static func retryAfter(_ http: HTTPURLResponse) -> Int? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}

extension SegmentMap {
    static func load(from url: URL) -> SegmentMap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SegmentMap.self, from: data)
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// URLSession delegate that streams each connection's bytes into the staged file
/// at the exact offset of its claimed range.
final class SegmentCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskBox {
        let onWrite: @Sendable (Data) throws -> Void
        let expects206: Bool
        var continuation: CheckedContinuation<Void, Error>?
        var failure: Error?
        // Set when this connection cancels itself because a steal shrank its
        // range: the partial data is complete and valid, not a pause.
        var selfCancelled = false

        init(onWrite: @escaping @Sendable (Data) throws -> Void,
             expects206: Bool,
             continuation: CheckedContinuation<Void, Error>) {
            self.onWrite = onWrite
            self.expects206 = expects206
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var boxes: [Int: TaskBox] = [:]

    func register(taskIdentifier: Int, handle: FileHandle, startOffset: Int64,
                  claim: SegmentPool.Claim, counter: ByteCounter, task: URLSessionDataTask,
                  continuation: CheckedContinuation<Void, Error>) {
        registerBox(taskIdentifier: taskIdentifier, expects206: true, continuation: continuation) { [weak claim] data in
            try handle.seek(toFileOffset: UInt64(startOffset + Int64(claim?.written ?? 0)))
            try handle.write(contentsOf: data)
            claim?.written += data.count
            counter.add(Int64(data.count))
            // Steal boundary reached: stop pulling bytes that now belong to
            // another connection and report success with the valid prefix.
            if let claim, startOffset + Int64(claim.written) > claim.effectiveEnd {
                if let box = self.boxFor(taskIdentifier) {
                    box.selfCancelled = true
                }
                task.cancel()
            }
        }
    }

    private func boxFor(_ taskIdentifier: Int) -> TaskBox? {
        lock.lock()
        defer { lock.unlock() }
        return boxes[taskIdentifier]
    }

    func registerSingleStream(taskIdentifier: Int, handle: FileHandle, counter: ByteCounter,
                              continuation: CheckedContinuation<Void, Error>) {
        registerBox(taskIdentifier: taskIdentifier, expects206: false, continuation: continuation) { data in
            try handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
            counter.add(Int64(data.count))
        }
    }

    private func registerBox(taskIdentifier: Int, expects206: Bool,
                             continuation: CheckedContinuation<Void, Error>,
                             onWrite: @escaping @Sendable (Data) throws -> Void) {
        lock.lock()
        boxes[taskIdentifier] = TaskBox(onWrite: onWrite, expects206: expects206, continuation: continuation)
        lock.unlock()
    }

    func abandon(taskIdentifier: Int) {
        if let box = take(taskIdentifier) {
            box.continuation?.resume(throwing: CancellationError())
        }
    }

    private func take(_ taskIdentifier: Int) -> TaskBox? {
        lock.lock()
        defer { lock.unlock() }
        return boxes.removeValue(forKey: taskIdentifier)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let box = boxes[dataTask.taskIdentifier]
        lock.unlock()
        guard let box else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let isQualified = box.expects206 ? status == 206 : (200..<300).contains(status)
        if !isQualified {
            if box.expects206, status == 200 {
                // Server ignored If-Range: the remote file changed, the map is stale.
                box.failure = DownloadError.stale
            } else {
                box.failure = DownloadError.server(status == 0 ? 400 : status)
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let box = boxes[dataTask.taskIdentifier]
        lock.unlock()
        guard let box else { return }
        do {
            try box.onWrite(data)
        } catch {
            box.failure = DownloadError(message: "Write failed: \(error.localizedDescription)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let box = take(task.taskIdentifier) else { return }
        if let failure = box.failure {
            box.continuation?.resume(throwing: failure)
        } else if let error = error as? URLError, error.code == .cancelled, box.selfCancelled {
            box.continuation?.resume()
        } else if let error = error as? URLError, error.code == .cancelled {
            box.continuation?.resume(throwing: CancellationError())
        } else if let error {
            box.continuation?.resume(throwing: DownloadError.network(error))
        } else {
            box.continuation?.resume()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let remaining = Array(boxes.values)
        boxes.removeAll()
        lock.unlock()
        for box in remaining {
            box.continuation?.resume(throwing: error ?? DownloadError(message: "Session invalidated"))
        }
    }
}
