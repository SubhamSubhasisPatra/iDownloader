import NIOCore

/// Bridges an NIO future into async/await without parking the calling thread.
/// `.get()` blocks a Swift-concurrency worker until the event loop finishes —
/// at peer-wire message rates that starves the whole cooperative pool.
func nioAwait<T>(_ future: EventLoopFuture<T>) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        future.whenComplete { result in
            continuation.resume(with: result)
        }
    }
}
