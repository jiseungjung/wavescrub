import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// Plays the waves being edited back to back, as the loop screen plays one:
/// the original footage, with each frame cut around the surfer as it's
/// drawn, at that wave's zoom. So zooming is only a different cut of the
/// next frame drawn, with nothing to make again. While a handle moves, it
/// plays the original video itself, to reach past what's in.
@MainActor
final class EditorPlayer: ObservableObject {
    /// One wave as it's played: its part of the video, where it starts in
    /// the finished video, and how it's cut.
    struct Segment {
        let id: UUID
        let start: Double
        let end: Double
        let track: WaveTrack
        var zoom: CGFloat
        /// Where it starts in the finished video, in its seconds.
        var at: Double = 0
    }

    let player = AVPlayer()
    /// Where the finished video is, in its seconds.
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    /// The picture's width over its height.
    @Published private(set) var aspect: CGFloat = 9 / 16
    /// A frame got ready, shown over the video while sliding: drawing the
    /// video's own frame means seeking to it, which trails the finger.
    @Published private(set) var still: CGImage?

    /// What the video shows of the picture at its own zoom.
    private(set) var shown: (w: CGFloat, h: CGFloat) = (1, 1)
    private(set) var orientation = CGImagePropertyOrientation.up
    private var segments: [Segment] = []
    private var speed = 1.0
    /// While a handle moves: the wave whose original footage is playing.
    private var source: Segment?
    /// Goes up whenever the same frame should be cut differently.
    private(set) var drawVersion = 0

    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var wanted: CMTime?
    private var seeking = false

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.source == nil, !self.seeking, self.wanted == nil, self.player.rate != 0 else { return }
                self.time = t.seconds
            }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playing = playing }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.time = self.duration
            }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func configure(shown: (w: CGFloat, h: CGFloat), orientation: CGImagePropertyOrientation) {
        self.shown = shown
        self.orientation = orientation
    }

    /// The waves back to back, from `time`. `built` is the finished video's
    /// footage; its frames are cut here as they're drawn.
    func load(_ built: ClipExport.Built, segments: [Segment], rate: Float, at time: Double, play: Bool) {
        var segments = segments
        for i in segments.indices where built.starts.indices.contains(i) { segments[i].at = built.starts[i] }
        self.segments = segments
        speed = Double(max(0.05, rate))
        let size = built.videoComposition.renderSize
        if size.height > 0 { aspect = size.width / size.height }
        source = nil
        player.replaceCurrentItem(with: AVPlayerItem(asset: built.composition))
        duration = built.duration
        seek(time)
        if play {
            still = nil
            player.play()
        }
    }

    /// While a handle moves: the original video, cut as that wave is, at a
    /// moment of it.
    func showSource(_ segment: Segment, asset: AVAsset, at moment: Double) {
        player.pause()
        if source?.id != segment.id || player.currentItem?.asset !== asset {
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        }
        source = segment
        seekSource(moment)
    }

    /// A moment of the original video, while a handle moves.
    func seekSource(_ moment: Double) {
        wanted = CMTime(seconds: moment, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    /// Cuts a wave closer or wider from the next frame drawn on.
    func setZoom(_ id: UUID, _ zoom: CGFloat) {
        for i in segments.indices where segments[i].id == id { segments[i].zoom = zoom }
        if source?.id == id { source?.zoom = zoom }
        drawVersion += 1
    }

    /// How to cut a frame of the item playing, at its own time: which path,
    /// how close, and the moment in the original video.
    func look(at itemTime: Double) -> (track: WaveTrack, zoom: CGFloat, moment: Double)? {
        if let source { return (source.track, source.zoom, itemTime) }
        guard let s = segments.last(where: { $0.at <= itemTime + 0.0005 }) ?? segments.first else { return nil }
        return (s.track, s.zoom, min(s.start + (itemTime - s.at) * speed, s.end))
    }

    /// Goes to an exact frame. While a seek is under way only the latest
    /// wanted frame is kept, so sliding quickly never queues up a backlog.
    func seek(_ t: Double) {
        time = t
        guard source == nil else { return }
        wanted = CMTime(seconds: t, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    /// While sliding: the timeline moves at once, and the picture follows.
    func slide(to t: Double) {
        time = t
    }

    /// The finger lifted: the video goes to that exact frame underneath,
    /// ready to play from there. The frame got ready stays showing until it
    /// plays: swapping one for the other showed as a jump in the picture.
    func settle() {
        seek(time)
    }

    func showStill(_ frame: CGImage?) {
        still = frame
    }

    private func seekToWanted() {
        guard let target = wanted, player.currentItem != nil else { return }
        wanted = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if self.wanted != nil { self.seekToWanted() }
            }
        }
    }

    func toggle() {
        if playing {
            pause()
        } else {
            guard source == nil else { return }
            if time >= duration - 0.05 { seek(0) }
            still = nil
            player.play()
        }
    }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Draws the editor's video, each frame cut around the surfer as it comes,
/// the way the loop screen does.
struct EditorVideoView: UIViewRepresentable {
    let player: EditorPlayer

    func makeUIView(context: Context) -> EditorVideoUIView { EditorVideoUIView(player: player) }
    func updateUIView(_ view: EditorVideoUIView, context: Context) {}
}

final class EditorVideoUIView: UIView {
    private let picture = CALayer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var displayLink: CADisplayLink?
    private weak var editor: EditorPlayer?
    private var output: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    /// The newest frame from the player, and what was last drawn.
    private var newest: (time: Double, buffer: CVPixelBuffer)?
    private var drawnBuffer: CVPixelBuffer?
    private var drawnVersion = -1
    private var needsRedraw = false

    /// Frames are drawn this wide at most: as sharp as the frames got ready
    /// for sliding, so the two look the same.
    static let width: CGFloat = EditorFrames.width

    init(player: EditorPlayer) {
        editor = player
        super.init(frame: .zero)
        backgroundColor = .black
        picture.contentsGravity = .resizeAspectFill
        layer.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
        needsRedraw = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let editor else { return }
        MainActor.assumeIsolated {
            let player = editor.player
            if let item = player.currentItem, item !== outputItem {
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(o)
                output = o
                outputItem = item
                // Its frames went by the item before: the last one drawn stays
                // up until this one's first arrives.
                newest = nil
            }
            if let output {
                let t = output.itemTime(forHostTime: link.targetTimestamp)
                var shownAt = CMTime.zero
                if output.hasNewPixelBuffer(forItemTime: t),
                   let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shownAt) {
                    newest = (shownAt.seconds, buffer)
                }
            }
            guard let frame = newest, bounds.width > 0,
                  needsRedraw || editor.drawVersion != drawnVersion || frame.buffer !== drawnBuffer,
                  let look = editor.look(at: frame.time) else { return }
            needsRedraw = false
            drawnVersion = editor.drawVersion
            drawnBuffer = frame.buffer
            draw(frame.buffer, look: look, shown: editor.shown, orientation: editor.orientation)
        }
    }

    private func draw(_ buffer: CVPixelBuffer, look: (track: WaveTrack, zoom: CGFloat, moment: Double),
                      shown: (w: CGFloat, h: CGFloat), orientation: CGImagePropertyOrientation) {
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let w = image.extent.width, h = image.extent.height
        let z = max(look.zoom, 0.01)
        let rect = FollowView(track: look.track, shownW: shown.w / z, shownH: shown.h / z).rect(at: look.moment)
        // Core Image measures from the bottom-left.
        let crop = CGRect(x: image.extent.minX + rect.minX * w, y: image.extent.minY + (1 - rect.maxY) * h,
                          width: rect.width * w, height: rect.height * h)
        let width = min(Self.width, bounds.width * traitCollection.displayScale)
        let size = CGSize(width: width, height: (width * bounds.height / bounds.width).rounded())
        let piece = LoopFrames.cut(image, to: crop, size: size)
        guard let cg = context.createCGImage(piece, from: piece.extent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = cg
        CATransaction.commit()
    }
}
