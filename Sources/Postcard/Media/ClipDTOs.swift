import Vapor

struct UploadForm: Content {
    var file: File
}

struct UploadResponse: Content {
    let id: String
    let filename: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let suggestedColors: [String]
}

struct ExportRequestBody: Content {
    let trimStart: Double
    let trimEnd: Double
    let cornerRadiusPercent: Double
    let aspectRatioWidth: Double
    let aspectRatioHeight: Double
    let paddingPercent: Double
    let backgroundMode: String
    let backgroundColorHex: String
}

struct ExportResponse: Content {
    let id: String
    let outputPath: String
}
