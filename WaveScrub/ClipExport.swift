import AVFoundation
import CoreImage
import Photos

/// Turns followed waves into one upright video to share: each wave as the
/// loop screen plays it, following the surfer, cut to 9:16, one after the
/// other, at the speed you're watching, with its sound.
///
/// The frame is as wide as the loop screen shows at your zoom; its height is
/// made up from the picture above and below, trimming the sky and water past
/// it. Zoomed out so far that the picture isn't tall enough for 9:16, it's
/// as tall as the picture, and comes out a little less tall than 9:16.
enum ClipExport {
    struct Piece {
        let start: Double
        let end: Double
        let track: WaveTrack
    }

    enum Failure: LocalizedError {
        case noVideo, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: "Couldn't read the video."
            case .failed(let why): why
            }
        }
    }

    /// How wide the shared clips are, in pixels.
    static let width: CGFloat = 1080

    /// The part of the picture each frame shows, as shares of its width and
    /// height: as wide as a screen this shape shows at `span`, and 9:16 tall
    /// where the picture allows.
    static func shown(span: Double, screen: CGSize, picture: CGSize) -> (w: CGFloat, h: CGFloat) {
        guard screen.width > 0, screen.height > 0, picture.width > 0, picture.height > 0 else { return (1, 1) }
        let aspect = picture.width / picture.height
        let whole = max(1, aspect * screen.height / screen.width)
        let shownH = min(CGFloat(span), whole)
        let w = min(1, shownH * (screen.width / screen.height) / aspect)
        let h = min(1, w * picture.width * 16 / 9 / picture.height)
        return (w, h)
    }

    /// The finished video's size in pixels, for that part of the picture.
    static func size(shown: (w: CGFloat, h: CGFloat), picture: CGSize) -> CGSize {
        let ratio = (shown.h * picture.height) / max(1, shown.w * picture.width)
        return CGSize(width: width, height: (width * ratio / 2).rounded() * 2)
    }

    /// Writes the video to a temporary file and returns it. `progress` is
    /// called on the main queue, from 0 to 1.
    static func export(asset: AVAsset, orientation: CGImagePropertyOrientation, pieces: [Piece],
                       shown: (w: CGFloat, h: CGFloat), rate: Float, name: String,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let sound = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform, fps) = try await source.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let upright = CGRect(origin: .zero, size: natural).applying(transform).size
        let picture = CGSize(width: abs(upright.width), height: abs(upright.height))

        // The waves back to back, as they are in the video.
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noVideo }
        video.preferredTransform = transform
        let audio = sound.flatMap {
            _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        /// Where each wave starts in the finished video, before any slowing
        /// down, and in the original.
        var cuts: [(at: Double, from: Double, piece: Piece)] = []
        var cursor = CMTime.zero
        for piece in pieces {
            let range = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 60000),
                                    end: CMTime(seconds: piece.end, preferredTimescale: 60000))
            try video.insertTimeRange(range, of: source, at: cursor)
            if let audio, let sound { try? audio.insertTimeRange(range, of: sound, at: cursor) }
            cuts.append((cursor.seconds, range.start.seconds, piece))
            cursor = cursor + range.duration
        }
        let speed = Double(max(0.05, rate))
        if speed != 1 {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                       toDuration: CMTimeMultiplyByFloat64(cursor, multiplier: 1 / speed))
        }

        let size = size(shown: shown, picture: picture)
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            var image = request.sourceImage
            // Frames may come as the camera stored them, on their side.
            let e = image.extent.size
            if abs(e.width - picture.width) > 1 || abs(e.height - picture.height) > 1 {
                image = image.oriented(orientation)
            }
            let t = request.compositionTime.seconds * speed
            guard let cut = cuts.last(where: { $0.at <= t + 0.0005 }) ?? cuts.first else {
                return request.finish(with: image, context: nil)
            }
            let time = cut.from + (t - cut.at)
            let rect = FollowView(track: cut.piece.track, shownW: shown.w, shownH: shown.h).rect(at: time)
            let x = image.extent.minX, y = image.extent.minY
            let w = image.extent.width, h = image.extent.height
            // Core Image measures from the bottom-left.
            let crop = CGRect(x: x + rect.minX * w, y: y + (1 - rect.maxY) * h,
                              width: rect.width * w, height: rect.height * h)
            request.finish(with: LoopFrames.cut(image, to: crop, size: size), context: nil)
        }
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60, max(24, fps.rounded()))))

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.failed("Couldn't export on this phone.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(name) + ".mp4")
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.audioTimePitchAlgorithm = .spectral

        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { watcher.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { done.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw Failure.failed(session.error?.localizedDescription ?? "The export didn't finish.")
        }
        return url
    }

    /// Saves the video into Photos, in a WaveScrub album.
    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let album: PHAssetCollection? = status == .authorized ? {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", albumName)
            return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
        }() : nil
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url),
                  let placeholder = request.placeholderForCreatedAsset, status == .authorized else { return }
            let albumRequest = album.map { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            albumRequest?.addAssets([placeholder] as NSArray)
        }
    }

    private static let albumName = "WaveScrub"

    private static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "WaveScrub" : String(clean.prefix(80))
    }
}
