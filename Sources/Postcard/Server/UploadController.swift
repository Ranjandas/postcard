import Vapor
import AVFoundation
import Foundation

enum UploadController {
    static func upload(_ req: Request) async throws -> UploadResponse {
        let form = try req.content.decode(UploadForm.self)
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Postcard", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = URL(fileURLWithPath: form.file.filename).pathExtension
        let destURL = dir.appendingPathComponent("source.\(ext.isEmpty ? "mov" : ext)")
        let data = Data(buffer: form.file.data)
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

        await ClipStore.shared.register(.init(
            id: id,
            originalFilename: form.file.filename,
            sourceURL: destURL,
            duration: duration,
            orientedSize: orientedSize
        ))

        return UploadResponse(
            id: id,
            filename: form.file.filename,
            durationSeconds: duration.seconds,
            width: Int(orientedSize.width),
            height: Int(orientedSize.height)
        )
    }
}
