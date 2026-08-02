import Vapor
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

        if let utType = UTType(filenameExtension: ext), utType.conforms(to: .image) {
            return try await uploadPhoto(id: id, filename: filename, sourceURL: destURL)
        }
        return try await uploadVideo(id: id, filename: filename, sourceURL: destURL)
    }

    private static func uploadVideo(id: String, filename: String, sourceURL: URL) async throws -> UploadResponse {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Abort(.unprocessableEntity, reason: "No video track found")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

        let suggestedColors = await PaletteExtractor.extractPalette(from: sourceURL, duration: duration)

        await ClipStore.shared.register(.init(
            id: id,
            originalFilename: filename,
            sourceURL: sourceURL,
            orientedSize: orientedSize,
            kind: .video(duration: duration)
        ))

        return UploadResponse(
            id: id,
            filename: filename,
            mediaKind: "video",
            durationSeconds: duration.seconds,
            width: Int(orientedSize.width),
            height: Int(orientedSize.height),
            suggestedColors: suggestedColors
        )
    }

    private static func uploadPhoto(id: String, filename: String, sourceURL: URL) async throws -> UploadResponse {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw Abort(.unprocessableEntity, reason: "Could not read image")
        }

        // EXIF orientations 5-8 are the 90°-rotated cases, where width/height swap once the
        // orientation is applied for display — CGImageSourceCopyPropertiesAtIndex reports raw
        // (pre-rotation) pixel dimensions, so this needs to be accounted for explicitly.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientedSize = [5, 6, 7, 8].contains(orientation)
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)

        var suggestedColors: [String] = []
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 80,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) {
            suggestedColors = PaletteExtractor.extractPalette(from: thumbnail)
        }

        await ClipStore.shared.register(.init(
            id: id,
            originalFilename: filename,
            sourceURL: sourceURL,
            orientedSize: orientedSize,
            kind: .photo
        ))

        return UploadResponse(
            id: id,
            filename: filename,
            mediaKind: "photo",
            durationSeconds: nil,
            width: Int(orientedSize.width),
            height: Int(orientedSize.height),
            suggestedColors: suggestedColors
        )
    }
}
