import AVFoundation

/// The loop's frames around where you're sliding, decoded ahead so sliding
/// through them is smooth.
///
/// The camera stores a whole picture only about once a second; every frame
/// in between is the changes since. Seeking the player to one exact frame
/// decodes everything from the last whole picture up to it, so sliding
/// asked for that over and over and fell behind. Here each second, whole
/// picture to whole picture, is decoded once in one go, and the seconds
/// either side are got ready while you look. They are kept at half size,
/// which is plenty while you slide; the player's own sharp frame follows
/// once you stop.
final class LoopFrames: @unchecked Sendable {
    typealias Frame = (time: Double, buffer: CVPixelBuffer)

    private let queue = DispatchQueue(label: "LoopFrames", qos: .userInitiated)
    private let lock = NSLock()
    private var asset: AVAsset?
    private var track: AVAssetTrack?
    private var size = CGSize.zero
    private var range = CMTimeRange.zero
    /// Where each second starts: the loop's start, then each whole picture.
    private var starts: [Double] = []
    private var seconds: [Int: [Frame]] = [:]
    private var decoding: Int?
    /// The second last asked for, and which way you were going.
    private var wanted = 0
    private var direction = 1
    private var run = 0

    /// How many seconds are kept either side of where you are.
    private static let reach = 2

    /// Starts over for a new loop, with nothing decoded yet.
    func reset(_ asset: AVAsset?, from start: Double, to end: Double) {
        lock.lock()
        run += 1
        let run = run
        self.asset = asset
        track = nil
        starts = []
        seconds = [:]
        decoding = nil
        range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                            end: CMTime(seconds: end, preferredTimescale: 60000))
        lock.unlock()
        guard let asset else { return }
        queue.async { [weak self] in self?.findSeconds(asset, run: run) }
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
        for key in seconds.keys where abs(key - i) > Self.reach { seconds[key] = nil }
        if decoding == nil { pump() }
        return seconds[i]?.last { $0.time <= time + 0.001 } ?? seconds[i]?.first
    }

    /// Reads where the whole pictures are, without decoding anything.
    private func findSeconds(_ asset: AVAsset, run: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var found: AVAssetTrack?
        var natural = CGSize.zero
        Task {
            found = try? await asset.loadTracks(withMediaType: .video).first
            natural = (try? await found?.load(.naturalSize)) ?? .zero
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
        size = CGSize(width: (natural.width / 2).rounded(), height: (natural.height / 2).rounded())
        pump()
    }

    /// Decodes the next missing second nearest where you are, going your way
    /// first. Called with the lock held.
    private func pump() {
        guard decoding == nil, let asset, let track, !starts.isEmpty else { return }
        let order = [0, direction, -direction, 2 * direction, -2 * direction].map { wanted + $0 }
        guard let next = order.first(where: { starts.indices.contains($0) && seconds[$0] == nil }) else { return }
        decoding = next
        let from = starts[next]
        let to = next + 1 < starts.count ? starts[next + 1] : range.end.seconds
        let size = size, run = run
        queue.async { [weak self] in
            let frames = Self.decode(asset, track: track, size: size, from: from, to: to)
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard run == self.run else { return }
            self.decoding = nil
            if abs(next - self.wanted) <= Self.reach { self.seconds[next] = frames }
            self.pump()
        }
    }

    private static func decode(_ asset: AVAsset, track: AVAssetTrack, size: CGSize, from: Double, to: Double) -> [Frame] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 60000),
                                       end: CMTime(seconds: to, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer))
        }
        return frames
    }
}
