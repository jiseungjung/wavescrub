import AVFoundation
import ImageIO
import Photos

/// A video's length, frame rate, upright size, and how the camera stored its
/// frames relative to how they're watched.
struct VideoInfo {
    var duration: Double
    var frameRate: Double
    var size: CGSize
    var orientation: CGImagePropertyOrientation

    static func load(_ asset: AVAsset) async throws -> VideoInfo {
        let duration = try await asset.load(.duration).seconds
        var fps = 30.0
        var size = CGSize.zero
        var orientation = CGImagePropertyOrientation.up
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (rate, natural, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
            if rate > 0 { fps = Double(rate) }
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
            switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
            case (0, 1, -1, 0): orientation = .right
            case (0, -1, 1, 0): orientation = .left
            case (-1, 0, 0, -1): orientation = .down
            default: orientation = .up
            }
        }
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return VideoInfo(duration: duration, frameRate: fps, size: size, orientation: orientation)
    }
}

extension RecentVideo {
    /// The key its waves and paths are saved under, as the main screen uses.
    var videoKey: String? {
        switch kind {
        case .photo: photoID.map { "photo:" + $0 }
        case .file: filePath.map { "file:" + $0 }
        }
    }
}

/// A video opened beside the one on the main screen, for comparing. A file
/// from Files stays readable for as long as this is kept.
final class OpenedVideo {
    let asset: AVAsset
    let info: VideoInfo
    let key: String
    private let scopedURL: URL?

    init(asset: AVAsset, info: VideoInfo, key: String, scopedURL: URL? = nil) {
        self.asset = asset
        self.info = info
        self.key = key
        self.scopedURL = scopedURL
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    /// Opens a recent video in place, as the main screen would, without
    /// touching what's open there. `progress` reports an iCloud download.
    static func open(_ recent: RecentVideo, progress: @escaping @MainActor (Int) -> Void) async throws -> OpenedVideo {
        guard let key = recent.videoKey else { throw CocoaError(.fileNoSuchFile) }
        switch recent.kind {
        case .photo:
            let asset = try await photoAsset(id: recent.photoID ?? "", progress: progress)
            return OpenedVideo(asset: asset, info: try await VideoInfo.load(asset), key: key)
        case .file:
            var stale = false
            guard let data = recent.fileBookmark,
                  let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let scoped = url.startAccessingSecurityScopedResource()
            let asset = AVURLAsset(url: url)
            do {
                return OpenedVideo(asset: asset, info: try await VideoInfo.load(asset), key: key,
                                   scopedURL: scoped ? url : nil)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        }
    }

    private static func photoAsset(id: String, progress: @escaping @MainActor (Int) -> Void) async throws -> AVAsset {
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            Task { @MainActor in progress(Int(value * 100)) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
                if let asset {
                    continuation.resume(returning: asset)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
