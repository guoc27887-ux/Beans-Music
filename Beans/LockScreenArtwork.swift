import AVFoundation
import CryptoKit
import MediaPlayer
import UIKit

/// 锁屏动态封面的设置键，iOS 18 与 iOS 26 共用（功能本身仅 iOS 26 可用）。
enum BeansLockScreenArtworkSettings {
    static let enabledKey = "beans.lockScreenImmersiveArtwork.enabled"
}

/// Supplies the local animated cover that iOS can use on the Lock Screen.
/// Beans 2.0.3 exposes a lease and a video directory; this implementation preserves
/// a private copy of each movie and uses a stable artwork identifier.
/// 动态封面依赖 iOS 26 的 MPMediaItemAnimatedArtwork，iOS 18 上整体不可用。
@available(iOS 26.0, *)
final class BeansLockScreenArtwork {
    static let enabledKey = BeansLockScreenArtworkSettings.enabledKey

    private var entries: [String: [String: MPMediaItemAnimatedArtwork]] = [:]
    private var pending = Set<String>()
    var onReady: (() -> Void)?

    func artwork(sourceURL: URL) -> [String: MPMediaItemAnimatedArtwork] {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true,
              !sourceURL.isFileURL || FileManager.default.fileExists(atPath: sourceURL.path) else { return [:] }
        let revision = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        let identifier = "beans-lock-screen|\(sourceURL.absoluteString)|\(revision?.fileSize ?? 0)|\(revision?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let existing = entries[identifier] { return existing }
        guard pending.insert(identifier).inserted else { return [:] }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        guard !keys.isEmpty else { pending.remove(identifier); return [:] }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> [String: MPMediaItemAnimatedArtwork] in
                guard let retained = try? await BeansLockScreenVideoStore.shared.retain(source: sourceURL, identifier: identifier) else { return [:] }
                let lease = BeansLockScreenArtworkLease(identifier: identifier)
                guard let image = CustomCoverMedia.previewImage(at: retained) else { return [:] }
                var values: [String: MPMediaItemAnimatedArtwork] = [:]
                for (key, size) in [(MPNowPlayingInfoProperty1x1AnimatedArtwork, CGSize(width: 720, height: 720)),
                                    (MPNowPlayingInfoProperty3x4AnimatedArtwork, CGSize(width: 720, height: 960))] where keys.contains(key) {
                    let preview = Self.crop(image, to: size)
                    values[key] = MPMediaItemAnimatedArtwork(
                        artworkID: identifier + "|" + key,
                        previewImageRequestHandler: { _ in preview },
                        videoAssetFileURLRequestHandler: { _ in
                            try? await BeansLockScreenVideoStore.shared.video(source: retained, identifier: lease.identifier, size: size)
                        }
                    )
                }
                return values
            }.value
            guard let self else { return }
            self.pending.remove(identifier)
            if self.entries.count >= 4 { self.entries.removeAll() }
            self.entries[identifier] = result
            self.onReady?()
        }
        return [:]
    }

    private static func crop(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = max(size.width / max(1, image.size.width), size.height / max(1, image.size.height))
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }
}

/// 跨版本门面：内部以类型擦除方式持有 iOS 26 的 BeansLockScreenArtwork，
/// 让调用方（如 PlayerManager 的存储属性）无需直接引用 iOS 26 专属类型；
/// iOS 18 上所有调用返回空结果，静态封面不受影响。
final class BeansLockScreenArtworkProvider {
    var onReady: (() -> Void)?
    private var storage: AnyObject?

    func artwork(sourceURL: URL) -> [String: Any] {
        guard #available(iOS 26.0, *) else { return [:] }
        let artwork: BeansLockScreenArtwork
        if let existing = storage as? BeansLockScreenArtwork {
            artwork = existing
        } else {
            artwork = BeansLockScreenArtwork()
            artwork.onReady = onReady
            storage = artwork
        }
        return artwork.artwork(sourceURL: sourceURL)
    }
}

private final class BeansLockScreenArtworkLease: @unchecked Sendable {
    let identifier: String
    init(identifier: String) { self.identifier = identifier }
    deinit {
        let identifier = identifier
        Task { await BeansLockScreenVideoStore.shared.release(identifier: identifier) }
    }
}
