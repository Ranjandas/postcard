import Vapor

struct UploadResponse: Content {
    let id: String
    let filename: String
    let mediaKind: String // "video" or "photo"
    let durationSeconds: Double? // nil for photos
    let width: Int
    let height: Int
    let suggestedColors: [String]
}

struct ExportRequestBody: Content {
    let trimStart: Double // video-only, ignored for photos
    let trimEnd: Double // video-only, ignored for photos
    let cornerRadiusPercent: Double
    let aspectRatioWidth: Double
    let aspectRatioHeight: Double
    let paddingPercent: Double
    let backgroundMode: String
    let backgroundColorHex: String
    // Everything below is photo-only, ignored for video.
    let cropX: Double
    let cropY: Double
    let cropWidth: Double
    let cropHeight: Double
    let exposurePercent: Double
    let highlightsPercent: Double
    let shadowsPercent: Double
    let brightnessPercent: Double
    let contrastPercent: Double
    let blackPercent: Double
}

struct ExportResponse: Content {
    let id: String
    let outputPath: String
}
