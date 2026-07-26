import Vapor
import AppKit

enum RevealController {
    static func reveal(_ req: Request) async throws -> HTTPStatus {
        let dir = try OutputLocation.ensureOutputDirectory()
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
        return .ok
    }
}
