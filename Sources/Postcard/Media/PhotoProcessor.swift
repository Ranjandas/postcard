import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A crop selection expressed as fractions (0...1) of the oriented (post-EXIF-rotation) photo,
/// top-left origin with y increasing downward — the same convention as CSS/DOM coordinates, and
/// what the browser-side crop tool naturally works in. `(0, 0, 1, 1)` means "no crop."
struct CropRect: Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isIdentity: Bool { x == 0 && y == 0 && width == 1 && height == 1 }
}

struct PhotoExportParameters: Sendable {
    let sourceURL: URL
    let outputURL: URL
    let cornerRadiusPercent: Double // 0...100
    let canvasSize: CGSize
    let horizontalPaddingPercent: Double // 0...100, of canvas width, applied equally left/right
    let background: BackgroundMode
    let crop: CropRect
    let exposurePercent: Double // -100...100, 0 = no change
    let highlightsPercent: Double // -100...100, 0 = no change (negative recovers/darkens highlights)
    let shadowsPercent: Double // -100...100, 0 = no change
    let brightnessPercent: Double // -100...100, 0 = no change
    let contrastPercent: Double // -100...100, 0 = no change
    let blackPercent: Double // -100...100, 0 = no change (negative crushes, positive lifts blacks)
}

enum PhotoProcessorError: Error {
    case decodeFailed
    case renderFailed
    case encodeFailed
}

/// The still-image counterpart to `VideoProcessor`. Reuses the same "contain, centered, inset by
/// padding" geometry (`fittedRect`/`coveringRect`/`canvasSize`/`cornerRadius`, all defined in
/// `VideoProcessor.swift`) and the same Core Image compositing approach already proven out for
/// the video pipeline's blurred-background option (`BlurredBackgroundCompositor`): a
/// `CIRoundedRectangleGenerator` mask blended with `CIBlendWithMask`, rather than a painted-over
/// shape, so the corner edge anti-aliases correctly. A photo is a single frame, so this needs
/// none of `AVVideoCompositing`'s per-frame plumbing — just one decode, one filter chain, one
/// `CIContext.render` call.
enum PhotoProcessor {
    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    private static let blurRadius: Double = 60

    static func export(_ params: PhotoExportParameters) throws {
        guard let decoded = CIImage(contentsOf: params.sourceURL, options: [.applyOrientationProperty: true]) else {
            throw PhotoProcessorError.decodeFailed
        }

        // CIImage's orientation application, like AVFoundation's preferredTransform, can leave
        // the extent at a non-zero origin — normalize back to (0,0) before further transforms
        // (see the same normalization VideoProcessor.export does for the video path).
        let rawExtent = decoded.extent
        var source = decoded.transformed(by: CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY))

        if !params.crop.isIdentity {
            let imageSize = source.extent.size
            let cropWidthPx = CGFloat(params.crop.width) * imageSize.width
            let cropHeightPx = CGFloat(params.crop.height) * imageSize.height
            let cropXPx = CGFloat(params.crop.x) * imageSize.width
            // The crop rect arrives top-left/y-down (UI convention); CIImage's extent is
            // bottom-left/y-up, so the y offset has to be measured up from the bottom instead.
            let cropYPx = (1 - CGFloat(params.crop.y) - CGFloat(params.crop.height)) * imageSize.height
            let cropRect = CGRect(x: cropXPx, y: cropYPx, width: cropWidthPx, height: cropHeightPx)
            source = source.cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        }

        source = source.adjusted(
            exposurePercent: params.exposurePercent,
            highlightsPercent: params.highlightsPercent,
            shadowsPercent: params.shadowsPercent,
            brightnessPercent: params.brightnessPercent,
            contrastPercent: params.contrastPercent,
            blackPercent: params.blackPercent
        )
        let orientedSize = source.extent.size

        let horizontalPadding = params.canvasSize.width * CGFloat(params.horizontalPaddingPercent / 100)
        let fitted = fittedRect(fitting: orientedSize, in: params.canvasSize, horizontalPadding: horizontalPadding)
        let scale = fitted.width / orientedSize.width

        let foreground = source
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fitted.origin.x, y: fitted.origin.y))

        let canvasRect = CGRect(origin: .zero, size: params.canvasSize)
        let radius = cornerRadius(forPercent: params.cornerRadiusPercent, ofRect: fitted)

        let background: CIImage
        switch params.background {
        case .color(let red, let green, let blue):
            background = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: canvasRect)
        case .blur:
            let coverRect = coveringRect(filling: orientedSize, in: params.canvasSize)
            background = source
                .transformed(by: CGAffineTransform(
                    scaleX: coverRect.width / orientedSize.width, y: coverRect.height / orientedSize.height
                ))
                .transformed(by: CGAffineTransform(translationX: coverRect.origin.x, y: coverRect.origin.y))
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: canvasRect)
        }

        let composed: CIImage
        if radius > 0 {
            guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: fitted),
                "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])?.outputImage else {
                throw PhotoProcessorError.renderFailed
            }
            composed = foreground.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask,
            ])
        } else {
            composed = foreground.composited(over: background)
        }

        guard let cgImage = ciContext.createCGImage(
            composed, from: canvasRect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw PhotoProcessorError.renderFailed
        }

        if FileManager.default.fileExists(atPath: params.outputURL.path) {
            try FileManager.default.removeItem(at: params.outputURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            params.outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw PhotoProcessorError.encodeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoProcessorError.encodeFailed
        }
    }
}

private extension CIImage {
    /// Maps each -100...100 UI slider onto its filter's native range — confirmed empirically via
    /// `CIFilter(name:)!.attributes` rather than assumed from docs (see the ranges below):
    ///   - exposure: `CIExposureAdjust`'s `inputEV` is an unbounded stop count (0 = no change);
    ///     ±100 UI maps to ±4 stops, a wide-but-sane practical range.
    ///   - highlights/shadows: `CIHighlightShadowAdjust`. `inputShadowAmount` is -1...1 (0 = no
    ///     change, positive brightens shadows) — a direct 1:1 map. `inputHighlightAmount` is
    ///     0...1 with 1 = no change and 0 = maximum recovery/darkening, so negative UI percent
    ///     (recover/darken) maps down toward 0 and positive UI percent maps up toward 1 but clamps
    ///     there — the filter has no way to push highlights brighter than "no change," so positive
    ///     values past 0 UI are a no-op. That's a real constraint of the filter, not an oversight.
    ///     (Both mappings — and this whole direction — were confirmed by directly probing
    ///     `applyingFilter` output pixels, not just read off `.attributes`; an earlier version of
    ///     the highlight mapping had the sign backwards and only this pixel-level check caught it.)
    ///   - brightness/contrast: `CIColorControls`, brightness -1...1 additive (0 = no change),
    ///     contrast a multiplier with 1 = no change.
    ///   - black point: no dedicated CI filter parameter for this: implemented as a `CIColorMatrix`
    ///     levels remap. Positive lifts the black floor (fade/haze look, up to 30%); negative
    ///     crushes the shadow end toward 0 (up to the bottom 30% of the range).
    func adjusted(
        exposurePercent: Double,
        highlightsPercent: Double,
        shadowsPercent: Double,
        brightnessPercent: Double,
        contrastPercent: Double,
        blackPercent: Double
    ) -> CIImage {
        var image = self

        if exposurePercent != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: exposurePercent / 100 * 4,
            ])
        }

        if highlightsPercent != 0 || shadowsPercent != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": min(max(1 + highlightsPercent / 100, 0), 1),
                "inputShadowAmount": min(max(shadowsPercent / 100, -1), 1),
            ])
        }

        if brightnessPercent != 0 || contrastPercent != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightnessPercent / 100,
                kCIInputContrastKey: 1 + contrastPercent / 100,
            ])
        }

        if blackPercent != 0 {
            let b = blackPercent / 100
            let threshold = abs(b) * 0.3
            let scale: CGFloat
            let bias: CGFloat
            if b >= 0 {
                // Lift: raise the floor by `threshold`, compressing the rest of the range above it.
                scale = 1 - threshold
                bias = threshold
            } else {
                // Crush: remap [threshold, 1] back to [0, 1], clipping everything below to black.
                scale = 1 / (1 - threshold)
                bias = -threshold / (1 - threshold)
            }
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
        }

        return image
    }
}
