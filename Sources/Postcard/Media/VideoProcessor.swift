import AVFoundation
import CoreGraphics
import QuartzCore

struct ExportParameters: Sendable {
    let sourceURL: URL
    let outputURL: URL
    let trimStart: CMTime
    let trimEnd: CMTime
    let cornerRadiusPercent: Double // 0...100
    let canvasSize: CGSize // e.g. 1080x1350
    let horizontalPaddingPercent: Double // 0...100, of canvas width, applied equally left/right
}

enum VideoProcessorError: Error {
    case noVideoTrack
    case compositionTrackCreationFailed
    case exportSessionCreationFailed
}

/// Computes the "contain" fit of `size` inside `bounds`, centered. `horizontalPadding` (in
/// points, applied equally on both sides) shrinks the width available to fit into, while
/// centering still happens against the full `bounds` width — so the video ends up with at
/// least that much margin on each side, more if its own aspect ratio already requires it.
func fittedRect(fitting size: CGSize, in bounds: CGSize, horizontalPadding: CGFloat = 0) -> CGRect {
    let availableWidth = max(bounds.width - horizontalPadding * 2, 1)
    let scale = min(availableWidth / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
        x: (bounds.width - fitted.width) / 2,
        y: (bounds.height - fitted.height) / 2,
        width: fitted.width,
        height: fitted.height
    )
}

/// Canvas pixel dimensions for a given aspect ratio, holding the shorter side at `shortSide`
/// and rounding the other side to an even number (required for yuv420p encoding).
func canvasSize(ratioWidth: Double, ratioHeight: Double, shortSide: CGFloat = 1080) -> CGSize {
    func evenified(_ value: CGFloat) -> CGFloat {
        let rounded = Int(value.rounded())
        return CGFloat(rounded % 2 == 0 ? rounded : rounded + 1)
    }
    if ratioWidth <= ratioHeight {
        return CGSize(width: shortSide, height: evenified(shortSide * CGFloat(ratioHeight / ratioWidth)))
    } else {
        return CGSize(width: evenified(shortSide * CGFloat(ratioWidth / ratioHeight)), height: shortSide)
    }
}

/// Corner radius in points for a given `percent` (0...100) of a rect's short side.
/// 100% yields a fully rounded short edge (radius == half the short side).
func cornerRadius(forPercent percent: Double, ofRect rect: CGRect) -> CGFloat {
    let shortSide = min(rect.width, rect.height)
    let clamped = min(max(percent, 0), 100)
    return (shortSide / 2) * CGFloat(clamped / 100)
}

enum VideoProcessor {
    static func export(_ params: ExportParameters) async throws {
        let asset = AVURLAsset(url: params.sourceURL)

        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessorError.noVideoTrack
        }
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)

        // 1) Trimmed composition (video + optional audio).
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoProcessorError.compositionTrackCreationFailed
        }

        let timeRange = CMTimeRange(start: params.trimStart, end: params.trimEnd)
        try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        compVideoTrack.preferredTransform = preferredTransform

        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        }

        // 2) Oriented (post-rotation) size of the source video. `preferredTransform` rotates
        // around (0,0), which can leave the resulting rect at a negative origin, so normalize
        // it back to (0,0) before composing further transforms.
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let normalize = CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)

        // 3) "Contain" fit of the oriented video inside the fixed canvas, centered, inset by
        // the requested horizontal padding.
        let horizontalPadding = params.canvasSize.width * CGFloat(params.horizontalPaddingPercent / 100)
        let fittedVideoRect = fittedRect(fitting: orientedSize, in: params.canvasSize, horizontalPadding: horizontalPadding)
        let scale = fittedVideoRect.width / orientedSize.width

        // 4) Video composition: renderSize is what actually determines the output pixel
        // dimensions (a CALayer's `frame` size does NOT), so it must be the canvas size, and the
        // layer-instruction transform must itself place/scale the decoded frame within it —
        // rotate to orient, normalize to (0,0), scale to fit, then translate into the fitted rect.
        let finalTransform = preferredTransform
            .concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: fittedVideoRect.origin.x, y: fittedVideoRect.origin.y))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = params.canvasSize
        let fps = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30.0
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: compVideoTrack.timeRange.duration)
        instruction.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // 5) Rounded corners via a true alpha mask (not a painted-over shape): a white
        // background layer sits behind the video layer, and the video layer's `.mask` clips it
        // to a rounded rect matching `fittedVideoRect`. Core Animation's mask compositing
        // anti-aliases this edge properly; painting a flat vector shape directly onto the
        // decoded frame (the earlier approach) left a visible hard seam once H.264 compressed
        // across it.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: params.canvasSize)
        parentLayer.isGeometryFlipped = true

        let backgroundLayer = CALayer()
        backgroundLayer.frame = parentLayer.bounds
        backgroundLayer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        parentLayer.addSublayer(backgroundLayer)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        videoLayer.allowsEdgeAntialiasing = true
        parentLayer.addSublayer(videoLayer)

        let radius = cornerRadius(forPercent: params.cornerRadiusPercent, ofRect: fittedVideoRect)
        if radius > 0 {
            let maskLayer = CAShapeLayer()
            maskLayer.frame = parentLayer.bounds
            maskLayer.path = CGPath(
                roundedRect: fittedVideoRect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            maskLayer.fillColor = CGColor(gray: 1, alpha: 1)
            maskLayer.allowsEdgeAntialiasing = true
            videoLayer.mask = maskLayer
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        // 6) Export (hardware-accelerated H.264 encode via VideoToolbox).
        guard let exportSession = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoProcessorError.exportSessionCreationFailed
        }
        exportSession.videoComposition = videoComposition

        if FileManager.default.fileExists(atPath: params.outputURL.path) {
            try FileManager.default.removeItem(at: params.outputURL)
        }
        try await exportSession.export(to: params.outputURL, as: .mp4)
    }
}
