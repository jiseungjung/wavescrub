import AVFoundation
import CoreGraphics
import Vision

/// Where you are through one wave, worked out once and replayed by the loop
/// screen. Positions are fractions of the picture, measured from its top-left.
struct WaveTrack: Codable, Equatable {
    var start: Double
    var end: Double
    /// Seconds between stored positions.
    var step: Double
    var xs: [Float]
    var ys: [Float]
    /// How tall you are, as a fraction of the picture's height. Sets the zoom.
    var height: Float

    func center(at time: Double) -> CGPoint {
        guard !xs.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let f = min(max(0, (time - start) / step), Double(xs.count - 1))
        let i = Int(f)
        let j = min(i + 1, xs.count - 1)
        let a = Float(f - Double(i))
        return CGPoint(x: CGFloat(xs[i] + (xs[j] - xs[i]) * a), y: CGFloat(ys[i] + (ys[j] - ys[i]) * a))
    }
}

/// Follows one surfer from a wave's bookmark to the end of their ride, on the
/// phone, with Apple's own tracker. Nothing leaves the device.
///
/// At the bookmark you are at the far right edge, about to take off. Apple's
/// person finder can't see anyone that small in a whole 4K frame, so you are
/// found the plain way: of the dark, moving shapes in the right fifth of the
/// picture, the one that travels furthest left over the next second and a
/// half while staying dark. That passes over paddlers waiting at the edge
/// (they barely move), the rider on the wave before (further left, slower)
/// and ripples near the camera (the tracker slides onto blue water).
///
/// The tracker loses you when someone crosses you: it slides onto them and
/// then freezes. So whenever it loses you, freezes, or its box holds no
/// wetsuit-dark pixels, it looks for a dark moving shape where your speed says
/// you should be by now, and picks you up from there.
///
/// The ride is over at the first of three things:
///
/// - you can't be picked back up for half a second (a wipeout, or gone under
///   the whitewater: the box sits on foam with nothing dark in it),
/// - you stop travelling left with the wave (you kicked out and are lying on
///   your board, still in view),
/// - you reach the left edge of the picture.
///
/// Apple's person finder was tried for the second case and almost never saw a
/// rider this small, so it is not used.
///
/// The numbers below were measured on three rides filmed in 4K: one kicked
/// out, one swallowed by whitewater, one wiped out.
enum WaveTracker {
    enum Failure: Error { case noVideo, nobodyAtBookmark, unreadable }

    /// Nobody's ride is longer than this; stop reading there regardless.
    static let longestRide = 45.0
    /// The tracker's own confidence, below which it has lost you…
    static let lostConfidence: Float = 0.3
    /// Lost, and not picked back up, for this long: the ride is over.
    static let lostFor = 0.5
    /// Below this share of dark pixels the box holds no wetsuit: it is on
    /// water or foam. A rider's box measured 15–35%.
    static let emptyBox = 0.05
    /// How far from where your speed puts you a shape may be, as a share of
    /// the picture, to pick you back up.
    static let searchReach = 0.05
    /// Over this many seconds, a rider travels well over a tenth of the
    /// picture; one who has kicked out barely moves at all.
    static let stallWindow = 2.5
    /// Less than this share of the picture's width, leftwards, over the window
    /// is a stop. The slowest stretch of a real ride measured about 3%.
    static let stallDistance = 0.015
    /// How tall a surfer is, as a share of the picture's height, in the clips
    /// measured. Sizes the box the tracker starts from.
    static let riderHeight = 0.042
    /// Seconds of video read at a time when following you backwards. Each
    /// piece is held whole, so this keeps memory to a few dozen megabytes.
    static let backPiece = 0.5

    // Finding you at the bookmark.
    /// Only shapes this far right are candidates.
    static let rightEdge = 0.8
    /// Brightness (0–255) below which a pixel is wetsuit, not water or foam.
    static let darkLuma: UInt8 = 60
    /// How much brighter or darker a pixel must get to count as moving.
    static let movedLuma = 20
    /// Frames between the two compared for movement.
    static let compareFrames = 5
    /// The smallest shape that can be a person, as a share of the picture.
    static let smallestShape = 0.00007
    /// How long each candidate is watched for.
    static let watchFor = 1.5
    /// Below this share of dark pixels, a candidate's box has slid onto water.
    static let stillDark = 0.10

    /// `tap`, when given, is where you tapped yourself and on which frame: the
    /// bookmark's, or a later one where you were easier to see. From a later
    /// frame you are also followed backwards to the bookmark, so the loop
    /// still starts there.
    ///
    /// `log`, when given, receives one line per frame and the reason the ride
    /// ended. Only the Mac test run uses it.
    static func track(asset: AVAsset, from start: Double, tap: (point: CGPoint, time: Double)?,
                      log: ((String) -> Void)? = nil) async throws -> WaveTrack {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let duration = try await asset.load(.duration)
        let fps = Double(Frames.rate)
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        let picture = CGSize(width: abs(turned.width), height: abs(turned.height))
        let frames = Frames(asset: asset, track: videoTrack, transform: transform, picture: picture,
                            duration: duration)
        // Frames arrive already turned the right way up.
        let orientation = CGImagePropertyOrientation.up

        let seed: CGRect
        let seedTime: Double
        if let tap {
            seed = riderBox(at: tap.point, picture: picture)
            // On the same beat as the frames read from the bookmark.
            seedTime = start + max(0, ((tap.time - start) * fps).rounded()) / fps
        } else {
            guard let found = try findRider(frames, start: start, orientation: orientation, log: log) else {
                log?("end,nobody at the bookmark")
                throw Failure.nobodyAtBookmark
            }
            seed = found.0
            seedTime = found.1
        }
        log?(String(format: "seed,%.3f,%.4f,%.4f", seedTime, seed.midX, seed.midY))
        try Task.checkCancellation()

        var follower = Follower(seed: seed, picture: picture, orientation: orientation)
        if seedTime > start + 0.5 / fps {
            follower = try followBack(frames, from: seedTime, to: start, seed: seed, log: log)
        }

        let (reader, output) = try frames.reader(from: seedTime, seconds: longestRide)
        defer { reader.cancelReading() }

        var end: Double?
        var reason = "the clip ran out"

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = sample.presentationTimeStamp.seconds
            // The reader starts at the keyframe before; skip up to the start.
            guard t >= seedTime - 0.5 / fps, let buffer = sample.imageBuffer, let luma = Luma(buffer) else { continue }
            guard let step = try follower.follow(buffer, luma: luma, at: t) else {
                reason = "the tracker returned nothing"
                break
            }
            if let since = follower.lostSince, t - since >= lostFor {
                end = since
                reason = "lost you and couldn't pick you back up"
                log?(step.line(t))
                break
            }
            log?(step.line(t))
            follower.record(step.box, at: t)

            let x = Double(step.box.midX)
            if x < 0.015 { end = t; reason = "you reached the left edge"; break }

            let times = follower.times, xs = follower.xs
            if follower.lostSince == nil, t - times[0] >= stallWindow,
               let from = times.firstIndex(where: { $0 >= t - stallWindow }),
               xs[from] - x < stallDistance {
                // End where you were furthest along, just as you turned off it.
                let furthest = (from..<xs.count).min { xs[$0] < xs[$1] } ?? from
                end = min(t, times[furthest] + 0.5)
                reason = "you stopped moving left"
                break
            }
        }
        let times = follower.times, xs = follower.xs, ys = follower.ys
        guard !times.isEmpty else { throw Failure.unreadable }
        let rideEnd = end ?? times[times.count - 1]
        log?(String(format: "end,%@,%.3f", reason, rideEnd))

        // Half a second either side, so the zoom glides instead of shaking with
        // every wobble of the box.
        let half = max(1, Int(fps / 2))
        let kept = times.lastIndex(where: { $0 <= rideEnd }).map { $0 + 1 } ?? times.count
        func smooth(_ v: [Double], _ i: Int) -> Float {
            let lo = max(0, i - half), hi = min(kept - 1, i + half)
            return Float(v[lo...hi].reduce(0, +) / Double(hi - lo + 1))
        }
        let every = max(1, Int((fps / 15).rounded()))
        let picked = Array(stride(from: 0, to: kept, by: every))
        return WaveTrack(start: times[0], end: rideEnd, step: Double(every) / fps,
                         xs: picked.map { smooth(xs, $0) }, ys: picked.map { smooth(ys, $0) },
                         height: Float(seed.height))
    }

    /// Follows you from where you were tapped back to the bookmark, and hands
    /// over that stretch, in time order, to carry on forwards from. Video can
    /// only be read forwards, so it is read a short piece at a time, from the
    /// last piece to the first, and each piece played backwards.
    private static func followBack(_ frames: Frames, from seedTime: Double, to start: Double, seed: CGRect,
                                   log: ((String) -> Void)?) throws -> Follower {
        let fps = Double(Frames.rate)
        var follower = Follower(seed: seed, picture: frames.picture, orientation: .up)
        var pieceEnd = seedTime
        reading: while pieceEnd > start + 0.5 / fps {
            let pieceStart = max(start, pieceEnd - backPiece)
            let (reader, output) = try frames.reader(from: pieceStart, seconds: pieceEnd - pieceStart, copies: true)
            var piece: [(Double, CVPixelBuffer)] = []
            while let sample = output.copyNextSampleBuffer() {
                let t = sample.presentationTimeStamp.seconds
                guard t >= pieceStart - 0.5 / fps, t < pieceEnd - 0.5 / fps, let buffer = sample.imageBuffer else { continue }
                piece.append((t, buffer))
            }
            reader.cancelReading()
            for (t, buffer) in piece.reversed() {
                try Task.checkCancellation()
                guard let luma = Luma(buffer), let step = try follower.follow(buffer, luma: luma, at: t) else {
                    break reading
                }
                // Lost for good going back: stay where you were last seen.
                var box = step.box
                if let since = follower.lostSince, since - t >= lostFor, let x = follower.xs.last, let y = follower.ys.last {
                    box = riderBox(at: CGPoint(x: x, y: y), picture: frames.picture)
                }
                box.origin.x = min(max(box.origin.x, -box.width / 2), 1 - box.width / 2)
                box.origin.y = min(max(box.origin.y, -box.height / 2), 1 - box.height / 2)
                log?("back" + step.line(t).dropFirst("frame".count))
                follower.record(box, at: t)
            }
            pieceEnd = pieceStart
        }
        // Forwards from here, a fresh tracker with the way back as your
        // history, in time order.
        var forward = Follower(seed: seed, picture: frames.picture, orientation: .up)
        forward.times = follower.times.reversed()
        forward.xs = follower.xs.reversed()
        forward.ys = follower.ys.reversed()
        return forward
    }

    // MARK: Finding you at the bookmark

    private struct Candidate {
        var observation: VNDetectedObjectObservation
        let startX: CGFloat
        var x: CGFloat
        var alive = true
    }

    /// The rider at the right edge, and the moment their box was taken.
    private static func findRider(_ frames: Frames, start: Double, orientation: CGImagePropertyOrientation,
                                  log: ((String) -> Void)?) throws -> (CGRect, Double)? {
        let fps = Double(Frames.rate), picture = frames.picture
        let (reader, output) = try frames.reader(from: start, seconds: watchFor + 1)
        defer { reader.cancelReading() }

        let sequence = VNSequenceRequestHandler()
        var first: Luma?
        var candidates: [Candidate] = []
        var shapes: (boxes: [CGRect], time: Double)?
        var frame = -1

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = sample.presentationTimeStamp.seconds
            guard t >= start - 0.5 / fps, let buffer = sample.imageBuffer else { continue }
            frame += 1
            if frame == 0 {
                first = Luma(buffer)
                continue
            }
            if frame < compareFrames { continue }
            if frame == compareFrames {
                guard let first, let now = Luma(buffer) else { return nil }
                let boxes = movingDarkShapes(now: now, before: first, orientation: orientation)
                    .filter { $0.x > rightEdge }
                    .sorted { $0.x > $1.x }
                    .prefix(8)
                    .map { riderBox(at: $0, picture: picture) }
                shapes = (boxes, t)
                candidates = boxes.map {
                    Candidate(observation: VNDetectedObjectObservation(boundingBox: visionRect($0)),
                              startX: $0.midX, x: $0.midX)
                }
                for b in boxes { log?(String(format: "candidate,%.4f,%.4f", b.midX, b.midY)) }
                continue
            }
            guard let shapes, !candidates.isEmpty else { return nil }
            let checkDark = (frame - compareFrames) % 9 == 0
            let luma = checkDark ? Luma(buffer) : nil
            for i in candidates.indices where candidates[i].alive {
                let request = VNTrackObjectRequest(detectedObjectObservation: candidates[i].observation)
                request.trackingLevel = .accurate
                guard (try? sequence.perform([request], on: buffer, orientation: orientation)) != nil,
                      let next = request.results?.first as? VNDetectedObjectObservation else {
                    candidates[i].alive = false
                    continue
                }
                candidates[i].observation = next
                let box = topLeftRect(next.boundingBox)
                candidates[i].x = box.midX
                if let luma, luma.darkShare(in: box, orientation: orientation) < stillDark {
                    candidates[i].alive = false
                }
            }
            if t - shapes.time >= watchFor { break }
        }
        guard let shapes else { return nil }
        for (i, c) in candidates.enumerated() {
            log?(String(format: "watched,%ld,%.4f,%.4f,%@", i, c.startX, c.startX - c.x, c.alive ? "dark" : "dropped"))
        }
        let best = candidates.indices
            .filter { candidates[$0].alive && candidates[$0].startX - candidates[$0].x > 0.01 }
            .max { candidates[$0].startX - candidates[$0].x < candidates[$1].startX - candidates[$1].x }
        guard let best else { return nil }
        return (shapes.boxes[best], shapes.time)
    }

    /// Centers of the dark shapes that changed between the two frames.
    fileprivate static func movingDarkShapes(now: Luma, before: Luma,
                                         orientation: CGImagePropertyOrientation) -> [CGPoint] {
        let w = now.width, h = now.height
        guard before.width == w, before.height == h else { return [] }
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where now.values[i] < darkLuma
            && abs(Int(now.values[i]) - Int(before.values[i])) > movedLuma {
            mask[i] = true
        }
        // Grow each speck a little, so a body broken up by spray is one shape.
        let r = 1
        var grown = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    for xx in max(0, x - r)...min(w - 1, x + r) { grown[yy * w + xx] = true }
                }
            }
        }
        var seen = [Bool](repeating: false, count: w * h)
        let smallest = Int(smallestShape * Double(w * h))
        var centers: [CGPoint] = []
        for s in 0..<(w * h) where grown[s] && !seen[s] {
            var stack = [s]
            seen[s] = true
            var count = 0, sx = 0, sy = 0
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                sx += x
                sy += y
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let n = ny * w + nx
                    if grown[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            guard count >= smallest else { continue }
            let c = upright(CGPoint(x: (Double(sx) / Double(count) + 0.5) / Double(w),
                                    y: (Double(sy) / Double(count) + 0.5) / Double(h)), orientation)
            centers.append(c)
        }
        return centers
    }

    /// A box the size of a surfer, centered on a point.
    fileprivate static func riderBox(at p: CGPoint, picture: CGSize) -> CGRect {
        let h = CGFloat(riderHeight)
        let w = h * picture.height / max(1, picture.width) * 0.9
        return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
    }

    /// Where your last second of travel puts you at time `t`, whether you're
    /// being followed forwards or backwards.
    fileprivate static func predicted(at t: Double, times: [Double], xs: [Double], ys: [Double]) -> CGPoint? {
        guard let lastTime = times.last else { return nil }
        let from = times.firstIndex { abs($0 - lastTime) <= 1 } ?? 0
        let span = lastTime - times[from]
        let n = times.count - 1
        let vx = abs(span) > 0.2 ? (xs[n] - xs[from]) / span : 0
        let vy = abs(span) > 0.2 ? (ys[n] - ys[from]) / span : 0
        return CGPoint(x: xs[n] + vx * (t - lastTime), y: ys[n] + vy * (t - lastTime))
    }

    /// Reads the video at about 1080 lines instead of 4K, turned upright on
    /// the way. Tracking a 4K frame took over a minute for a 15-second ride;
    /// a rider is still fifty pixels tall at this size, plenty to follow.
    struct Frames {
        let asset: AVAsset
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let picture: CGSize
        let duration: CMTime

        static let lines: CGFloat = 1080
        /// Frames a second looked at: half of what was filmed, which halves the
        /// work. The path is smoothed over half a second anyway.
        static let rate = 15

        func reader(from start: Double, seconds: Double, copies: Bool = false) throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
            let scale = min(1, Self.lines / max(1, min(picture.width, picture.height)))
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: (picture.width * scale / 2).rounded() * 2,
                                            height: (picture.height * scale / 2).rounded() * 2)
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.rate))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.videoComposition = composition
            output.alwaysCopiesSampleData = copies
            reader.add(output)
            // Never past the end of the video, or the reader refuses to start.
            let from = CMTime(seconds: start, preferredTimescale: 60000)
            let to = CMTimeMinimum(duration, from + CMTime(seconds: seconds, preferredTimescale: 600))
            reader.timeRange = CMTimeRange(start: from, end: to)
            guard reader.startReading() else { throw Failure.unreadable }
            return (reader, output)
        }
    }

    // MARK: Coordinates

    /// Vision measures from the bottom-left; everything else here from the top-left.
    fileprivate static func visionRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    fileprivate static func topLeftRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// A point in the stored frame, as it sits in the picture you see.
    fileprivate static func upright(_ p: CGPoint, _ o: CGImagePropertyOrientation) -> CGPoint {
        switch o {
        case .right: CGPoint(x: 1 - p.y, y: p.x)
        case .left: CGPoint(x: p.y, y: 1 - p.x)
        case .down: CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: p
        }
    }

    /// A point in the picture you see, as it sits in the stored frame.
    fileprivate static func stored(_ p: CGPoint, _ o: CGImagePropertyOrientation) -> CGPoint {
        switch o {
        case .right: CGPoint(x: p.y, y: 1 - p.x)
        case .left: CGPoint(x: 1 - p.y, y: p.x)
        case .down: CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: p
        }
    }
}

/// Apple's tracker, kept on you frame after frame, and picked back up from
/// where your speed says you should be whenever it loses you. Frames may come
/// forwards or backwards in time.
private struct Follower {
    struct Step {
        var box: CGRect
        let confidence: Float
        let dark: Double
        var note: String

        func line(_ t: Double) -> String {
            String(format: "frame,%.3f,%.4f,%.4f,%.3f,%.2f,%@", t, box.midX, box.midY, confidence, dark, note)
        }
    }

    let picture: CGSize
    let orientation: CGImagePropertyOrientation
    private let sequence = VNSequenceRequestHandler()
    private var last: VNDetectedObjectObservation
    private var previous: CGRect?
    private var frozen = 0
    private var recent: [Luma] = []
    var times: [Double] = []
    var xs: [Double] = []
    var ys: [Double] = []
    /// When you were lost, if you still are.
    private(set) var lostSince: Double?

    init(seed: CGRect, picture: CGSize, orientation: CGImagePropertyOrientation) {
        self.picture = picture
        self.orientation = orientation
        last = VNDetectedObjectObservation(boundingBox: WaveTracker.visionRect(seed))
    }

    /// Where you are in this frame; nil if the tracker gave up altogether.
    mutating func follow(_ buffer: CVPixelBuffer, luma: Luma, at t: Double) throws -> Step? {
        recent.append(luma)
        if recent.count > WaveTracker.compareFrames + 1 { recent.removeFirst() }

        let request = VNTrackObjectRequest(detectedObjectObservation: last)
        request.trackingLevel = .accurate
        try sequence.perform([request], on: buffer, orientation: orientation)
        guard let found = request.results?.first as? VNDetectedObjectObservation else { return nil }
        last = found
        var box = WaveTracker.topLeftRect(found.boundingBox)
        frozen = previous.map { abs($0.midX - box.midX) < 1e-6 && abs($0.midY - box.midY) < 1e-6 } == true ? frozen + 1 : 0
        previous = box
        let dark = luma.darkShare(in: box, orientation: orientation)
        var note = "ok"

        if found.confidence < WaveTracker.lostConfidence || frozen >= 2 || dark < WaveTracker.emptyBox {
            note = found.confidence < WaveTracker.lostConfidence ? "low" : frozen >= 2 ? "frozen" : "empty"
            let guess = WaveTracker.predicted(at: t, times: times, xs: xs, ys: ys)
            let reach = WaveTracker.searchReach
            if let guess, recent.count > WaveTracker.compareFrames,
               let p = WaveTracker.movingDarkShapes(now: luma, before: recent[0], orientation: orientation)
                   .filter({ abs($0.x - guess.x) < reach && abs($0.y - guess.y) < reach })
                   .min(by: { hypot($0.x - guess.x, $0.y - guess.y) < hypot($1.x - guess.x, $1.y - guess.y) }) {
                box = WaveTracker.riderBox(at: p, picture: picture)
                last = VNDetectedObjectObservation(boundingBox: WaveTracker.visionRect(box))
                previous = nil
                frozen = 0
                lostSince = nil
                note += "+found"
            } else {
                if lostSince == nil { lostSince = t }
                // Until you're found again, carry on where your speed says.
                if let guess { box = WaveTracker.riderBox(at: guess, picture: picture) }
            }
        } else {
            lostSince = nil
        }
        return Step(box: box, confidence: found.confidence, dark: dark, note: note)
    }

    mutating func record(_ box: CGRect, at t: Double) {
        times.append(t)
        xs.append(Double(box.midX))
        ys.append(Double(box.midY))
    }
}

/// A frame's brightness, one value for every few pixels: plenty to tell a
/// black wetsuit from blue water, and small enough to scan quickly.
private struct Luma {
    let width: Int
    let height: Int
    let values: [UInt8]

    init?(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, max(bw, bh) / 480)
        let w = bw / step, h = bh / step
        let p = base.assumingMemoryBound(to: UInt8.self)
        var values = [UInt8](repeating: 0, count: w * h)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let line = p + y * step * row
                for x in 0..<w {
                    let px = line + x * step * 4
                    // Blue, green, red: weighted as the eye sees brightness.
                    out[y * w + x] = UInt8((Int(px[0]) * 29 + Int(px[1]) * 150 + Int(px[2]) * 77) >> 8)
                }
            }
        }
        width = w
        height = h
        self.values = values
    }

    /// The share of the box that is wetsuit-dark. The box is in the picture
    /// you see; this frame is stored however the camera held it.
    func darkShare(in box: CGRect, orientation: CGImagePropertyOrientation) -> Double {
        let a = WaveTracker.stored(CGPoint(x: box.minX, y: box.minY), orientation)
        let b = WaveTracker.stored(CGPoint(x: box.maxX, y: box.maxY), orientation)
        let x0 = max(0, Int(min(a.x, b.x) * CGFloat(width))), x1 = min(width - 1, Int(max(a.x, b.x) * CGFloat(width)))
        let y0 = max(0, Int(min(a.y, b.y) * CGFloat(height))), y1 = min(height - 1, Int(max(a.y, b.y) * CGFloat(height)))
        guard x1 >= x0, y1 >= y0 else { return 0 }
        var dark = 0
        for y in y0...y1 {
            for x in x0...x1 where values[y * width + x] < WaveTracker.darkLuma { dark += 1 }
        }
        return Double(dark) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
    }
}
