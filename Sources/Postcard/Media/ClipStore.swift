import CoreGraphics
import Foundation
@preconcurrency import CoreMedia

actor ClipStore {
    static let shared = ClipStore()

    struct Clip: Sendable {
        let id: String
        let originalFilename: String
        let sourceURL: URL
        let duration: CMTime
        let orientedSize: CGSize
    }

    private var clips: [String: Clip] = [:]

    func register(_ clip: Clip) {
        clips[clip.id] = clip
    }

    func clip(id: String) -> Clip? {
        clips[id]
    }

    @discardableResult
    func remove(id: String) -> Clip? {
        clips.removeValue(forKey: id)
    }
}
