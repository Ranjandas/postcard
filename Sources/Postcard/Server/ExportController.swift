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

        let radius = min(max(body.cornerRadiusPercent, 0), 100)
        let padding = min(max(body.paddingPercent, 0), 40)
        let ratioWidth = max(body.aspectRatioWidth, 0.01)
        let ratioHeight = max(body.aspectRatioHeight, 0.01)
        let colorComponents = parseHexColor(body.backgroundColorHex)
        let background: BackgroundMode = body.backgroundMode == "blur"
            ? .blur
            : .color(red: colorComponents.red, green: colorComponents.green, blue: colorComponents.blue)
        let outDir = try OutputLocation.ensureOutputDirectory()
        let caption = captionParameters(from: body)

        switch clip.kind {
        case .video(let duration):
            let canvas = canvasSize(ratioWidth: ratioWidth, ratioHeight: ratioHeight)
            let start = max(0, body.trimStart)
            let end = min(duration.seconds, body.trimEnd)
            guard start < end else {
                throw Abort(.badRequest, reason: "Invalid trim range")
            }
            let outURL = OutputLocation.uniqueOutputURL(in: outDir, baseName: clip.originalFilename, extension: "mp4")
            try await VideoProcessor.export(.init(
                sourceURL: clip.sourceURL,
                outputURL: outURL,
                trimStart: CMTime(seconds: start, preferredTimescale: 600),
                trimEnd: CMTime(seconds: end, preferredTimescale: 600),
                cornerRadiusPercent: radius,
                canvasSize: canvas,
                horizontalPaddingPercent: padding,
                background: background,
                caption: caption
            ))
            return ExportResponse(id: id, outputPath: outURL.path)

        case .photo:
            let crop = CropRect(
                x: body.cropX, y: body.cropY,
                width: min(max(body.cropWidth, 0.01), 1), height: min(max(body.cropHeight, 0.01), 1)
            )
            let croppedContentSize = CGSize(
                width: clip.orientedSize.width * crop.width, height: clip.orientedSize.height * crop.height
            )
            let shortSide = nativeShortSide(
                contentSize: croppedContentSize, ratioWidth: ratioWidth, ratioHeight: ratioHeight,
                horizontalPaddingPercent: padding
            )
            let canvas = canvasSize(ratioWidth: ratioWidth, ratioHeight: ratioHeight, shortSide: shortSide)
            let outURL = OutputLocation.uniqueOutputURL(in: outDir, baseName: clip.originalFilename, extension: "jpg")
            try PhotoProcessor.export(.init(
                sourceURL: clip.sourceURL,
                outputURL: outURL,
                cornerRadiusPercent: radius,
                canvasSize: canvas,
                horizontalPaddingPercent: padding,
                background: background,
                crop: crop,
                exposurePercent: body.exposurePercent,
                highlightsPercent: body.highlightsPercent,
                shadowsPercent: body.shadowsPercent,
                brightnessPercent: body.brightnessPercent,
                contrastPercent: body.contrastPercent,
                blackPercent: body.blackPercent,
                caption: caption
            ))
            return ExportResponse(id: id, outputPath: outURL.path)
        }
    }

    /// `nil` when there's no caption text — every downstream render path skips caption
    /// compositing entirely on `nil`, so an unused caption costs nothing.
    private static func captionParameters(from body: ExportRequestBody) -> CaptionParameters? {
        guard !body.captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let anchor: CaptionVerticalAnchor
        switch body.captionAnchor {
        case "top": anchor = .top
        case "middle": anchor = .middle
        default: anchor = .bottom
        }
        return CaptionParameters(
            text: body.captionText,
            fontKey: body.captionFontKey,
            sizePercent: min(max(body.captionSizePercent, 1), 30),
            colorHex: body.captionColorHex,
            backgroundColorHex: body.captionBgColorHex,
            backgroundOpacityPercent: min(max(body.captionBgOpacityPercent, 0), 100),
            anchor: anchor
        )
    }

    /// Parses a `#rrggbb` (or `rrggbb`) string into 0...1 components, falling back to white for
    /// anything malformed rather than failing the export over a bad color value.
    private static func parseHexColor(_ hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return (1, 1, 1)
        }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return (r, g, b)
    }
}
