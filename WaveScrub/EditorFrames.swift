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

    /// How wide the kept frames are, in pixels: the same as the editor's
    /// video, so they look no different from it.
    static let width: CGFloat = 720
    /// At most this many frames a second; more look no smoother while sliding.
    static let rate = 30.0
    /// Stops keeping frames past this, in case of a very long export.
    static let maxBytes = 350_000_000

    /// Starts decoding in the background, the waves in the order given.
    func start(asset: AVAsset, clips: [Clip], shown: (w: CGFloat, h: CGFloat),
               orientation: CGImagePropertyOrientation) {
        // Behind anything on screen: getting frames ready mustn't hold up
        // drawing the frames already ready.
        Task.detached(priority: .utility) { [self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
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

    private let showQueue = DispatchQueue(label: "EditorFrames.show", qos: .userInteractive)
    private var request: (id: UUID, time: Double, done: @MainActor (CGImage?) -> Void)?
    private var showing = false

    /// The frame for a moment, unpacked away from the screen's drawing and
    /// handed back on the main queue: nil if it isn't ready. While one is
    /// being unpacked only the latest wanted is kept, so sliding quickly
    /// never queues up a backlog.
    func show(_ id: UUID, at time: Double, then done: @escaping @MainActor (CGImage?) -> Void) {
        lock.lock()
        request = (id, time, done)
        let start = !showing
        showing = true
        lock.unlock()
        if start { showQueue.async { [self] in showNext() } }
    }

    private func showNext() {
        lock.lock()
        guard let next = request else {
            showing = false
            lock.unlock()
            return
        }
        request = nil
        lock.unlock()
        let image = self.image(next.id, at: next.time, unpacked: true)
        DispatchQueue.main.async { MainActor.assumeIsolated { next.done(image) } }
        showNext()
    }

    /// The kept frame of this wave nearest a moment in the original video,
    /// if one is that close. Unpacked, it's ready to draw at once.
    func image(_ id: UUID, at time: Double, unpacked: Bool = false) -> CGImage? {
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
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: unpacked] as CFDictionary)
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
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85,
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
