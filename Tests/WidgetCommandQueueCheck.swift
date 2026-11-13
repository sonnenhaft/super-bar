import Foundation

private enum SyntheticFailure: Error { case rejected }
private struct Session: Sendable { let sequence: Int; let account: String }
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var account = "first-account"
    private var created = 0, published = 0, active = 0, peak = 0
    private var reading = false
    func useAccount(_ account: String) { lock.lock(); self.account = account; lock.unlock() }
    func session() -> Session {
        lock.lock(); defer { lock.unlock() }
        created += 1
        return Session(sequence: created, account: account)
    }
    func publish() { lock.lock(); published += 1; lock.unlock() }
    func beginRead() { lock.lock(); reading = true; lock.unlock() }
    var readStarted: Bool { lock.lock(); defer { lock.unlock() }; return reading }
    func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    var counts: (created: Int, published: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }; return (created, published, peak)
    }
}

@main enum WidgetCommandQueueCheck {
    static func expectCancellation(_ task: Task<Int, Error>) async throws {
        do { _ = try await task.value; preconditionFailure("Cancelled command returned success") }
        catch is CancellationError { }
    }
    static func main() async throws {
        // Every invocation observes the account at execution time, not a cached
        // client from the previous command. No credentials or hardware exist here.
        let runner = WidgetCommandQueue(), probe = Probe()
        let first = try await runner.run(makeSession: { probe.session() }) { session, _ in session }
        probe.useAccount("second-account")
        let second = try await runner.run(makeSession: { probe.session() }) { session, _ in session }
        precondition(first.sequence == 1 && second.sequence == 2)
        precondition(first.account == "first-account" && second.account == "second-account")

        let blocked = DispatchQueue(label: "test.widget.blocked")
        blocked.suspend()
        let queuedRunner = WidgetCommandQueue(queue: blocked), queuedProbe = Probe()
        let cancelledBeforeStart = Task.detached {
            try await queuedRunner.run(makeSession: { queuedProbe.session() }) { _, cancellation in
                try cancellation.check(); queuedProbe.publish(); return 1
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelledBeforeStart.cancel()
        blocked.resume()
        try await expectCancellation(cancelledBeforeStart)
        precondition(queuedProbe.counts.created == 0 && queuedProbe.counts.published == 0,
                     "Cancellation while queued must prevent even authentication/session creation")

        let readProbe = Probe(), finishRead = DispatchSemaphore(value: 0)
        let cancelledDuringRead = Task.detached {
            try await runner.run(makeSession: { readProbe.session() }) { _, cancellation in
                readProbe.beginRead()
                precondition(finishRead.wait(timeout: .now() + 2) == .success)
                // Matches ControlSession's gate after the fresh shadow read,
                // immediately before the publishing operation.
                try cancellation.check()
                readProbe.publish()
                return 1
            }
        }
        for _ in 0..<500 {
            if readProbe.readStarted { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(readProbe.readStarted)
        cancelledDuringRead.cancel()
        finishRead.signal()
        try await expectCancellation(cancelledDuringRead)
        precondition(readProbe.counts.published == 0, "A cancelled fresh read must never progress to a write")

        do {
            let _: Int = try await runner.run(makeSession: { () -> Session in throw SyntheticFailure.rejected }) { _, _ in
                preconditionFailure("Failed authentication created a command")
            }
            preconditionFailure("Factory failure was swallowed")
        } catch SyntheticFailure.rejected { }

        let serialProbe = Probe()
        let count = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await runner.run(makeSession: { serialProbe.session() }) { session, _ in
                        serialProbe.enter(); defer { serialProbe.leave() }
                        Thread.sleep(forTimeInterval: 0.002)
                        return session.sequence
                    }
                }
            }
            var count = 0
            for try await _ in group { count += 1 }
            return count
        }
        precondition(count == 10 && serialProbe.counts.created == 10 && serialProbe.counts.peak == 1)
        print("Widget command queue: cancellation before execution/publish, fresh account sessions and serialized recovery passed; no device requests.")
    }
}
