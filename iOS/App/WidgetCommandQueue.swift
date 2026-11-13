import Foundation

// The synchronous TCL client runs on a dedicated queue. Task.isCancelled on that
// queue does not describe the originating intent, so pass an explicit gate.
final class WidgetCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

final class WidgetCommandQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    init(queue: DispatchQueue = DispatchQueue(label: "com.sonnenhaft.superbar.widget-climate", qos: .userInitiated)) {
        self.queue = queue
    }

    // A new session is created only after a queued command is allowed to start.
    // No command can inherit a previous account's cached authentication session.
    func run<Session, Value: Sendable>(makeSession: @escaping @Sendable () throws -> Session,
                                     operation: @escaping @Sendable (Session, WidgetCommandCancellation) throws -> Value) async throws -> Value {
        let cancellation = WidgetCommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let session = try makeSession()
                        try cancellation.check()
                        let value = try operation(session, cancellation)
                        try cancellation.check()
                        return value
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}
