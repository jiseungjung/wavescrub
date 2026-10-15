import AVFoundation
import CoreImage
import os

/// The part of the picture shown while following the surfer: how much of it
/// fits on screen, and how far the view has been dragged off them.
struct FollowView: Equatable, Sendable {
    var track: WaveTrack
    /// How much of the picture's width and height is shown, as a share of it:
    /// more than 1 when zoomed out past its edges.
    var shownW: CGFloat
    var shownH: CGFloat
    /// Where the view has been dragged to, as a share of what's shown.
    var look: CGPoint = .zero

    /// The part shown at this moment, as fractions of the upright picture from
    /// its top-left.
    ///
    /// Never past the picture's edge. A surfer starts a wave at its right
    /// edge, so the view waits there until they come into the middle; held
    /// to the edge frame by frame it then set off at their full speed in
    /// one jolt, and at a wide zoom it caught and let go of the top as they
    /// rose and dropped. Averaged over a second around now, it eases off
    /// the edge and back onto it instead, and is still exactly on them in
    /// between. Once the whole width or height is in view, that way the
    /// picture just sits in the middle, and they're only followed the other way.
    func rect(at time: Double) -> CGRect {
        var left: CGFloat = 0, top: CGFloat = 0
        let offsets = (-5...5).map { Double($0) * 0.1 }
        for offset in offsets {
            var c = track.center(at: time + offset)
            c.x += look.x * shownW
            c.y += look.y * shownH
            left += shownW >= 1 ? (1 - shownW) / 2 : min(max(0, c.x - shownW / 2), 1 - shownW)
            top += shownH >= 1 ? (1 - shownH) / 2 : min(max(0, c.y - shownH / 2), 1 - shownH)
        }
        return CGRect(x: left / CGFloat(offsets.count), y: top / CGFloat(offsets.count), width: shownW, height: shownH)
    }
}

/// The loop's frames around where you're sliding, decoded ahead so sliding
/// through them is smooth.
///
/// The camera stores a whole picture only about once a second; every frame
/// in between is the changes since. Seeking the player to one exact frame
/// decodes everything from the last whole picture up to it, so sliding
/// asked for that over and over and fell behind. Here each second, whole
/// picture to whole picture, is decoded once in one go, and the seconds
/// either side are got ready while you look.
///
/// Only the part around the surfer is kept, with a margin, at the video's
/// full detail (or the screen's, if that's less): shrinking whole 4K frames
/// enough to keep a few seconds of them made the zoomed-in view blurry. If
/// the zoom or the view moves past the margin, they're made again.
final class LoopFrames: @unchecked Sendable {
    /// `region` is the part of the upright picture a frame holds, as
    /// fractions of it; without one the frame is the whole picture as stored.
    typealias Frame = (time: Double, buffer: CVPixelBuffer, region: CGRect?)

    private let queue = DispatchQueue(label: "LoopFrames", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var range = CMTimeRange.zero
    /// Where each second starts: the loop's start, then each whole picture.
    private var starts: [Double] = []
    private var seconds: [Int: [Frame]] = [:]
    private var decoding: Int?
    /// The second last asked for, and which way you were going.
    private var wanted = 0
    private var direction = 1
    private var run = 0
    /// What's being shown, and on how many screen pixels top to bottom.
    private var view: FollowView?
    private var pixels: CGFloat = 0
    private var orientation = CGImagePropertyOrientation.up
    /// Changes whenever frames already made no longer fit what's shown.
    private var viewRun = 0

    /// How many seconds are kept either side of where you are.
    private let reach: Int
    /// How much more than what's shown each frame keeps, each side, as a
    /// share of it: room to pinch and drag a little before remaking them.
    private static let margin: CGFloat = 0.15
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The most pixels a frame keeps, however big the screen: 1080p's worth.
    private static let maxPixels: CGFloat = 1920 * 1080

    init(reach: Int = 2) {
        self.reach = reach
    }

    /// Called on the main queue each time another second is ready.
    var onReady: (() -> Void)?

    /// Whether frames are being got ready at all.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return asset != nil
    }

    /// Starts over for a new loop, with nothing decoded yet. The same video
    /// over a part of the loop already being got ready (as when two clips
    /// are linked) keeps what's done.
    func reset(_ asset: AVAsset?, from start: Double, to end: Double) {
        lock.lock()
        if let asset, asset === self.asset, track != nil,
           start >= range.start.seconds - 0.001, end <= range.end.seconds + 0.001 {
            lock.unlock()
            return
        }
        run += 1
        let run = run
        self.asset = asset
        track = nil
        starts = []
        seconds = [:]
        decoding = nil
        view = nil
        range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                            end: CMTime(seconds: end, preferredTimescale: 60000))
        lock.unlock()
        guard let asset else { return }
        queue.async { [weak self] in self?.findSeconds(asset, run: run) }
    }

    /// What's on screen now. Frames are made for it once it's known, and
    /// made again if the zoom, the view or the screen changes past the margin.
    func follow(_ new: FollowView, pixels newPixels: CGFloat, orientation newOrientation: CGImagePropertyOrientation) {
        lock.lock()
        defer { lock.unlock() }
        if let view, view.track == new.track, orientation == newOrientation,
           abs(log(new.shownH / view.shownH)) < 0.2,
           abs(new.look.x - view.look.x) < Self.margin * 0.7,
           abs(new.look.y - view.look.y) < Self.margin * 0.7,
           abs(log(max(1, newPixels) / max(1, pixels))) < 0.2 {
            return
        }
        view = new
        pixels = newPixels
        orientation = newOrientation
        viewRun += 1
        seconds = [:]
        decoding = nil
        pump()
    }

    /// The decoded frame showing at this moment, if its second is ready. Asks
    /// for it, and the seconds next to it, if not.
    func frame(at time: Double) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard !starts.isEmpty else { return nil }
        let i = max(0, (starts.lastIndex { $0 <= time + 0.001 }) ?? 0)
        if i != wanted {
            direction = i > wanted ? 1 : -1
            wanted = i
        }
        for key in seconds.keys where abs(key - i) > reach { seconds[key] = nil }
        if decoding == nil { pump() }
        // The last sliver of a loop can hold no frames of its own: show the
        // last one before it.
        if let second = seconds[i], second.isEmpty, i > 0 { return seconds[i - 1]?.last }
        return seconds[i]?.last { $0.time <= time + 0.001 } ?? seconds[i]?.first
    }

    /// Reads where the whole pictures are, without decoding anything.
    private func findSeconds(_ asset: AVAsset, run: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var found: AVAssetTrack?
        Task {
            found = try? await asset.loadTracks(withMediaType: .video).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let found, let reader = try? AVAssetReader(asset: asset) else { return }
        lock.lock()
        let range = range
        lock.unlock()
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: found, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }
        var starts = [range.start.seconds]
        while let sample = output.copyNextSampleBuffer() {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let partial = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if !partial, time > starts[starts.count - 1] + 0.1 { starts.append(time) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard run == self.run else { return }
        self.starts = starts
        track = found
        pump()
    }

    /// Whether there's room for more frames. Close to the phone's limit for
    /// the app, sliding does without them rather than the app being closed.
    private static var memoryToSpare: Bool {
        #if os(iOS)
        os_proc_available_memory() > 700_000_000
        #else
        true
        #endif
    }

    /// Decodes the next missing second nearest where you are, going your way
    /// first. Called with the lock held.
    private func pump() {
        guard decoding == nil, let asset, let track, let view, !starts.isEmpty, Self.memoryToSpare else { return }
        // Outward from where you are, your way first, as far as the reach.
        let order = [wanted] + (1...max(1, reach)).flatMap { [wanted + $0 * direction, wanted - $0 * direction] }
        guard let next = order.first(where: {
            starts.indices.contains($0) && seconds[$0] == nil && abs($0 - wanted) <= reach
        }) else { return }
        decoding = next
        let from = starts[next]
        let to = next + 1 < starts.count ? starts[next + 1] : range.end.seconds
        let run = run, viewRun = viewRun, pixels = pixels, orientation = orientation
        queue.async { [weak self] in
            guard let self else { return }
            let frames = self.decode(asset, track: track, from: from, to: to,
                                     view: view, pixels: pixels, orientation: orientation) {
                self.lock.lock()
                defer { self.lock.unlock() }
                return run != self.run || viewRun != self.viewRun
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard run == self.run, viewRun == self.viewRun else { return }
            self.decoding = nil
            if abs(next - self.wanted) <= self.reach { self.seconds[next] = frames }
            self.pump()
            if let onReady = self.onReady { DispatchQueue.main.async(execute: onReady) }
        }
    }

    /// Each frame upright, cut to what's shown and its margin, at the video's
    /// detail or the screen's, whichever is less.
    private func decode(_ asset: AVAsset, track: AVAssetTrack, from: Double, to: Double,
                        view: FollowView, pixels: CGFloat, orientation: CGImagePropertyOrientation,
                        stale: () -> Bool) -> [Frame] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60000),
                                       end: CMTime(seconds: to, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }
        let m = Self.margin
        var pool: CVPixelBufferPool?
        var outSize = CGSize.zero
        var frames: [Frame] = []
        // Each 4K frame is let go as soon as its part is cut out: left to the
        // end of the second, a second of them piled up and ran the phone out
        // of memory.
        while true {
            let done: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return true }
                // A new loop, or the zoom or view moved on: these are wanted no more.
                if stale() {
                    reader.cancelReading()
                    frames = []
                    return true
                }
                guard let source = CMSampleBufferGetImageBuffer(sample) else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let image = CIImage(cvPixelBuffer: source).oriented(orientation)
                let w = image.extent.width, h = image.extent.height
                let shown = view.rect(at: time)
                let region = shown.insetBy(dx: -shown.width * m, dy: -shown.height * m)
                // The same size every frame: what's shown never changes size.
                if pool == nil {
                    let sourceH = region.height * h
                    var scale = min(1, pixels * (1 + 2 * m) / sourceH)
                    let area = region.width * w * region.height * h * scale * scale
                    if area > Self.maxPixels { scale *= sqrt(Self.maxPixels / area) }
                    outSize = CGSize(width: max(2, (region.width * w * scale / 2).rounded() * 2),
                                     height: max(2, (region.height * h * scale / 2).rounded() * 2))
                    CVPixelBufferPoolCreate(nil, nil, [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        kCVPixelBufferWidthKey as String: Int(outSize.width),
                        kCVPixelBufferHeightKey as String: Int(outSize.height),
                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                    ] as CFDictionary, &pool)
                }
                guard let pool else { return true }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { return false }
                // Core Image measures from the bottom-left.
                let crop = CGRect(x: image.extent.minX + region.minX * w,
                                  y: image.extent.minY + (1 - region.maxY) * h,
                                  width: region.width * w, height: region.height * h)
                context.render(Self.cut(image, to: crop, size: outSize), to: buffer,
                               bounds: CGRect(origin: .zero, size: outSize), colorSpace: Self.sRGB)
                frames.append((time, buffer, region))
                return false
            }
            if done { break }
        }
        return frames
    }

    /// The part of `image` inside `crop`, scaled to `size`, on black, with its
    /// corner at zero. Only the part of the picture that's there is scaled:
    /// cutting a crop far bigger than the picture out of it first, as when
    /// zoomed right out on frames made zoomed in, used a great deal of memory.
    static func cut(_ image: CIImage, to crop: CGRect, size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: frame)
        let visible = image.extent.intersection(crop)
        guard !visible.isNull, !visible.isEmpty, crop.width > 0, crop.height > 0 else { return black }
        return image.cropped(to: visible)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: size.width / crop.width, y: size.height / crop.height)))
            .composited(over: black)
            .cropped(to: frame)
    }
}
