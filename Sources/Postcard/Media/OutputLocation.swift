import Foundation

enum OutputLocation {
    static func ensureOutputDirectory() throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = movies.appendingPathComponent("Postcard Output", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func uniqueOutputURL(in dir: URL, baseName: String, extension ext: String = "mp4") -> URL {
        let stem = (baseName as NSString).deletingPathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(4))
        return dir.appendingPathComponent("\(stem)-\(stamp)-\(suffix).\(ext)")
    }
}
