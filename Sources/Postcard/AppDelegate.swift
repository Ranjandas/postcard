import AppKit
import Vapor
import Foundation

@objc @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var vaporApp: Application?
    private let port = 8420
    private let hostname = "127.0.0.1"

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationWillTerminate(_ notification: Notification) {
        guard let app = vaporApp else { return }
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await app.asyncShutdown()
            sem.signal()
        }
        sem.wait()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Postcard")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Postcard", action: #selector(openUI), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal Output Folder", action: #selector(revealOutput), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Postcard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
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
