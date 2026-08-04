import AppKit
import WebKit

/// Hosts Postcard's UI in a real `NSWindow` (via `WKWebView`) instead of the user's default
/// system browser. This is the sole owner of that window/web view for the app's lifetime — there
/// is exactly one, created once at startup and only ever hidden, never deallocated, so reopening
/// it (status item, or a future "camera connected" trigger) is instant and preserves whatever
/// client-side JS state (loaded clips, an open photo editor) was already there.
@MainActor final class MainWindowController: NSObject, NSWindowDelegate, WKUIDelegate {
    private let window: NSWindow
    private let webView: WKWebView

    override init() {
        // A non-persistent data store means no on-disk HTTP cache surviving across app
        // relaunches — the default (persistent) store caches `/`, `/app.js`, `/styles.css` to
        // disk keyed off the app, so a rebuilt server can end up never even being requested by
        // an already-cached WKWebView; confirmed by the total absence of `GET /` in the server
        // log across several relaunches while chasing an unrelated-looking bug. Content here is
        // inherently ephemeral per-session anyway (clips live in per-launch temp dirs via
        // ClipStore), so there's no persistent state worth keeping across launches in the first
        // place — this isn't just a dev workaround, it's the architecturally correct choice.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Postcard"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.contentView = webView
        self.window = window

        super.init()
        window.delegate = self
        webView.uiDelegate = self
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        // Accessory apps (`.accessory` activation policy, see main.swift) don't get automatic
        // activation on window order-front the way regular apps do, so this needs to be explicit
        // or the window can appear behind whatever app currently has focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    // Hide rather than let AppKit actually close/deallocate the window — keeps the WKWebView
    // (and all client-side JS state) alive so reopening via the status item is instant, with
    // nothing lost, rather than a fresh page load.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // Unlike a real browser, WKWebView on macOS has no built-in handling for `<input
    // type="file">` — without this delegate method, clicking the drop zone's "or click to choose
    // files" control silently does nothing, no panel appears. Drag-and-drop is unaffected since
    // it's raw DOM `dataTransfer`, not a native panel.
    //
    // The completion handler's type must match the protocol requirement's *exactly*, including
    // `@MainActor @Sendable` — plain `@escaping ([URL]?) -> Void` compiles with only a quiet
    // "nearly matches optional requirement" warning, but Swift then does NOT treat this as
    // fulfilling the `WKUIDelegate` requirement: WebKit's ObjC runtime sees the app as not
    // implementing the method at all, so it never gets called and nothing happens, no matter how
    // the click is triggered. Caught by actually reading that warning instead of dismissing it.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}
