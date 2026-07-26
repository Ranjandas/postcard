# Postcard

Postcard is a macOS menu bar app that frames your video clips like postcards. Drag a clip in,
trim it, pick an aspect ratio, round the corners, and export — all with hardware-accelerated
processing, right from your menu bar.

## Features

- **Drag-and-drop batch import** — drop multiple clips at once, each gets its own trim range.
- **Trim** — set in/out points per clip with a scrubbable dual-handle slider.
- **Aspect ratio** — pick from Instagram's supported ratios: `9:16` (Story/Reel), `4:5`
  (Portrait), `1:1` (Square), `3:4` (Tall), `1.91:1` (Landscape).
- **Rounded corners** — adjustable roundedness, from square to a full pill shape.
- **Side padding** — equal left/right inset around the framed clip.
- **Live preview** — every control updates the thumbnail immediately in the browser.
- **Hardware-accelerated export** — uses AVFoundation/VideoToolbox, not a software encode.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode or Xcode Command Line Tools)

## Getting started

Clone the repo and run it directly with Swift Package Manager:

```sh
git clone git@github.com:Ranjandas/postcard.git
cd postcard
swift run
```

This launches Postcard as a menu bar app (look for its icon in the menu bar — no Dock icon by
design) and opens the UI in your default browser at `http://127.0.0.1:8420`.

### Building a standalone app

`swift run` is fine for development, but to get a double-clickable `Postcard.app`:

```sh
./Scripts/build-app.sh
open Postcard.app
```

This produces a release build and hand-assembles the `.app` bundle (ad-hoc signed, so Gatekeeper
won't block it on the machine that built it).

## Usage

1. Launch Postcard — it starts a local server and opens the UI in your browser.
2. Drag one or more video clips onto the drop zone (or click it to choose files).
3. For each clip, drag the trim handles to set the start/end points.
4. Use the global controls to pick an aspect ratio, corner roundedness, and side padding — these
   apply to every clip in the batch and update all the thumbnails live.
5. Click **Export** on a clip, or **Export All** for the whole batch.
6. Click **Reveal Output Folder** to find your exported clips in `~/Movies/Postcard Output/`.

## How it works

Each clip is composited onto a white canvas of the chosen aspect ratio, scaled to fit and
centered, with the requested padding and corner rounding baked into the exported video —
not just a preview overlay. Encoding goes through AVFoundation, which uses hardware
acceleration (VideoToolbox) automatically where available.

## Roadmap

- Photo support, alongside video clips.

## Project layout

```
Sources/Postcard/
├── main.swift, AppDelegate.swift   — menu bar app shell
├── Server/                         — Vapor routes (upload, media streaming, export, reveal)
├── Media/                          — clip state + the AVFoundation compositing/export pipeline
└── Public/                         — the browser UI (HTML/CSS/JS)
```

See [`CLAUDE.md`](./CLAUDE.md) for a deeper architecture walkthrough.
