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
/// At the bookmark you are the one at the far right edge, about to take off,
/// so that is who it picks unless you tapped someone. The ride is over at the
/// first of four things:
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
    /// How much of you, top to bottom, a box made from a tap covers.
    static let tapBoxHeight = 0.045

    static func track(asset: AVAsset, from start: Double, tap: CGPoint?) async throws -> WaveTrack {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform, rate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let fps = rate > 0 ? Double(rate) : 30
        let orientation = orientation(of: transform)
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        let pictureSize = CGSize(width: abs(turned.width), height: abs(turned.height))

        // The frame at the bookmark, the right way up, to find you in.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 60000))
        try Task.checkCancellation()
        guard let seed = seedBox(in: image, pictureSize: pictureSize, tap: tap) else { throw Failure.nobodyAtBookmark }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: longestRide, preferredTimescale: 600))
        guard reader.startReading() else { throw Failure.unreadable }
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

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = sample.presentationTimeStamp.seconds
            // The reader starts at the keyframe before; skip up to the bookmark.
            guard t >= start - 0.5 / fps, let buffer = sample.imageBuffer else { continue }

            let request = VNTrackObjectRequest(detectedObjectObservation: last)
            request.trackingLevel = .accurate
            try sequence.perform([request], on: buffer, orientation: orientation)
            guard let found = request.results?.first as? VNDetectedObjectObservation else { break }
            last = found
            let box = topLeftRect(found.boundingBox)
            let x = Double(box.midX)
            times.append(t)
            xs.append(x)
            ys.append(Double(box.midY))

            if found.confidence < lostConfidence {
                if lowSince == nil { lowSince = t }
                if let since = lowSince, t - since >= lostFor { end = since; break }
            } else {
                lowSince = nil
            }

            if x < 0.015 { end = t; break }

            // Five times a second, check there is still a person in the box.
            // Only trusted once it has seen you a few times: a rider small or
            // blurred enough to be missed from the start must not end at once.
            if times.count % 6 == 1 {
                if personInside(box, buffer: buffer, orientation: orientation) {
                    lastSeen = t
                    sightings += 1
                } else if sightings >= 3, let seen = lastSeen, t - seen > goneFor {
                    end = seen + 0.3
                    break
                }
            }

            if t - start >= stallWindow,
               let from = times.firstIndex(where: { $0 >= t - stallWindow }),
               xs[from] - x < stallDistance {
                // End where you were furthest along, just as you turned off it.
                let furthest = (from..<xs.count).min { xs[$0] < xs[$1] } ?? from
                end = min(t, times[furthest] + 0.5)
                break
            }
        }
        guard !times.isEmpty else { throw Failure.unreadable }
        let rideEnd = end ?? times[times.count - 1]

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

    /// The person you tapped, or with no tap the one furthest right.
    private static func seedBox(in image: CGImage, pictureSize: CGSize, tap: CGPoint?) -> CGRect? {
        let found = people(in: image)
        guard let tap else { return found.max { $0.midX < $1.midX } }
        let near = found
            .filter { $0.insetBy(dx: -$0.width / 2, dy: -$0.height / 2).contains(tap) }
            .min { hypot($0.midX - tap.x, $0.midY - tap.y) < hypot($1.midX - tap.x, $1.midY - tap.y) }
        if let near { return near }
        let h = CGFloat(tapBoxHeight)
        let w = h * pictureSize.height / max(1, pictureSize.width) * 0.9
        return CGRect(x: tap.x - w / 2, y: tap.y - h / 2, width: w, height: h)
    }

    /// Everyone the person finder sees. A surfer is only a few dozen pixels
    /// tall in a whole 4K frame, too small once the finder shrinks it, so it
    /// also looks at six overlapping pieces of the frame, each one bigger.
    private static func people(in image: CGImage) -> [CGRect] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var tiles = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        for x in [0, 0.3, 0.6] as [CGFloat] {
            for y in [0, 0.4] as [CGFloat] { tiles.append(CGRect(x: x, y: y, width: 0.4, height: 0.6)) }
        }
        var boxes: [CGRect] = []
        for tile in tiles {
            let pixels = CGRect(x: tile.minX * w, y: tile.minY * h, width: tile.width * w, height: tile.height * h).integral
            guard let piece = image.cropping(to: pixels) else { continue }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(cgImage: piece).perform([request])
            for person in request.results ?? [] {
                let b = topLeftRect(person.boundingBox)
                boxes.append(CGRect(x: (pixels.minX + b.minX * pixels.width) / w,
                                    y: (pixels.minY + b.minY * pixels.height) / h,
                                    width: b.width * pixels.width / w,
                                    height: b.height * pixels.height / h))
            }
        }
        return boxes
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
}
