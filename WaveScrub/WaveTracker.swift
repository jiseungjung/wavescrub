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
/// The ride is over at the first of four things:
///
/// - the tracker says it has lost you (a wipeout),
/// - nobody is inside the box any more (you went under the whitewater, and the
///   tracker has slid onto the foam without noticing),
/// - you stop travelling left with the wave (you kicked out and are lying on
///   your board — still in view, so neither of the others fires),
/// - you reach the left edge of the picture.
///
/// The numbers below were measured on three rides filmed in 4K: one kicked
/// out, one swallowed by whitewater, one wiped out.
enum WaveTracker {
    enum Failure: Error { case noVideo, nobodyAtBookmark, unreadable }

    /// Nobody's ride is longer than this; stop reading there regardless.
    static let longestRide = 45.0
    /// The tracker's own confidence, below which it has lost you…
    static let lostConfidence: Float = 0.3
    /// …for this long in a row.
    static let lostFor = 0.25
    /// No person found in the box for this long means you've gone under.
    static let goneFor = 1.2
    /// Over this many seconds, a rider travels well over a tenth of the
    /// picture; one who has kicked out barely moves at all.
    static let stallWindow = 2.5
    /// Less than this share of the picture's width, leftwards, over the window
    /// is a stop. The slowest stretch of a real ride measured about 3%.
    static let stallDistance = 0.015
    /// How tall a surfer is, as a share of the picture's height, in the clips
    /// measured. Sizes the box the tracker starts from.
    static let riderHeight = 0.042

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

    /// `log`, when given, receives one line per frame and the reason the ride
    /// ended. Only the Mac test run uses it.
    static func track(asset: AVAsset, from start: Double, tap: CGPoint?,
                      log: ((String) -> Void)? = nil) async throws -> WaveTrack {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform, rate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let fps = rate > 0 ? Double(rate) : 30
        let orientation = orientation(of: transform)
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        let picture = CGSize(width: abs(turned.width), height: abs(turned.height))

        let seed: CGRect
        let seedTime: Double
        if let tap {
            seed = riderBox(at: tap, picture: picture)
            seedTime = start
        } else {
            guard let found = try findRider(asset: asset, track: videoTrack, start: start, fps: fps,
                                            orientation: orientation, picture: picture, log: log) else {
                log?("end,nobody at the bookmark")
                throw Failure.nobodyAtBookmark
            }
            seed = found.0
            seedTime = found.1
        }
        log?(String(format: "seed,%.3f,%.4f,%.4f", seedTime, seed.midX, seed.midY))
        try Task.checkCancellation()

        let (reader, output) = try makeReader(asset: asset, track: videoTrack, from: seedTime, seconds: longestRide)
        defer { reader.cancelReading() }

        let sequence = VNSequenceRequestHandler()
        var last = VNDetectedObjectObservation(boundingBox: visionRect(seed))
        var times: [Double] = []
        var xs: [Double] = []
        var ys: [Double] = []
        var lowSince: Double?
        var lastSeen: Double?
        var sightings = 0
        var end: Double?
        var reason = "the clip ran out"

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = sample.presentationTimeStamp.seconds
            // The reader starts at the keyframe before; skip up to the start.
            guard t >= seedTime - 0.5 / fps, let buffer = sample.imageBuffer else { continue }

            let request = VNTrackObjectRequest(detectedObjectObservation: last)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: buffer, orientation: orientation)
            guard let found = request.results?.first else { reason = "the tracker returned nothing"; break }
            last = found
            let box = topLeftRect(found.boundingBox)
            let x = Double(box.midX)
            times.append(t)
            xs.append(x)
            ys.append(Double(box.midY))

            // Five times a second, check there is still a person in the box.
            // Only trusted once it has seen you a few times: a rider small or
            // blurred enough to be missed from the start must not end at once.
            var person = "-"
            if times.count % 6 == 1 {
                let seen = personInside(box, buffer: buffer, orientation: orientation)
                person = seen ? "1" : "0"
                if seen {
                    lastSeen = t
                    sightings += 1
                }
            }
            log?(String(format: "frame,%.3f,%.4f,%.4f,%.3f,%@", t, x, box.midY, found.confidence, person))

            if found.confidence < lostConfidence {
                if lowSince == nil { lowSince = t }
                if let since = lowSince, t - since >= lostFor { end = since; reason = "the tracker lost you"; break }
            } else {
                lowSince = nil
            }

            if x < 0.015 { end = t; reason = "you reached the left edge"; break }

            if sightings >= 3, let seen = lastSeen, t - seen > goneFor {
                end = seen + 0.3
                reason = "nobody in the box"
                break
            }

            if t - seedTime >= stallWindow,
               let from = times.firstIndex(where: { $0 >= t - stallWindow }),
               xs[from] - x < stallDistance {
                // End where you were furthest along, just as you turned off it.
                let furthest = (from..<xs.count).min { xs[$0] < xs[$1] } ?? from
                end = min(t, times[furthest] + 0.5)
                reason = "you stopped moving left"
                break
            }
        }
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

    // MARK: Finding you at the bookmark

    private struct Candidate {
        var observation: VNDetectedObjectObservation
        let startX: CGFloat
        var x: CGFloat
        var alive = true
    }

    /// The rider at the right edge, and the moment their box was taken.
    private static func findRider(asset: AVAsset, track: AVAssetTrack, start: Double, fps: Double,
                                  orientation: CGImagePropertyOrientation, picture: CGSize,
                                  log: ((String) -> Void)?) throws -> (CGRect, Double)? {
        let (reader, output) = try makeReader(asset: asset, track: track, from: start, seconds: watchFor + 1)
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
                      let next = request.results?.first else {
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

    /// Centers of dark shapes that changed between the two frames, rightmost
    /// first, at most eight.
    private static func movingDarkShapes(now: Luma, before: Luma,
                                         orientation: CGImagePropertyOrientation) -> [CGPoint] {
        let w = now.width, h = now.height
        guard before.width == w, before.height == h else { return [] }
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where now.values[i] < darkLuma
            && abs(Int(now.values[i]) - Int(before.values[i])) > movedLuma {
            mask[i] = true
        }
        // Grow each speck a little, so a body broken up by spray is one shape.
        let r = 2
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
            if c.x > rightEdge { centers.append(c) }
        }
        return Array(centers.sorted { $0.x > $1.x }.prefix(8))
    }

    /// A box the size of a surfer, centered on a point.
    private static func riderBox(at p: CGPoint, picture: CGSize) -> CGRect {
        let h = CGFloat(riderHeight)
        let w = h * picture.height / max(1, picture.width) * 0.9
        return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
    }

    /// Whether the person finder sees anyone in and just around the box.
    private static func personInside(_ box: CGRect, buffer: CVPixelBuffer,
                                     orientation: CGImagePropertyOrientation) -> Bool {
        let area = box.insetBy(dx: -box.width, dy: -box.height / 2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !area.isNull, area.width > 0, area.height > 0 else { return false }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        request.regionOfInterest = visionRect(area)
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])
        return !(request.results ?? []).isEmpty
    }

    private static func makeReader(asset: AVAsset, track: AVAssetTrack, from start: Double,
                                   seconds: Double) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 600))
        guard reader.startReading() else { throw Failure.unreadable }
        return (reader, output)
    }

    // MARK: Coordinates

    /// Vision measures from the bottom-left; everything else here from the top-left.
    private static func visionRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    private static func topLeftRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Which way up the stored frames are, so Vision sees them as you filmed.
    private static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
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

/// A frame's brightness, one value for every few pixels: plenty to tell a
/// black wetsuit from blue water, and small enough to scan quickly.
private struct Luma {
    let width: Int
    let height: Int
    let values: [UInt8]

    init?(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let bw = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let bh = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let step = max(1, max(bw, bh) / 960)
        let w = bw / step, h = bh / step
        let p = base.assumingMemoryBound(to: UInt8.self)
        var values = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = p + y * step * row
            for x in 0..<w { values[y * w + x] = line[x * step] }
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
