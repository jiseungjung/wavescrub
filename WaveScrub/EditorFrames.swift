import AVFoundation
import CoreImage
import Foundation

/// Every frame of each wave, cut as it will be exported and kept small, so
/// sliding through the export editor shows each one at once.
///
/// Seeking the video to an exact frame means decoding from the last whole
/// picture, about a second back, then cutting it out: slower than a finger
/// moves, so the picture trailed behind. Here each wave is decoded once,
/// straight through, as soon as the editor opens. Frames are kept by their
/// moment in the original video, so trimming, reordering and changing
/// speed all use the same ones. A wave stretched past what's ready gets the
/// new part added; a wave zoomed differently is made again.
final class EditorFrames: @unchecked Sendable {
    private struct Job {
        let id: UUID
        let range: ClosedRange<Double>
        let track: WaveTrack
        let shown: (w: CGFloat, h: CGFloat)
        let generation: Int
    }

    private let lock = NSLock()
    private var frames: [UUID: [(time: Double, data: Data)]] = [:]
    private var bytes = 0
    private var cancelled = false
    private var jobs: [Job] = []
    private var working = false
    /// Goes up each time a wave's frames are thrown away to be made again,
    /// so work on the old ones stops.
    private var generations: [UUID: Int] = [:]
    private var asset: AVAsset?
    private var orientation = CGImagePropertyOrientation.up

    /// How wide the kept frames are, in pixels: the same as the editor's
    /// video, so they look no different from it.
    static let width: CGFloat = 720
    /// At most this many frames a second; more look no smoother while sliding.
    static let rate = 30.0
    /// Stops keeping frames past this, in case of a very long export.
    static let maxBytes = 350_000_000

    func setUp(asset: AVAsset, orientation: CGImagePropertyOrientation) {
        lock.lock()
        self.asset = asset
        self.orientation = orientation
        lock.unlock()
    }

    /// Gets this part of a wave ready, cut with this view. `fresh` throws
    /// away what was made before, for a new zoom.
    func want(_ id: UUID, range: ClosedRange<Double>, track: WaveTrack, shown: (w: CGFloat, h: CGFloat), fresh: Bool) {
        lock.lock()
        if fresh {
            generations[id, default: 0] += 1
            bytes -= frames[id]?.reduce(0) { $0 + $1.data.count } ?? 0
            frames[id] = nil
            jobs.removeAll { $0.id == id }
        }
        jobs.append(Job(id: id, range: range, track: track, shown: shown, generation: generations[id, default: 0]))
        let start = !working
        working = true
        lock.unlock()
        if start {
            // Behind anything on screen: getting frames ready mustn't hold up
            // drawing the frames already ready.
            Task.detached(priority: .utility) { [self] in await work() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        frames = [:]
        jobs = []
        lock.unlock()
    }

    private func work() async {
        lock.lock()
        let asset = asset, orientation = orientation
        lock.unlock()
        guard let asset, let track = try? await asset.loadTracks(withMediaType: .video).first else {
            lock.lock()
            working = false
            lock.unlock()
            return
        }
        let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
        while true {
            lock.lock()
            guard !cancelled, !jobs.isEmpty else {
                working = false
                lock.unlock()
                return
            }
            let job = jobs.removeFirst()
            lock.unlock()
            decode(asset, track: track, job: job, orientation: orientation, context: context)
        }
    }

    private func isStale(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || generations[job.id, default: 0] != job.generation
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

    /// Where `time` goes in a list in time order.
    private static func index(of time: Double, in list: [(time: Double, data: Data)]) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The kept frame of this wave nearest a moment in the original video,
    /// if one is that close. Unpacked, it's ready to draw at once.
    func image(_ id: UUID, at time: Double, unpacked: Bool = false) -> CGImage? {
        lock.lock()
        let list = frames[id] ?? []
        lock.unlock()
        guard !list.isEmpty else { return nil }
        let lo = Self.index(of: time, in: list)
        let best = [lo - 1, lo].filter { list.indices.contains($0) }
            .min { abs(list[$0].time - time) < abs(list[$1].time - time) } ?? 0
        guard abs(list[best].time - time) < 1.5 / Self.rate,
              let source = CGImageSourceCreateWithData(list[best].data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: unpacked] as CFDictionary)
    }

    private func decode(_ asset: AVAsset, track: AVAssetTrack, job: Job,
                        orientation: CGImagePropertyOrientation, context: CIContext) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: job.range.lowerBound, preferredTimescale: 60000),
                                       end: CMTime(seconds: job.range.upperBound, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }
        let view = FollowView(track: job.track, shownW: job.shown.w, shownH: job.shown.h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var last = -Double.infinity
        while true {
            let done: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return true }
                if isStale(job) {
                    reader.cancelReading()
                    return true
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time - last >= 0.9 / Self.rate, let buffer = CMSampleBufferGetImageBuffer(sample) else { return false }
                last = time
                lock.lock()
                let have = frames[job.id] ?? []
                lock.unlock()
                // Already made, from an earlier part asked for.
                let i = Self.index(of: time, in: have)
                if [i - 1, i].contains(where: { have.indices.contains($0) && abs(have[$0].time - time) < 0.5 / Self.rate }) {
                    return false
                }
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
                guard !cancelled, generations[job.id, default: 0] == job.generation, bytes < Self.maxBytes else { return true }
                var list = frames[job.id] ?? []
                list.insert((time, data), at: Self.index(of: time, in: list))
                frames[job.id] = list
                bytes += data.count
                return false
            }
            if done { break }
        }
    }
}
