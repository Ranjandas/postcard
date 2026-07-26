import Vapor
import CoreMedia
import CoreGraphics

enum ExportController {
    static func export(_ req: Request) async throws -> ExportResponse {
        let id = try req.parameters.require("id")
        let body = try req.content.decode(ExportRequestBody.self)
        guard let clip = await ClipStore.shared.clip(id: id) else {
            throw Abort(.notFound)
        }

        let start = max(0, body.trimStart)
        let end = min(clip.duration.seconds, body.trimEnd)
        guard start < end else {
            throw Abort(.badRequest, reason: "Invalid trim range")
        }
        let radius = min(max(body.cornerRadiusPercent, 0), 100)
        let padding = min(max(body.paddingPercent, 0), 40)
        let ratioWidth = max(body.aspectRatioWidth, 0.01)
        let ratioHeight = max(body.aspectRatioHeight, 0.01)

        let outDir = try OutputLocation.ensureOutputDirectory()
        let outURL = OutputLocation.uniqueOutputURL(in: outDir, baseName: clip.originalFilename)

        try await VideoProcessor.export(.init(
            sourceURL: clip.sourceURL,
            outputURL: outURL,
            trimStart: CMTime(seconds: start, preferredTimescale: 600),
            trimEnd: CMTime(seconds: end, preferredTimescale: 600),
            cornerRadiusPercent: radius,
            canvasSize: canvasSize(ratioWidth: ratioWidth, ratioHeight: ratioHeight),
            horizontalPaddingPercent: padding
        ))

        return ExportResponse(id: id, outputPath: outURL.path)
    }
}
