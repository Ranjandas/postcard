import Vapor

func configure(_ app: Application) throws {
    guard let publicDir = Bundle.module.resourceURL?.appendingPathComponent("Public") else {
        fatalError("Postcard: could not locate bundled Public resources directory")
    }
    app.middleware.use(FileMiddleware(publicDirectory: publicDir.path, defaultFile: "index.html"))

    app.post("api", "upload", use: UploadController.upload)
    app.get("api", "media", ":id", use: MediaController.stream)
    app.post("api", "export", ":id", use: ExportController.export)
    app.delete("api", "clip", ":id", use: ClipController.delete)
    app.post("api", "reveal-output", use: RevealController.reveal)
}
