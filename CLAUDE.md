# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Postcard is a macOS menu bar app. It runs a local Vapor web server in-process and serves a
browser UI at `http://127.0.0.1:8420`. You drag short video clips onto the page, trim them, pick
an aspect ratio and corner roundedness/padding, and it exports each clip — centered on a white
canvas, scaled to fit, corners rounded — using hardware-accelerated AVFoundation/VideoToolbox
encoding. Output goes to `~/Movies/Postcard Output/`.

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
packaged `.app` both resolve it through `Bundle.module`), then four JSON/multipart routes:

- `POST /api/upload` (`UploadController`) — saves the file to a per-clip temp dir, probes
  duration/dimensions with `AVURLAsset`'s async `load(...)` API, registers the clip in
  `ClipStore`.
- `GET /api/media/:id` (`MediaController`) — `req.fileio.asyncStreamFile(at:)`, which handles
  HTTP Range requests, needed for `<video>` scrubbing in the browser.
- `POST /api/export/:id` (`ExportController`) — decodes trim range, corner radius %, aspect
  ratio, padding % from the request body, clamps them, and calls `VideoProcessor.export`.
- `POST /api/reveal-output` (`RevealController`) — hops to `@MainActor` to call
  `NSWorkspace.activateFileViewerSelecting`.

`ClipStore` (`Media/ClipStore.swift`) is an `actor` holding only `Sendable` value types (`URL`,
`CMTime`, `CGSize`, `String`) — never raw `AVAssetTrack`/`AVMutableComposition` — specifically to
avoid Swift 6 strict-concurrency friction with AVFoundation's non-`Sendable` types.

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

### Frontend/backend geometry contract

Corner radius, aspect ratio, and padding are **global** controls (one value applies to every clip
in a batch), while trim start/end are per-clip. The percent-based math is intentionally kept
consistent between the browser preview and the server:

- Corner radius %: `radius = (shortSideOfFittedVideoRect / 2) * (percent / 100)` — 100% rounds the
  video's short edge into a full pill/circle. Implemented once server-side
  (`cornerRadius(forPercent:ofRect:)`) and once client-side (`applyRadiusToVideo` in `app.js`,
  reading the video element's post-layout `clientWidth`/`clientHeight`).
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
