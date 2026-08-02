import AVFoundation
import CoreGraphics
@preconcurrency import CoreMedia

enum PaletteExtractor {
    /// Samples a handful of frames spread across the clip, buckets their pixels by coarse RGB
    /// quantization, and returns the most prominent, mutually distinct colors as hex strings.
    /// Never throws — palette extraction is a nice-to-have and must not fail an upload.
    static func extractPalette(
        from url: URL, duration: CMTime, sampleCount: Int = 5, paletteSize: Int = 6
    ) async -> [String] {
        guard duration.seconds > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 80, height: 80)

        var buckets: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<sampleCount {
            let time = CMTimeMultiplyByRatio(duration, multiplier: Int32(i + 1), divisor: Int32(sampleCount + 1))
            guard let result = try? await generator.image(at: time) else { continue }
            let cgImage = result.image
            for (r, g, b) in pixelSamples(from: cgImage) {
                // 8 levels per channel (round to nearest 32) keeps the bucket space small
                // while still separating visually distinct colors.
                let qr = (Int(r) / 32) * 32, qg = (Int(g) / 32) * 32, qb = (Int(b) / 32) * 32
                let key = UInt32(qr << 16 | qg << 8 | qb)
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.count += 1
                bucket.r += Int(r)
                bucket.g += Int(g)
                bucket.b += Int(b)
                buckets[key] = bucket
            }
        }
        guard !buckets.isEmpty else { return [] }

        let candidates = buckets.values
            .map { bucket -> (count: Int, r: Int, g: Int, b: Int) in
                (bucket.count, bucket.r / bucket.count, bucket.g / bucket.count, bucket.b / bucket.count)
            }
            .sorted { $0.count > $1.count }

        for minDistance in [60, 40, 20, 0] {
            var selected: [(r: Int, g: Int, b: Int)] = []
            for candidate in candidates {
                let farEnoughFromAll = selected.allSatisfy { existing in
                    let dr = existing.r - candidate.r, dg = existing.g - candidate.g, db = existing.b - candidate.b
                    return (dr * dr + dg * dg + db * db) >= minDistance * minDistance
                }
                if farEnoughFromAll {
                    selected.append((candidate.r, candidate.g, candidate.b))
                }
                if selected.count == paletteSize { break }
            }
            if selected.count == min(paletteSize, candidates.count) {
                return selected.map { hexString(r: $0.r, g: $0.g, b: $0.b) }
            }
        }
        return []
    }

    private static func pixelSamples(from cgImage: CGImage) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return [] }
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &raw, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var samples: [(r: UInt8, g: UInt8, b: UInt8)] = []
        samples.reserveCapacity(width * height)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            samples.append((raw[offset], raw[offset + 1], raw[offset + 2]))
        }
        return samples
    }

    private static func hexString(r: Int, g: Int, b: Int) -> String {
        String(format: "#%02x%02x%02x", r.clamped(0, 255), g.clamped(0, 255), b.clamped(0, 255))
    }
}

private extension Int {
    func clamped(_ lower: Int, _ upper: Int) -> Int { Swift.min(Swift.max(self, lower), upper) }
}
