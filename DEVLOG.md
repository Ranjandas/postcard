# Dev Log

Chronological record of features and fixes: what changed, why, and how. Newest entries at the
top. This file is history — it captures the reasoning behind a change as it happened. For the
current state of the architecture, see `CLAUDE.md` instead; that file is a living reference and
gets rewritten as things change, while entries here stay as a record of what was true and why at
the time.

## 2026-08-04 — Fix: "or click to choose files" did nothing in the new native window

**What:** Three independent bugs, all masking each other, had to be found and fixed before this
worked: (1) `MainWindowController` now conforms to `WKUIDelegate` and implements
`webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)` with the completion handler
typed exactly as `@escaping @MainActor @Sendable ([URL]?) -> Void`, matching the protocol
requirement precisely; (2) the drop zone (`index.html`) is now a `<label for="file-input">`
instead of a plain `<section>` with a JS `fileInput.click()` call, and the input itself is
visually hidden via CSS (`.visually-hidden`) rather than the `hidden` attribute; (3) the
`WKWebView`'s configuration now uses `WKWebsiteDataStore.nonPersistent()`
(`MainWindow.swift:22-23`) instead of the default persistent store.

**Why:** Regression from the previous entry's move to a native `WKWebView` window: dragging files
kept working (raw DOM `dataTransfer`, no native panel involved), but clicking "or click to choose
files" did nothing, and stayed broken across several rounds of fixes that each looked sufficient
on their own:
- WKWebView on macOS has no built-in file-picker handling at all — the host app must supply an
  `NSOpenPanel` via `WKUIDelegate`, which `MainWindowController` never set. Fixing just this
  (adding the delegate method with a plain `([URL]?) -> Void` completion handler type) produced a
  quiet "nearly matches optional requirement" build warning that looked benign and was dismissed
  as such — wrongly. Swift's protocol-conformance checking is exact about closure attributes:
  without `@MainActor @Sendable` matching the protocol's declared type precisely, the method
  doesn't count as an override at all, so WebKit never called it, no matter what triggered the
  click.
- Separately, and while still misdiagnosing the above as the whole problem: the drop zone relied
  on a JS-synthesized `fileInput.click()`, which real browsers honor but WKWebView appears not to
  treat as a trusted user gesture for opening a native panel — switched to a `<label for>`
  association, which is the browser's own default action, not synthetic JS.
- Also separately: the `hidden` attribute makes an element `display: none`, and WKWebView appears
  to exclude such elements from receiving open-panel activation at all, `<label>`-triggered or
  not — switched to a "visually hidden but still rendered" CSS pattern instead.
- Also separately, and the one that made the other two fixes impossible to verify: `WKWebView`'s
  default (persistent) `WKWebsiteDataStore` caches HTTP responses to disk *across app relaunches*,
  unlike the Vapor server process, which restarts clean every time. Every one of the fixes above
  was rebuilt and relaunched to test, but the server log showed **zero** `GET /` requests on
  several of those relaunches — the window was silently showing a stale cached page the whole
  time, so changes to `index.html`/`app.js`/`styles.css` weren't even being loaded into the
  browser context to test in the first place.

**How:** Found by working outward from what could be verified directly rather than guessing
further: confirmed the server was serving the latest files (`curl`), confirmed the running binary
was freshly built and contained the latest diagnostic strings (`strings` on the binary), and only
then noticed the server log's *absence* of `GET /` on relaunch as the tell for the caching bug.
The delegate signature bug was found by actually reading the full text of a build warning that
had been glossed over as boilerplate noise three fix-attempts earlier — a reminder that "just a
warning" still deserves reading in full, not pattern-matching on its shape. Once all three were
fixed together, confirmed working via a real manual click (not scriptable in this environment —
GUI-scripted and CGEvent-synthesized clicks here don't reliably carry a trusted gesture through to
WebKit either, which is a separate, weaker echo of the same "what counts as a real user gesture"
theme).


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
