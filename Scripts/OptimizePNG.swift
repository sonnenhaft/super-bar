// Lossless asset build tool; AppKit and macOS zlib only. Never included in the app.
import AppKit
import zlib

func big(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
func chunk(_ kind: String, _ bytes: Data) -> Data {
    let payload = Data(kind.utf8) + bytes
    let checksum = payload.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(payload.count)) }
    return big(UInt32(bytes.count)) + payload + big(UInt32(checksum))
}
func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
}
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let original = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: original), bitmap.bitsPerSample == 8, bitmap.samplesPerPixel == 4,
          !bitmap.isPlanar, !bitmap.bitmapFormat.contains(.alphaFirst), let pixels = bitmap.bitmapData else { continue }
    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh, stride = bitmap.bytesPerRow
    var filtered = Data(capacity: (width * 4 + 1) * height)
    for y in 0..<height {
        var best: [UInt8] = [], bestScore = Int.max
        for filter in 0...4 {
            var row = [UInt8(filter)], score = 0
            row.reserveCapacity(width * 4 + 1)
            for x in 0..<width * 4 {
                let raw = Int(pixels[y * stride + x])
                let a = x >= 4 ? Int(pixels[y * stride + x - 4]) : 0
                let b = y > 0 ? Int(pixels[(y - 1) * stride + x]) : 0
                let c = y > 0 && x >= 4 ? Int(pixels[(y - 1) * stride + x - 4]) : 0
                let prediction = filter == 0 ? 0 : filter == 1 ? a : filter == 2 ? b : filter == 3 ? (a + b) / 2 : paeth(a, b, c)
                let value = UInt8(truncatingIfNeeded: raw - prediction)
                row.append(value); score += abs(Int(Int8(bitPattern: value)))
            }
            if score < bestScore { best = row; bestScore = score }
        }
        filtered.append(contentsOf: best)
    }
    var size = compressBound(uLong(filtered.count)), zipped = Data(count: Int(compressBound(uLong(filtered.count))))
    let status = zipped.withUnsafeMutableBytes { output in filtered.withUnsafeBytes { input in
        compress2(output.bindMemory(to: UInt8.self).baseAddress, &size, input.bindMemory(to: UInt8.self).baseAddress, uLong(filtered.count), Z_BEST_COMPRESSION)
    } }
    guard status == Z_OK else { fatalError("PNG compression failed") }
    zipped.count = Int(size)
    let header = big(UInt32(width)) + big(UInt32(height)) + Data([8,6,0,0,0])
    let result = Data([137,80,78,71,13,10,26,10]) + chunk("IHDR", header) + chunk("IDAT", zipped) + chunk("IEND", Data())
    // Verify every decoded channel before replacing an asset.
    guard let check = NSBitmapImageRep(data: result), check.pixelsWide == width, check.pixelsHigh == height, let verified = check.bitmapData else { fatalError("PNG decode failed") }
    for y in 0..<height { for x in 0..<width * 4 { precondition(pixels[y * stride + x] == verified[y * check.bytesPerRow + x], "PNG pixel changed") } }
    if result.count < original.count { try result.write(to: url, options: .atomic) }
    print("\(url.lastPathComponent): \(original.count) → \(min(result.count, original.count)) bytes")
}
