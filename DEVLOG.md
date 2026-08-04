# Dev Log

Chronological record of features and fixes: what changed, why, and how. Newest entries at the
top. This file is history — it captures the reasoning behind a change as it happened. For the
current state of the architecture, see `CLAUDE.md` instead; that file is a living reference and
gets rewritten as things change, while entries here stay as a record of what was true and why at
the time.

## 2026-08-04 — Native window via WKWebView instead of the default browser

**What:** Postcard's UI now opens in a real, native `NSWindow` (`Sources/Postcard/MainWindow.swift`,
`MainWindowController`) hosting a `WKWebView`, instead of handing the local server's URL to
`NSWorkspace.shared.open(url)` and launching the user's default system browser. The window is
created once at startup and only ever hidden (`windowShouldClose` returns `false` and calls
`orderOut(nil)`), never deallocated — closing it and reopening via the status item's "Open
Postcard" is instant and preserves whatever client-side JS state was already there (loaded clips,
an open photo editor), since the `WKWebView` and its page never reload.

**Why:** An external browser tab made Postcard feel like a website rather than a Mac app — no
real title bar/toolbar chrome, and no way to reliably bring the UI back to front on a system
event (you can't `NSApp.activate` a specific already-open browser tab). That second point is a
hard blocker for the planned camera-import feature: when a camera is plugged in, the app needs to
reliably grab focus and show an import prompt the way Photos.app/Image Capture do, which requires
owning a real window.

**How:** `MainWindowController` (`@MainActor`, `NSObject & NSWindowDelegate`) builds a titled,
resizable `NSWindow` (1280×860 default, 900×600 minimum) with a `WKWebView` filling its content
view. `AppDelegate.startServer()` creates and shows it after the existing `waitUntilReady(url:)`
poll, instead of calling `NSWorkspace.shared.open`; the status item's `openUI()` now just calls
`.show()` on the existing controller (`makeKeyAndOrderFront` + `NSApp.activate` — accessory apps
don't auto-activate on window order-front, unlike regular apps). No changes to the server,
`ClipStore`, or any processing pipeline; this is purely how the existing page is hosted.
Verified: the window renders as a native macOS window (not a browser tab) with the app's UI
intact; closing and reopening via the status item shows no new `GET /` request in the server log
(confirming no reload); the existing Vapor-shutdown quit path still terminates cleanly. Drag-and-
drop file upload and `<video>` scrubbing inside the `WKWebView` were not verified in this pass —
they need a real file drag/playback check, which isn't something scriptable via the CLI tools
available while making this change.
