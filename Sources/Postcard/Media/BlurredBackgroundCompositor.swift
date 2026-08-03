import AVFoundation
import CoreImage
import CoreGraphics
@preconcurrency import CoreMedia
import Metal

/// A single, whole-duration instruction carrying the extra per-export geometry a stock
/// `AVMutableVideoCompositionInstruction` can't hold, so `BlurredBackgroundCompositor` has
/// everything it needs to reproduce the same "contain, centered, rounded" placement the
/// solid-color path applies (see `VideoProcessor.export`), plus a blurred "cover" fill behind it.
final class BlurredBackgroundInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let foregroundTransform: CGAffineTransform
    let backgroundTransform: CGAffineTransform
    let fittedVideoRect: CGRect
    let cornerRadius: CGFloat
    let canvasSize: CGSize
    // Rasterized once (the caption is static across frames), then composited into every frame —
    // see `VideoProcessor.export`'s `.blur` branch.
    let captionOverlay: CIImage?

    init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        foregroundTransform: CGAffineTransform,
        backgroundTransform: CGAffineTransform,
        fittedVideoRect: CGRect,
        cornerRadius: CGFloat,
        canvasSize: CGSize,
        captionOverlay: CIImage?
    ) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.foregroundTransform = foregroundTransform
        self.backgroundTransform = backgroundTransform
        self.fittedVideoRect = fittedVideoRect
        self.cornerRadius = cornerRadius
        self.canvasSize = canvasSize
        self.captionOverlay = captionOverlay
    }
}

/// Renders a blurred, canvas-filling copy of the source frame behind the same sharp, rounded
/// video the solid-color path produces. Unlike corner rounding (a real `CALayer.mask`), this
/// can't be done as a Core Animation trick — a flat `CALayer` has no way to show live, filtered
/// video content — so it's done as direct pixel compositing via Core Image, driven from the raw
/// decoded frame `AVFoundation` hands this compositor per `AVAsynchronousVideoCompositionRequest`.
///
/// Both the blurred background and the sharp foreground are derived from that *same* single
/// frame (no second composition track needed): the background gets a "cover" transform + Gaussian
/// blur, the foreground gets the identical transform the solid-color path uses, and a
/// `CIRoundedRectangleGenerator` mask (built directly in Core Image, not rasterized via
/// `CGContext`, so it can't drift out of the coordinate space the transforms already operate in)
/// blends them together.
final class BlurredBackgroundCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    private let blurRadius: Double = 60

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? BlurredBackgroundInstruction,
              let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID),
              let outputBuffer = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: VideoProcessorError.compositingFailed)
            return
        }

        let source = CIImage(cvPixelBuffer: sourceBuffer)
        let canvasRect = CGRect(origin: .zero, size: instruction.canvasSize)

        // Clamp edges to infinite before blurring so CIGaussianBlur doesn't sample transparent
        // pixels past the (already canvas-covering) frame boundary, which would otherwise leave a
        // faint dark fringe around the edges once cropped back to the canvas.
        let background = source
            .transformed(by: instruction.backgroundTransform)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: canvasRect)

        let foreground = source.transformed(by: instruction.foregroundTransform)

        let composed: CIImage
        if instruction.cornerRadius > 0 {
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: instruction.fittedVideoRect),
                "inputRadius": instruction.cornerRadius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])?.outputImage
            if let mask {
                composed = foreground.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: background,
                    kCIInputMaskImageKey: mask,
                ])
            } else {
                composed = foreground.composited(over: background)
            }
        } else {
            composed = foreground.composited(over: background)
        }

        var final = composed
        if let overlay = instruction.captionOverlay {
            final = overlay.composited(over: composed)
        }

        ciContext.render(final, to: outputBuffer, bounds: canvasRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: outputBuffer)
    }
}
