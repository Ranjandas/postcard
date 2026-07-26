import Vapor

enum MediaController {
    static func stream(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id"),
              let clip = await ClipStore.shared.clip(id: id) else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: clip.sourceURL.path)
    }
}
