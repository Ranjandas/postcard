import AppKit
import WebKit

/// Hosts Postcard's UI in a real `NSWindow` (via `WKWebView`) instead of the user's default
/// system browser. This is the sole owner of that window/web view for the app's lifetime — there
/// is exactly one, created once at startup and only ever hidden, never deallocated, so reopening
/// it (status item, or a future "camera connected" trigger) is instant and preserves whatever
/// client-side JS state (loaded clips, an open photo editor) was already there.
@MainActor final class MainWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let webView: WKWebView

    override init() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
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
}
