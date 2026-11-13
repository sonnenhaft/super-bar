import Foundation

@main struct BluetoothStreamCheck {
    static func main() throws {
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
        print("Bluetooth stream: partial samples, per-line bounds and oversized newline bypass verified.")
    }
}
