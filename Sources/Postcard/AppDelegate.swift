import AppKit
import Vapor
import Foundation

@objc @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var vaporApp: Application?
    private let port = 8420
    private let hostname = "127.0.0.1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        Task {
            do {
                try await startServer()
            } catch {
                NSLog("Postcard: failed to start server: \(error)")
                let alert = NSAlert()
                alert.messageText = "Postcard couldn't start its local server"
                alert.informativeText = "\(error)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    private func startServer() async throws {
        CaptionFonts.registerBundledFonts()

        let env = try Environment.detect()
        let app = try await Application.make(env)
        self.vaporApp = app

        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = "500mb"

        try configure(app)
        try await app.startup()

        let url = URL(string: "http://\(hostname):\(port)/")!
        await waitUntilReady(url: url)
        NSWorkspace.shared.open(url)
    }

    /// Belt-and-suspenders readiness check: poll briefly before opening the browser,
    /// in case `startup()` returns before the listen socket is fully accept()-ready.
    private func waitUntilReady(url: URL, attempts: Int = 20) async {
        for _ in 0..<attempts {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // Deliberately not `applicationWillTerminate` + a blocking DispatchSemaphore: this class is
    // @MainActor, so `Task { ... }` created here inherits that actor and can only run on the main
    // thread's own serial executor — blocking that same thread with `sem.wait()` right after
    // starting it deadlocks forever (the task can never get scheduled to call `sem.signal()`).
    // `.terminateLater` + `NSApp.reply(...)` lets AppKit's run loop keep going while the async
    // shutdown completes, then finishes termination once it actually has.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = vaporApp else { return .terminateNow }
        Task {
            try? await app.asyncShutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Accessory apps (no Dock icon) never get a visible menu bar, so without this,
    /// Cmd+Q has no main menu to route to and silently does nothing — the status
    /// item's own "Quit" key equivalent only fires while that dropdown is open.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Postcard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Postcard")
        let menu = NSMenu()
        let openItem = menu.addItem(withTitle: "Open Postcard", action: #selector(openUI), keyEquivalent: "")
        openItem.target = self
        let revealItem = menu.addItem(withTitle: "Reveal Output Folder", action: #selector(revealOutput), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(.separator())
        // Left with a nil target deliberately: `terminate(_:)` is an NSApplication method, not one
        // AppDelegate implements, so setting `target = self` here (as the other items do) makes
        // NSMenu's automatic validation see the target doesn't respond to the selector and grey the
        // item out. A nil target instead walks the responder chain, which finds NSApp.
        menu.addItem(withTitle: "Quit Postcard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openUI() {
        NSWorkspace.shared.open(URL(string: "http://\(hostname):\(port)/")!)
    }

    @objc private func revealOutput() {
        if let dir = try? OutputLocation.ensureOutputDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}
