import Vapor
import AVFoundation
import Foundation

enum UploadController {
    /// Uploads are sent as a raw binary body (not `multipart/form-data`) with the filename in the
    /// `X-Filename` header, percent-encoded. multipart-kit's `MultipartParser` splits the body
    /// into a new chunk (and callback) at every byte matching the boundary's leading byte (`\r`),
    /// which occurs roughly every 256 bytes in binary video data — turning a single-digit-MB/s
    /// operation into hundreds of thousands of tiny buffer-copy callbacks and multi-second
    /// uploads even on localhost, confirmed empirically via timing instrumentation (~30s of a
    /// ~31s upload spent solely in `req.content.decode`). Reading the raw collected body instead
    /// skips that parser entirely.
    static func upload(_ req: Request) async throws -> UploadResponse {
        guard let encodedFilename = req.headers.first(name: "X-Filename"),
              let filename = encodedFilename.removingPercentEncoding else {
            throw Abort(.badRequest, reason: "Missing X-Filename header")
        }
        guard var buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing request body")
        }
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Postcard", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = URL(fileURLWithPath: filename).pathExtension
        let destURL = dir.appendingPathComponent("source.\(ext.isEmpty ? "mov" : ext)")
        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
        try data.write(to: destURL)

        let asset = AVURLAsset(url: destURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Abort(.unprocessableEntity, reason: "No video track found")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

        let suggestedColors = await PaletteExtractor.extractPalette(from: destURL, duration: duration)

        await ClipStore.shared.register(.init(
            id: id,
            originalFilename: filename,
            sourceURL: destURL,
            duration: duration,
            orientedSize: orientedSize
        ))

        return UploadResponse(
            id: id,
            filename: filename,
            durationSeconds: duration.seconds,
            width: Int(orientedSize.width),
            height: Int(orientedSize.height),
            suggestedColors: suggestedColors
        )
    }
}
