import Foundation
import Darwin

@main struct BluetoothStreamCheck {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--bluetti-helper" {
            // Exercise the same signal and main run loop used by a connected station.
            signal(SIGUSR1, SIG_IGN)
            let request = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            var received = false
            request.setEventHandler { received = true }
            request.resume()
            FileHandle.standardOutput.write(Data("{\"ok\":true,\"n\":1}\n".utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !received && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            guard received else { exit(1) }
            FileHandle.standardOutput.write(Data("{\"ok\":true,\"n\":2}\n".utf8))
            return
        }
        var stream = BluettiSampleStream()
        var values: [Int] = []
        try stream.append(Data("{\"n\":".utf8)) { _, _ in preconditionFailure("Partial sample emitted") }
        try stream.append(Data("1}\n{\"n\":2}\n".utf8)) { _, row in values.append(row["n"] as! Int) }
        precondition(values == [1, 2])

        // A newline must not bypass the cap or reach the consumer.
        let oversized = Data(("{\"value\":\"" + String(repeating: "x", count: BluettiSampleStream.maximumLineBytes) + "\"}\n").utf8)
        for chunks in [[oversized], [Data(oversized.prefix(100)), Data(oversized.dropFirst(100))]] {
            var rejected = false
            var decoder = BluettiSampleStream()
            do {
                for chunk in chunks {
                    try decoder.append(chunk) { _, _ in preconditionFailure("Oversized sample emitted") }
                }
            } catch { rejected = true }
            precondition(rejected)
        }

        // The cap is per sample, not per read; many small lines remain valid.
        var decoder = BluettiSampleStream()
        var count = 0
        try decoder.append(Data(String(repeating: "{\"ok\":true}\n", count: 30_000).utf8)) { _, _ in count += 1 }
        precondition(count == 30_000)

        // A live sample must arrive while the helper's pipe remains open.
        let pipe = Pipe()
        let received = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global().async {
            BluettiPipeCapture().drainSamples(pipe.fileHandleForReading, receive: { row in
                precondition(row["ok"] as? Bool == true)
                received.signal()
            }, invalid: { preconditionFailure("Valid live sample rejected") })
            finished.leave()
        }
        pipe.fileHandleForWriting.write(Data("{\"ok\":true}\n".utf8))
        let delivered = received.wait(timeout: .now() + 2)
        try pipe.fileHandleForWriting.close()
        finished.wait()
        precondition(delivered == .success, "Live sample waited for pipe EOF or a full read buffer")
        let job = CLIJob()
        let samples = DispatchSemaphore(value: 0)
        let completion = DispatchSemaphore(value: 0)
        job.run(executable: URL(fileURLWithPath: CommandLine.arguments[0]), arguments: [], sampleInterval: 120,
                onSample: { _ in samples.signal() }) { result in
            precondition(result.exitCode == 0 && result.error == nil)
            completion.signal()
        }
        precondition(samples.wait(timeout: .now() + 3) == .success)
        precondition(job.requestImmediateRead())
        precondition(samples.wait(timeout: .now() + 3) == .success, "Manual refresh must wake an idle helper")
        precondition(completion.wait(timeout: .now() + 3) == .success)
        precondition(!job.requestImmediateRead(), "An exited helper must not acknowledge a refresh")
        print("Bluetooth stream: bounded live samples, immediate refresh and exited-helper detection verified.")
    }
}
