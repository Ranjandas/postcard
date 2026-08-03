import AppKit
import CoreImage
import CoreText
import Metal
import QuartzCore

enum CaptionVerticalAnchor: String, Sendable {
    case top, middle, bottom
}

struct CaptionParameters: Sendable {
    let text: String
    let fontKey: String
    let sizePercent: Double // % of canvas short side
    let colorHex: String
    let backgroundColorHex: String
    let backgroundOpacityPercent: Double // 0...100; 0 doubles as "no pill" — no separate toggle
    let anchor: CaptionVerticalAnchor
}

/// The whitelist of bundled fonts a client may request by key — never trust an arbitrary
/// client-supplied string for an `NSFont(name:)` lookup.
enum CaptionFonts {
    private static let postScriptNames: [String: String] = [
        "pacifico": "Pacifico-Regular",
        "caveat": "Caveat-Regular",
        "playfair": "PlayfairDisplay-Regular",
        "bebasneue": "BebasNeue-Regular",
        "montserrat": "Montserrat-Regular",
    ]

    static func postScriptName(for key: String) -> String {
        postScriptNames[key] ?? postScriptNames["montserrat"]!
    }

    /// Registers every bundled `Public/fonts/*.ttf` in-process (not installed system-wide, and
    /// gone once the process exits) so `NSFont(name:)`/`CATextLayer` can find them by PostScript
    /// name. Must run once before the first export; called from `AppDelegate.startServer()`.
    static func registerBundledFonts() {
        guard let fontsDir = Bundle.module.resourceURL?.appendingPathComponent("Public/fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("Postcard: failed to register font \(url.lastPathComponent): \(String(describing: error?.takeUnretainedValue()))")
            }
        }
    }
}

/// Renders the caption text as either a canvas-sized transparent `CIImage` overlay (for the
/// Core-Image-based photo and blurred-video-background paths) or a small `CALayer` group (for
/// the solid-color video path, which composites through `AVVideoCompositionCoreAnimationTool`
/// instead) — the same split the codebase already has for corner rounding, applied here for the
/// same reason (see `VideoProcessor.swift`).
///
/// Both entry points share one geometry contract: `captionBandRect` divides the canvas into three
/// vertical thirds (top/middle/bottom), inset by a fixed margin, in the same top-left/y-down
/// convention `CropRect` already uses elsewhere in this codebase. The solid-color video path's
/// `parentLayer` is `isGeometryFlipped = true` (already top-left/y-down), so `CALayer` frames use
/// this rect directly with no conversion. The raster path gets the same convention for free by
/// drawing into a `flipped: true` `NSGraphicsContext` — matching how a normal image's "top" ends
/// up at the *high* end of `CIImage.extent` once wrapped, the same relationship `PhotoProcessor`
/// already relies on for crop rects (see its `cropYPx` comment).
enum CaptionRenderer {
    private static let marginPercent: Double = 6

    static func captionBandRect(anchor: CaptionVerticalAnchor, canvasSize: CGSize) -> CGRect {
        let margin = min(canvasSize.width, canvasSize.height) * CGFloat(marginPercent / 100)
        let bandHeight = max((canvasSize.height - margin * 2) / 3, 1)
        let width = max(canvasSize.width - margin * 2, 1)
        let index: CGFloat
        switch anchor {
        case .top: index = 0
        case .middle: index = 1
        case .bottom: index = 2
        }
        return CGRect(x: margin, y: margin + index * bandHeight, width: width, height: bandHeight)
    }

    /// The actual (wrapped, measured) text rect within `band`, aligned per `anchor` — the band
    /// itself is a full third of the canvas, but the text block within it should hug whichever
    /// edge (or center) the anchor names rather than stretch to fill the whole third.
    private static func textRect(for attrString: NSAttributedString, band: CGRect, anchor: CaptionVerticalAnchor) -> CGRect {
        let measured = attrString.boundingRect(
            with: CGSize(width: band.width, height: band.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(measured.height, band.height)
        switch anchor {
        case .top:
            return CGRect(x: band.minX, y: band.minY, width: band.width, height: height)
        case .middle:
            return CGRect(x: band.minX, y: band.minY + (band.height - height) / 2, width: band.width, height: height)
        case .bottom:
            return CGRect(x: band.minX, y: band.maxY - height, width: band.width, height: height)
        }
    }

    private static func attributedString(_ params: CaptionParameters, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont(name: CaptionFonts.postScriptName(for: params.fontKey), size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: params.text, attributes: [
            .font: font,
            .foregroundColor: NSColor(hex: params.colorHex) ?? .black,
            .paragraphStyle: paragraph,
        ])
    }

    /// Photo export + video blurred-background path (per-frame Core Image compositing, but the
    /// caption is static so this is called once and reused for every frame).
    ///
    /// Drives Core Text directly against the raw `CGContext` rather than going through
    /// `NSGraphicsContext(cgContext:flipped:true)` + `NSAttributedString.draw(in:)` — that
    /// combination was tried first and, verified empirically (rendering actual pixels, per this
    /// codebase's established practice for exactly this class of bug — see `PhotoProcessor`'s own
    /// comment on the highlights-sign bug), draws glyphs upside-down when the graphics context
    /// isn't backed by a real (flipped) `NSView`. `CTFrameDraw` has no such ambiguity: it always
    /// draws upright text into whatever path you give it, in the `CGContext`'s native
    /// bottom-left/y-up space — so `textRect` (computed in top-left/y-down terms, matching
    /// `CropRect` elsewhere) is converted with the same explicit y-flip formula `PhotoProcessor`
    /// already uses for crop rects, rather than relying on a context "flipped" flag.
    static func rasterize(_ params: CaptionParameters, canvasSize: CGSize) -> CIImage? {
        let fontSize = min(canvasSize.width, canvasSize.height) * CGFloat(params.sizePercent / 100)
        let attrString = attributedString(params, fontSize: fontSize)
        let band = captionBandRect(anchor: params.anchor, canvasSize: canvasSize)
        let rectTopLeft = textRect(for: attrString, band: band, anchor: params.anchor)
        let rect = CGRect(
            x: rectTopLeft.minX,
            y: canvasSize.height - rectTopLeft.minY - rectTopLeft.height,
            width: rectTopLeft.width,
            height: rectTopLeft.height
        )

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        if params.backgroundOpacityPercent > 0 {
            let padding = pillPadding(fontSize: fontSize)
            let pillRect = rect.insetBy(dx: -padding, dy: -padding * 0.6)
            let color = (NSColor(hex: params.backgroundColorHex) ?? .black)
                .withAlphaComponent(CGFloat(params.backgroundOpacityPercent / 100))
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: padding, cornerHeight: padding, transform: nil))
            ctx.fillPath()
        } else {
            let shadow = legibilityShadow(fontSize: fontSize)
            ctx.setShadow(
                offset: CGSize(width: 0, height: -fontSize * 0.04),
                blur: shadow.shadowBlurRadius,
                color: (shadow.shadowColor ?? .black).cgColor
            )
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attrString.length), path, nil)
        CTFrameDraw(frame, ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    /// Video solid-color-background path. A `CATextLayer` was tried first (matching the pattern
    /// this path already uses for corner rounding — a real Core Animation primitive rather than a
    /// raster); verified empirically (per this codebase's established practice — see this file's
    /// `rasterize` comment and `PhotoProcessor`'s highlights-sign bug), it renders completely
    /// *blank* when composited offline via `AVVideoCompositionCoreAnimationTool` — `CATextLayer`
    /// needs a live display pass export never gives it, unlike `CAShapeLayer`'s `path`/`fillColor`
    /// (used for the rounded-corner mask) which render synchronously with no such requirement.
    /// So this instead reuses the same raster `rasterize()` produces for the photo and
    /// blurred-video paths, handed to Core Animation as a plain image layer. `isGeometryFlipped =
    /// false` on that one layer cancels `parentLayer`'s own flip for just this subtree, so the
    /// (CG-native, unflipped) rasterized image displays right-side up.
    static func makeCaptionLayer(_ params: CaptionParameters, canvasSize: CGSize) -> CALayer? {
        guard let overlay = rasterize(params, canvasSize: canvasSize),
              let cgImage = ciContext.createCGImage(overlay, from: CGRect(origin: .zero, size: canvasSize))
        else { return nil }

        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: canvasSize)
        layer.isGeometryFlipped = false
        layer.contents = cgImage
        return layer
    }

    private static func pillPadding(fontSize: CGFloat) -> CGFloat {
        fontSize * 0.4
    }

    private static func legibilityShadow(fontSize: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = fontSize * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: -fontSize * 0.04)
        return shadow
    }
}

private extension NSColor {
    /// Parses a `#rrggbb` (or `rrggbb`) string, returning `nil` for anything malformed rather
    /// than throwing — matches `ExportController.parseHexColor`'s "never fail export over a bad
    /// color value" convention, just as an `NSColor` instead of raw components.
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
