import Vapor
import Foundation

enum ClipController {
    static func delete(_ req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }
        guard let clip = await ClipStore.shared.remove(id: id) else {
            throw Abort(.notFound)
        }
        try? FileManager.default.removeItem(at: clip.sourceURL.deletingLastPathComponent())
        return .noContent
    }
}
