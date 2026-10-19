import AVFoundation
import CoreImage
import Foundation

/// Every frame of each wave's loop, cut as it will be exported and kept
/// small, so sliding through the export editor shows each one at once.
///
/// Seeking the video to an exact frame means decoding from the last whole
/// picture, about a second back, then cutting it out: slower than a finger
/// moves, so the picture trailed behind. Here each loop is decoded once,
/// straight through, as soon as the editor opens. Frames are kept by their
/// moment in the original video, so trimming, reordering and changing
/// speed all use the same ones.
final class EditorFrames: @unchecked Sendable {
    struct Clip {
        let id: UUID
        let loop: ClosedRange<Double>
        let track: WaveTrack
    }

    private let lock = NSLock()
    private var frames: [UUID: [(time: Double, data: Data)]] = [:]
    private var bytes = 0
    private var cancelled = false

    /// How wide the kept frames are, in pixels: sharp enough for the
    /// editor's picture while sliding, small enough to keep them all.
    static let width: CGFloat = 405
    /// At most this many frames a second; more look no smoother while sliding.
    static let rate = 30.0
    /// Stops keeping frames past this, in case of a very long export.
    static let maxBytes = 160_000_000

    /// Starts decoding in the background, the waves in the order given.
    func start(asset: AVAsset, clips: [Clip], shown: (w: CGFloat, h: CGFloat),
               orientation: CGImagePropertyOrientation) {
        Task.detached(priority: .userInitiated) { [self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let context = CIContext(options: [.cacheIntermediates: false])
            for clip in clips {
                guard !isCancelled else { return }
                decode(asset, track: track, clip: clip, shown: shown, orientation: orientation, context: context)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        frames = [:]
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// The kept frame of this wave nearest a moment in the original video,
    /// if one is that close.
    func image(_ id: UUID, at time: Double) -> CGImage? {
        lock.lock()
        let list = frames[id] ?? []
        lock.unlock()
        guard !list.isEmpty else { return nil }
        var lo = 0, hi = list.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        let best = [lo - 1, lo].filter { list.indices.contains($0) }
            .min { abs(list[$0].time - time) < abs(list[$1].time - time) } ?? lo
        guard abs(list[best].time - time) < 1.5 / Self.rate,
              let source = CGImageSourceCreateWithData(list[best].data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func decode(_ asset: AVAsset, track: AVAssetTrack, clip: Clip, shown: (w: CGFloat, h: CGFloat),
                        orientation: CGImagePropertyOrientation, context: CIContext) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: clip.loop.lowerBound, preferredTimescale: 60000),
                                       end: CMTime(seconds: clip.loop.upperBound, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }
        let view = FollowView(track: clip.track, shownW: shown.w, shownH: shown.h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var last = -Double.infinity
        while true {
            let done: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return true }
                if isCancelled {
                    reader.cancelReading()
                    return true
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time - last >= 0.9 / Self.rate, let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
                last = time
                let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                let w = image.extent.width, h = image.extent.height
                let rect = view.rect(at: time)
                // Core Image measures from the bottom-left.
                let crop = CGRect(x: image.extent.minX + rect.minX * w, y: image.extent.minY + (1 - rect.maxY) * h,
                                  width: rect.width * w, height: rect.height * h)
                let height = (Self.width * crop.height / max(1, crop.width) / 2).rounded() * 2
                let piece = LoopFrames.cut(image, to: crop, size: CGSize(width: Self.width, height: height))
                guard let data = context.jpegRepresentation(of: piece, colorSpace: space, options: [
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6,
                ]) else { return false }
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled, bytes < Self.maxBytes else { return true }
                frames[clip.id, default: []].append((time, data))
                bytes += data.count
                return false
            }
            if done { break }
        }
    }
}
