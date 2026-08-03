# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Postcard is a macOS menu bar app. It runs a local Vapor web server in-process and serves a
browser UI at `http://127.0.0.1:8420`. You drag short video clips or photos onto the page.
Video clips get trimmed; photos get cropped and tonally adjusted (exposure, highlights, shadows,
brightness, contrast, black point) in a large Lightroom/Photomator-style editor. Both share the
same "postcard" framing controls — aspect ratio, corner roundedness, padding, background (white/
custom color/blurred) — and export centered on the canvas, scaled to fit, corners rounded, using
hardware-accelerated AVFoundation/VideoToolbox encoding for video and Core Image for photos.
Output goes to `~/Movies/Postcard Output/`.

## Environment constraint (important)

Only Xcode Command Line Tools are installed — there is no `xcodebuild`, and `swift test` does not
work (neither the `Testing` nor `XCTest` module is wired up in this toolchain). Everything is
built via Swift Package Manager. Do not add a test target expecting `swift test` to work in this
environment; verify logic changes empirically instead (e.g. a throwaway `swift script.swift`, or
driving the running server with `curl` + `ffprobe`/`ffmpeg`, as has been done throughout
development).

## Commands

- `swift build` — compile check.
- `swift run` — launch the menu bar app for development (status item, no Dock icon, auto-opens
  the browser to `http://127.0.0.1:8420/`).
- `./Scripts/build-app.sh` — release build, then hand-assembles `Postcard.app` (no `xcodebuild`
  available to do this). Copies the binary, `Resources/Info.plist`, and every SwiftPM-generated
  `*.bundle` (the app's own `Public/` assets plus dependency privacy-manifest bundles) into
  `Postcard.app/Contents/{MacOS,Resources}`, then ad-hoc codesigns (`codesign --sign -`).
  **Must** use `swift build --show-bin-path` (or `-L` with `find`) to locate `.build/release` —
  it's a symlink, and plain `find .build/release` silently returns nothing on this platform's
  `find`, which was a real bug caught during development.
- `open Postcard.app` — run the packaged app.
- Restarting during development: `pkill -f "Postcard.app/Contents/MacOS/Postcard"` doesn't
  reliably work — Vapor's `ServeCommand` installs its own `SIGTERM`/`SIGINT` handlers that
  resolve a promise nothing awaits (since we call `app.startup()`, not `app.execute()`), so the
  default terminate-on-SIGTERM behavior is disabled. Use `kill -KILL <pid>` instead, or quit via
  the app's own menu bar item (which goes through `NSApplication.terminate`, a different, working
  path).

## Architecture

### Process model

`main.swift` boots a plain `NSApplication` with `.setActivationPolicy(.accessory)` (no Dock icon
— set programmatically, not just via `LSUIElement` in Info.plist, because `LSUIElement` only
takes effect when launched through LaunchServices, not via `swift run`). `AppDelegate` is
`@MainActor` and owns both the `NSStatusItem` (Open / Reveal Output Folder / Quit menu) and the
embedded Vapor `Application`, which is started in a `Task` from `applicationDidFinishLaunching`.
`app.startup()` (not `execute()`) is used deliberately — it binds the listen socket and returns,
letting AppKit's run loop keep driving the main thread; `execute()` would additionally block
awaiting shutdown.

### Request flow

`Server/Configure.swift` wires: `FileMiddleware` serving `Public/` (dev via `swift run` and
packaged `.app` both resolve it through `Bundle.module`), then five JSON/binary routes:

- `POST /api/upload` (`UploadController`) — takes the raw media bytes as the request body (not
  `multipart/form-data`), with the filename percent-encoded in an `X-Filename` header, then saves
  it to a per-clip temp dir. Classifies by `UTType(filenameExtension:).conforms(to: .image)` and
  branches: video probes duration/dimensions with `AVURLAsset`'s async `load(...)` API (throws if
  no video track); photo reads dimensions via `CGImageSourceCopyPropertiesAtIndex` (metadata-only,
  no full decode), correcting for EXIF orientations 5-8 which swap width/height. Both branches
  register the clip in `ClipStore` and extract a suggested color palette. Deliberately *not*
  multipart: multipart-kit's `MultipartParser` restarts its chunk scan at every byte matching the
  boundary's leading byte (`\r`), which occurs roughly every 256 bytes in binary video data, so an
  80-90MB clip turned into ~300K tiny `onBody`/`writeBuffer` callbacks and a ~30s upload even over
  localhost — confirmed by timing-instrumenting each step (`decode` alone was ~29s of a ~31s
  upload; disk write, AVFoundation probing, and palette extraction combined were ~0.1s). Sending
  the file as a raw body instead drops the same 95MB upload to ~1.2s.
- `GET /api/media/:id` (`MediaController`) — `req.fileio.asyncStreamFile(at:)`, which handles
  HTTP Range requests, needed for `<video>` scrubbing in the browser (and works unchanged for
  photo byte-streaming).
- `POST /api/export/:id` (`ExportController`) — decodes corner radius %, aspect ratio, padding %,
  and background from the request body (shared by both media kinds), clamps them, then switches
  on `clip.kind`: video also decodes trim range and calls `VideoProcessor.export`; photo also
  decodes crop rect + the six tonal adjustment percentages and calls `PhotoProcessor.export`.
- `DELETE /api/clip/:id` (`ClipController`) — removes the clip from `ClipStore` and deletes its
  temp dir; kind-agnostic.
- `POST /api/reveal-output` (`RevealController`) — hops to `@MainActor` to call
  `NSWorkspace.activateFileViewerSelecting`.

`ClipStore` (`Media/ClipStore.swift`) is an `actor` holding only `Sendable` value types (`URL`,
`CGSize`, `String`, and a `MediaKind` enum — `.video(duration: CMTime)` or `.photo`) — never raw
`AVAssetTrack`/`AVMutableComposition`/`CIImage`, specifically to avoid Swift 6 strict-concurrency
friction with AVFoundation/CoreImage's non-`Sendable` types. `MediaKind` is an enum rather than
optional fields on `Clip` deliberately — it keeps every consumer's `switch` exhaustive instead of
relying on an unenforced "duration is nil iff photo" invariant.

### Video processing pipeline (`Media/VideoProcessor.swift`)

This is the part most worth reading carefully before changing; several non-obvious AVFoundation/
Core Animation behaviors were discovered empirically (frame-by-frame visual inspection via
`ffmpeg`-extracted PNGs), not from docs alone:

- **`AVMutableVideoComposition.renderSize` — not any `CALayer`'s `frame` — determines the actual
  output pixel dimensions.** An earlier version sized `parentLayer`/`videoLayer` to the canvas
  size while leaving `renderSize` at the source's own resolution; the canvas compositing was
  silently never applied and output just came out at source resolution. `renderSize` must equal
  the target canvas size, and the "scale video to fit, center, inset by padding" math must be
  baked into the `AVMutableVideoCompositionLayerInstruction`'s transform (see
  `fittedRect(fitting:in:horizontalPadding:)` + the transform composition in `export(_:)`), not
  expressed via `CALayer.frame`.
- **Rounded corners use a real `CALayer.mask`**, not `masksToBounds` on a pre-sized layer and not
  a painted-over vector shape. A white background layer sits behind a full-canvas video layer;
  the video layer's `.mask` is a `CAShapeLayer` with a rounded-rect path matching the fitted video
  rect. Core Animation's mask compositing anti-aliases the edge correctly. An intermediate
  approach that painted a flat white shape directly over the video's corners left a visible hard
  seam once H.264 compressed across it — verified by cropping into exported frames.
  `parentLayer.isGeometryFlipped = true` is required on macOS to match AVFoundation's top-left/
  y-down render coordinate space (CALayer defaults to bottom-left/y-up on macOS, unlike iOS).
  `instruction.backgroundColor` (white) handles the letterbox/pillarbox fill outside the video's
  own fitted rect; the mask handles rounding within it.
- **Aspect ratio → canvas size**: `canvasSize(ratioWidth:ratioHeight:shortSide:)` holds the
  shorter side at 1080px and derives the other side, rounded to an even number (required for
  yuv420p encoding — odd dimensions can break the encoder).
- **Padding**: `fittedRect`'s `horizontalPadding` parameter reduces the width available to fit
  into while still centering against the *full* canvas width, so symmetric left/right margins
  fall out of ordinary centering math with no separate offset step needed.
- **Output filenames must include sub-second precision** (`OutputLocation.uniqueOutputURL`) —
  second-precision `ISO8601DateFormatter` timestamps collided and silently overwrote files on
  rapid re-exports; a fractional-seconds timestamp plus a short random suffix fixed it.
- Hardware acceleration is not something this code requests explicitly — `AVAssetExportSession`
  uses VideoToolbox automatically where available. This was confirmed empirically (not just
  assumed) by checking `com.apple.coremedia.videoencoder` XPC activity during export via
  `log show`.

### Photo processing pipeline (`Media/PhotoProcessor.swift`)

The still-image counterpart to `VideoProcessor`. A photo is a single frame, so this needs none of
`AVVideoCompositing`'s per-frame plumbing — decode once with `CIImage(contentsOf:options:
[.applyOrientationProperty: true])`, crop, apply the tonal adjustment filter chain, composite onto
the canvas, one `CIContext.render` call, encode to JPEG via `CGImageDestination`. It reuses
`VideoProcessor.swift`'s geometry math (`fittedRect`/`coveringRect`/`canvasSize`/`cornerRadius`)
unchanged, and reuses the exact Core Image compositing pattern already proven out by
`BlurredBackgroundCompositor` for the video blur-background option: a `CIRoundedRectangleGenerator`
mask blended with `CIBlendWithMask` for corner rounding (not a painted-over shape — same
anti-aliasing rationale as the video path's `CALayer.mask`), and a clamp→`CIGaussianBlur`→crop
sequence for the blurred background fill.

- **Crop** is stored/sent as fractions (0...1) of the oriented photo, top-left origin, y-down —
  the same convention as CSS/DOM coordinates, matching what the browser's crop tool naturally
  works in. Converting to a Core Image pixel rect requires a y-flip (`cropYPx = (1 - y - height) *
  imageHeight`), since `CIImage.extent` is bottom-left/y-up. Like the video path's
  `preferredTransform` normalization, `.cropped(to:)` leaves the extent at the crop rect's own
  (non-zero) origin, which would throw off every transform applied afterward (they're relative to
  the coordinate space's origin, not the content's own bounds) — it must be translated back to
  `(0,0)` before the fit/scale/position transforms run.
- **Tonal adjustments** — exposure, highlights, shadows, brightness, contrast, black point — map
  onto `CIExposureAdjust`, `CIHighlightShadowAdjust`, `CIColorControls`, and (for black point,
  which has no dedicated CI filter) a `CIColorMatrix` levels remap. The exact parameter names,
  defaults, and — critically — hard min/max bounds were pulled from `CIFilter(name:)!.attributes`
  at a REPL/throwaway-script prompt rather than assumed from docs (e.g. `inputHighlightAmount` is
  hard-capped at 1 — the filter can only recover/darken highlights, never boost them past
  "unchanged," which shapes how the UI slider's positive half behaves). **The sign of the
  highlights mapping was wrong in an early version** (`1 - percent/100` instead of `1 +
  percent/100`) and behaved plausibly enough in code review to ship — it was only caught by
  rendering actual before/after pixels for a known dark/bright test patch and comparing values,
  not by reading the filter's parameter description. `CIHighlightShadowAdjust` is also a *local*
  tone-mapping operator (its `inputRadius` parameter controls the local neighborhood used to
  decide what's a shadow/highlight) — testing it against a flat color or a smooth gradient shows
  almost no effect regardless of amount, because there's no local contrast for it to act on; a
  test image needs actual dark/light patches or real photo texture to be informative. Both
  lessons generalize: when validating a `CIFilter`, render real pixels and compare numbers, don't
  reason from the parameter's description alone.

### Background control: per-clip state, with a global bulk/default action

Background (a solid/custom color, or a blurred copy of the clip's own footage) is **per-clip**
state (`clip.backgroundMode` + `clip.backgroundColor`) — unlike aspect ratio/corner radius/padding
above, it is not a single value shared by the whole batch. Every clip (a video card's own row, or
a photo via the editor) has its own color swatches and its own Blur button. The "Blur all clips"
button in `#global-controls` is deliberately *not* a forced/override state: clicking it (1)
bulk-applies `backgroundMode: 'blur'` (or `'color'`) to every clip currently loaded, and (2)
becomes the default `backgroundMode` handed to clips uploaded afterward — but every clip stays
independently switchable afterward via its own Blur button, so the global button's own
active/inactive look can (and will) drift out of sync with individual clips the moment one is
changed by hand, the same way a "select all" checkbox goes stale once one item is toggled on its
own.

`setClipBackgroundColor`/`setClipBackgroundBlur` (`app.js`) are the single place that mutates a
clip's background — called from the per-clip swatches/Blur button (video card or editor) and
looped over every clip from the global button — and `applyClipBackgroundVisual` keeps both UI
surfaces for that clip in sync: the card's own preview/controls, and, if that same clip happens to
be the one open in the editor, the editor's preview/controls too (checked via `currentEditingClip
=== clip`).

### Photo editor UI (`Public/app.js`, the `#photo-editor` overlay in `index.html`)

Photo editing (crop + the six tonal sliders + background) happens in a single, large, reusable
overlay — Lightroom/Photomator-style — rather than inline on each grid card (grid cards stay
simple thumbnails; click one, or its edit icon, to open the editor). There's exactly **one**
editor instance in the DOM, reused for whichever photo is currently open: its control listeners
are wired once and read/write a module-level `currentEditingClip` reference rather than closing
over a specific clip at setup time, which avoids rebinding (and leaking duplicate) listeners each
time a different photo is opened — `renderEditor*`/`applyEditor*` functions repopulate the static
UI for a given clip on open.

- **Cropped preview via CSS, not canvas pixels**: the editor's large "framed" preview (and the
  crop tool's own live rect) render the crop purely with CSS — an `overflow: hidden` wrapper sized
  to the crop region's own aspect ratio (via `aspect-ratio`, so it fits into the canvas box exactly
  like an uncropped `<img>` did before), containing the full `<img>` absolutely positioned/scaled
  so the crop region fills the wrapper (`width/height` scaled by `naturalSize / cropSize`,
  `left/top` offset by `-cropOrigin / cropSize`). This is the same "let CSS layout do the
  contain-fit math" approach the rest of the frontend/backend geometry contract already relies on
  (see below) — no canvas/pixel manipulation needed for a live-draggable crop preview.
- **Crop tool** (draggable rect + 8 handles over the full, uncropped photo) tracks the crop rect
  in fraction-space (0...1) and computes drag deltas relative to the *rendered* image box
  (`getBoundingClientRect()` diffed against the stage container, recomputed per drag since the
  image is itself contain-fit and may be letterboxed within its stage). Each handle's `data-edge`
  (`"nw"`, `"n"`, `"e"`, …) is checked with `.includes('w'|'e'|'n'|'s')` so one drag handler covers
  all 8 handles plus whole-rect move, rather than 9 separate cases.
- **Live tonal preview via an SVG filter, not CSS `filter` functions**: exposure/brightness/
  contrast have clean CSS equivalents, but highlights/shadows/black point don't (CSS's `filter`
  shorthand has no tone-curve/levels primitive). Instead, a single 1D lookup curve (33 points
  across input 0...1, each slider's contribution weighted by where it sits in that range — shadows
  weighted toward 0, highlights toward 1, black point a floor shift) is computed in JS and applied
  via an `<feComponentTransfer><feFuncR type="table" ...>` SVG filter referenced from the image's
  `style.filter = "url(#editor-tone-curve)"`. Only the filter's `tableValues` attributes are
  rewritten per slider input — the `url(#...)` reference itself never changes, so the browser just
  re-renders with the new curve. Like the rest of the preview stack, this is a deliberate
  approximation (documented in the JS), not a client-side reimplementation of
  `CIHighlightShadowAdjust`'s actual algorithm — the export is the source of truth.

### Frontend/backend geometry contract

Corner radius, aspect ratio, and padding are **global** controls (one value applies to every clip
in a batch, video or photo), while trim start/end and crop are per-clip (trim is video-only, crop
is photo-only). The percent-based math is intentionally kept consistent between the browser
preview and the server:

- Corner radius %: `radius = (shortSideOfFittedVideoRect / 2) * (percent / 100)` — 100% rounds the
  video's short edge into a full pill/circle. Implemented once server-side
  (`cornerRadius(forPercent:ofRect:)`) and once client-side (`applyRadiusToPreviewElement` in
  `app.js`, reading the relevant element's post-layout `clientWidth`/`clientHeight` — a `<video>`,
  an `<img>`, or, in the photo editor, the crop-wrapper div).
- Padding %: expressed as "% of canvas width per side." The browser preview applies this as CSS
  `padding-left`/`padding-right` percentages on `.canvas-preview`, which CSS defines as relative
  to the container's *width* even for what would otherwise be vertical padding — this happens to
  exactly match the server's semantics for free, so the preview needs no bespoke padding math.
- Aspect ratio: buttons carry `data-w`/`data-h`; the preview box gets `style.aspectRatio =
  "${w} / ${h}"`, letting the browser's own layout reproduce the "contain, centered" fit that the
  server computes via `fittedRect`.
- Because the live thumbnail is a CSS approximation (not literally the AVFoundation-composited
  frame), it's expected to be close but not pixel-identical to the exported file — the server
  pipeline in `VideoProcessor.swift` is the source of truth.
