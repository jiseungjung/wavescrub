import AVFoundation
import SwiftUI
import UIKit

/// Plays one wave over and over, zoomed in and following the surfer. Swipe sideways,
/// or tap a name along the bottom, to switch to another wave.
///
/// A wave not yet followed loops unzoomed from its bookmark until it is. If
/// nobody could be found at the bookmark, or the wrong person was picked, the
/// bookmark's frame is shown still to tap the surfer on. Pinch and drag to
/// look closer, and slide a little past the bookmark if they're easier to see
/// there; they're followed back to the bookmark either way.
struct WaveLoopView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loop = LoopPlayer()
    @State private var waveID: Wave.ID?
    @State private var picking = false
    /// The frame shown to tap the surfer on.
    @State private var pickTime: Double = 0
    @State private var rate: Float = 1
    /// Only this surfer's waves, or everyone's.
    @State private var onlySurfer: Surfer.ID?
    /// The wave last watched with each choice, to come back to it.
    @State private var lastWave: [Surfer.ID?: Wave.ID] = [:]
    @AppStorage("loopZoom") private var zoom: Double = 1

    /// How long to loop from a bookmark while the surfer is still being found.
    private static let unfollowedLength = 12.0
    /// How far past the bookmark you can go to find a clearer frame of the surfer.
    private static let pickReach = 10.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FollowingVideoView(
                loop: loop,
                videoSize: model.videoSize,
                orientation: model.videoOrientation,
                track: picking ? nil : track,
                zoom: zoom,
                stillID: picking ? waveID : nil,
                onTap: picking ? { point in pick(point) } : nil,
                onSwipe: { step($0) },
                onZoom: { zoom = $0 }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let status { statusLabel(status) }
                Spacer()
                bottomPanel
            }
        }
        .statusBarHidden()
        .onAppear {
            model.player.pause()
            loop.rate = rate
            waveID = model.selectedWaveID
                ?? model.waves.last(where: { $0.time <= model.currentTime })?.id
                ?? model.waves.first?.id
        }
        .onDisappear {
            loop.stop()
            model.priorityWaveID = nil
        }
        .onChange(of: waveID) {
            picking = waveID.map { model.unfoundWaveIDs.contains($0) } ?? false
            pickTime = wave?.time ?? 0
            if let waveID { lastWave[onlySurfer] = waveID }
            model.priorityWaveID = waveID
            refresh()
        }
        .onChange(of: track) { refresh() }
        .onChange(of: model.unfoundWaveIDs) {
            if let waveID, model.unfoundWaveIDs.contains(waveID), !picking {
                beginPicking()
            }
        }
        .onChange(of: rate) { loop.rate = rate }
    }

    private var wave: Wave? { model.waves.first { $0.id == waveID } }
    /// The waves you can go through: everyone's, or one surfer's.
    private var shownWaves: [Wave] {
        guard let onlySurfer else { return model.waves }
        return model.waves.filter { $0.surferID == onlySurfer }
    }
    private var track: WaveTrack? { waveID.flatMap { model.tracks[$0] } }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3)
            }
            Spacer()
            // Wrong person, or the ride cut short: tap the surfer again.
            Button {
                beginPicking()
            } label: {
                Image(systemName: "person.crop.rectangle").font(.title3)
            }
            .disabled(picking || wave == nil)
            Button {
                rate = rate == 1 ? 0.5 : rate == 0.5 ? 0.25 : 1
            } label: {
                Text(rate == 1 ? "1×" : rate == 0.5 ? "½×" : "¼×")
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private enum Status { case pick, finding }

    private var status: Status? {
        guard let waveID else { return nil }
        if picking { return .pick }
        return model.tracks[waveID] == nil ? .finding : nil
    }

    private func statusLabel(_ status: Status) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .pick:
                Image(systemName: "hand.tap")
                Text("Pinch to zoom, tap the surfer")
            case .finding:
                ProgressView()
                Text("Finding the surfer…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    /// Slides the still frame on from the bookmark, to one where the surfer is
    /// easier to make out.
    private func pickTimeBar(_ wave: Wave) -> some View {
        let last = max(wave.time, min(model.duration, wave.time + Self.pickReach))
        let frame = 1 / max(1, model.frameRate)
        return HStack(spacing: 12) {
            Slider(value: Binding(get: { pickTime }, set: { pickTime = $0 }), in: wave.time...max(last, wave.time + frame))
                .tint(.white)
            Text(String(format: "+%.1fs", pickTime - wave.time))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: pickTime) { loop.show(pickTime) }
    }

    /// The bar for the loop or the still frame, and the waves' names under
    /// it, on one backing so nothing shows through between them.
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if picking, let wave {
                pickTimeBar(wave)
            } else if wave != nil {
                LoopScrubBar(loop: loop, clock: loop.clock)
            }
            if model.surfers.count > 1 { surferFilter.padding(.top, wave == nil ? 12 : 4) }
            waveNames
                .padding(.top, model.surfers.count > 1 ? 10 : wave == nil ? 12 : 2)
        }
        .background {
            if wave == nil {
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                Rectangle().fill(.ultraThinMaterial.opacity(0.8)).ignoresSafeArea()
            }
        }
    }

    /// All · each surfer: pick one to go through only their waves.
    private var surferFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("All", color: .white, selected: onlySurfer == nil) { onlySurfer = nil }
                ForEach(model.surfers) { surfer in
                    filterChip(surfer.label, color: surfer.color.color, selected: onlySurfer == surfer.id) {
                        onlySurfer = surfer.id
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        // Stay on the wave you're watching if it's in the new choice; otherwise
        // go back to the one you last watched there, or the nearest before.
        .onChange(of: onlySurfer) {
            let shown = shownWaves
            guard !shown.contains(where: { $0.id == waveID }) else { return }
            if let last = lastWave[onlySurfer], shown.contains(where: { $0.id == last }) {
                waveID = last
            } else {
                waveID = shown.last(where: { $0.time <= (wave?.time ?? 0) })?.id ?? shown.first?.id
            }
        }
    }

    private func filterChip(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? color : color.opacity(0.18), in: Capsule())
        }
    }

    /// Every wave by its name and its surfer's color, in time order.
    private var waveNames: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shownWaves) { w in
                        Button { waveID = w.id } label: {
                            HStack(spacing: 6) {
                                Circle().fill(w.color.color).frame(width: 10, height: 10)
                                Text(w.name).font(.callout).lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                w.id == waveID ? w.color.color.opacity(0.45) : Color.white.opacity(0.12),
                                in: Capsule()
                            )
                        }
                        .id(w.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: waveID) {
                withAnimation { proxy.scrollTo(waveID, anchor: .center) }
            }
            // The list is rebuilt for the new choice; bring the wave back into view.
            .onChange(of: onlySurfer) {
                DispatchQueue.main.async { proxy.scrollTo(waveID, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(waveID, anchor: .center) }
        }
        .padding(.bottom, 8)
    }

    // MARK: Actions

    private func step(_ by: Int) {
        let waves = shownWaves
        guard let i = waves.firstIndex(where: { $0.id == waveID }) else { return }
        let next = i + by
        guard waves.indices.contains(next) else { return }
        waveID = waves[next].id
    }

    private func beginPicking() {
        picking = true
        pickTime = wave?.time ?? 0
        refresh()
    }

    private func pick(_ point: CGPoint) {
        guard let waveID else { return }
        model.retrack(waveID, tappedAt: point, time: pickTime)
        picking = false
        refresh()
    }

    private func refresh() {
        guard let asset = model.asset, let wave else {
            loop.stop()
            return
        }
        if picking {
            loop.still(asset, at: pickTime)
        } else if let track {
            loop.loop(asset, from: track.start, to: track.end, followed: true)
        } else {
            loop.loop(asset, from: wave.time, to: min(model.duration, wave.time + Self.unfollowedLength))
        }
    }
}

/// A separate player from the main screen's, so leaving this screen puts you
/// back exactly where you were.
@MainActor
final class LoopPlayer: ObservableObject {
    let player = AVQueuePlayer()
    /// Where the loop is, kept apart so only the bar redraws as it plays.
    let clock = LoopClock()
    /// A frame got ready for sliding, shown until the player's own sharp one
    /// of the same moment arrives.
    private(set) var slideFrame: LoopFrames.Frame?
    private let frames = LoopFrames()
    private var looper: AVPlayerLooper?
    private var range: CMTimeRange?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.player.currentItem != nil else { return }
                self.clock.time = time.seconds
            }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.clock.playing = playing }
        }
    }

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    /// Only a followed loop gets frames ready for sliding: the rest is
    /// shown by the player as it is.
    func loop(_ asset: AVAsset, from start: Double, to end: Double, followed: Bool = false) {
        let wanted = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                 end: CMTime(seconds: max(end, start + 0.5), preferredTimescale: 60000))
        guard wanted != range else { return }
        clear()
        range = wanted
        clock.start = wanted.start.seconds
        clock.end = wanted.end.seconds
        clock.time = clock.start
        frames.reset(followed ? asset : nil, from: wanted.start.seconds, to: wanted.end.seconds)
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset), timeRange: wanted)
        player.defaultRate = rate
        player.play()
    }

    /// The exact frame at the bookmark, or a little after, held still, to tap
    /// the surfer on.
    func still(_ asset: AVAsset, at time: Double) {
        clear()
        let item = AVPlayerItem(asset: asset)
        player.insert(item, after: nil)
        player.pause()
        show(time)
    }

    /// Moves to an exact frame, of the still or the loop. While a seek is
    /// under way only the latest wanted frame is kept, so sliding quickly
    /// never queues up a backlog.
    func show(_ time: Double) {
        clock.time = time
        slideFrame = frames.frame(at: time)
        wantedFrame = CMTime(seconds: time, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    /// Moves while sliding: to a frame got ready, when there is one, and
    /// otherwise as `show` does.
    func slide(_ time: Double) {
        if let frame = frames.frame(at: time) {
            clock.time = time
            slideFrame = frame
        } else {
            show(time)
        }
    }

    func play() {
        slideFrame = nil
        player.play()
    }
    func pause() { player.pause() }

    private var wantedFrame = CMTime.zero
    private var seeking = false
    /// Changes with each new still or loop, so a seek begun on the last one
    /// can't carry on into this one.
    private var seekRun = 0

    private func seekToWanted() {
        guard let item = player.currentItem else { return }
        seeking = true
        let target = wantedFrame
        let run = seekRun
        item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, run == self.seekRun else { return }
                self.seeking = false
                if self.wantedFrame != target { self.seekToWanted() }
            }
        }
    }

    func stop() {
        clear()
    }

    private func clear() {
        seeking = false
        seekRun += 1
        slideFrame = nil
        frames.reset(nil, from: 0, to: 0)
        looper?.disableLooping()
        looper = nil
        range = nil
        player.pause()
        player.removeAllItems()
    }
}

@MainActor
final class LoopClock: ObservableObject {
    @Published var time: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var playing = false
}

/// Plays and pauses the loop, and slides through it a frame at a time, as
/// the bar for tapping the surfer does. Sliding pauses the loop until you let
/// go, then it carries on if it was playing.
struct LoopScrubBar: View {
    let loop: LoopPlayer
    @ObservedObject var clock: LoopClock
    @State private var wasPlaying: Bool?

    var body: some View {
        let end = max(clock.end, clock.start + 0.1)
        HStack(spacing: 12) {
            Button {
                clock.playing ? loop.pause() : loop.play()
            } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            Slider(value: Binding(get: { min(max(clock.time, clock.start), end) }, set: { loop.slide($0) }),
                   in: clock.start...end) { editing in
                if editing {
                    wasPlaying = clock.playing
                    loop.pause()
                } else {
                    loop.show(clock.time)
                    if wasPlaying == true { loop.play() }
                    wasPlaying = nil
                }
            }
            .tint(.white)
            Text(String(format: "%.1fs", max(0, clock.time - clock.start)))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The video, moved and scaled every screen refresh so the surfer stays in the
/// middle at the size you'd have zoomed to by hand. Without a path it shows the
/// whole picture, and a tap reports where in the picture it landed. A still
/// frame to tap on can be pinched and dragged to look closer.
struct FollowingVideoView: UIViewRepresentable {
    let loop: LoopPlayer
    let videoSize: CGSize
    let orientation: CGImagePropertyOrientation
    let track: WaveTrack?
    let zoom: Double
    /// The wave whose still frame is up to tap the surfer on, if any. A new one
    /// starts unzoomed.
    var stillID: Wave.ID?
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: (Int) -> Void
    var onZoom: (Double) -> Void

    func makeUIView(context: Context) -> FollowingPlayerView {
        FollowingPlayerView(loop: loop)
    }

    func updateUIView(_ view: FollowingPlayerView, context: Context) {
        view.videoSize = videoSize
        view.orientation = orientation
        view.track = track
        view.zoom = zoom
        view.stillID = stillID
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onZoom = onZoom
    }
}

final class FollowingPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()
    /// While following the surfer, each frame is cropped and drawn here instead.
    private let followLayer = CALayer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var displayLink: CADisplayLink?
    var videoSize: CGSize = .zero
    var orientation: CGImagePropertyOrientation = .up
    var track: WaveTrack?
    var zoom: Double = 1 {
        didSet { if zoom != oldValue { needsRedraw = true } }
    }
    var stillID: UUID? {
        didSet { if stillID != oldValue { setStill(scale: 1, offset: .zero) } }
    }
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: (Int) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    /// The picture's width over its height, upright, from the last frame drawn.
    private var pictureAspect: CGFloat = 16 / 9
    /// How far the still frame is zoomed and moved from the middle.
    private var stillScale: CGFloat = 1
    private var stillOffset: CGPoint = .zero
    private let pan = UIPanGestureRecognizer()
    private var swipes: [UISwipeGestureRecognizer] = []
    private weak var loop: LoopPlayer?
    /// The player's newest frame, and the frame last drawn, so a paused one
    /// can be drawn again at a new zoom.
    private var playerFrame: LoopFrames.Frame?
    private var drawnFrame: LoopFrames.Frame?
    private var needsRedraw = false

    /// How many surfers fit top to bottom, at zoom 1: what the clips cut by
    /// hand showed.
    static let heightsInView = 9.0

    init(loop: LoopPlayer) {
        let player = loop.player
        self.loop = loop
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        followLayer.contentsGravity = .resizeAspectFill
        followLayer.isHidden = true
        layer.addSublayer(followLayer)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
            swipes.append(swipe)
        }
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.setAffineTransform(.identity)
        playerLayer.frame = bounds
        followLayer.frame = bounds
        CATransaction.commit()
        needsRedraw = true
        setStill(scale: stillScale, offset: stillOffset)
    }

    /// Zooms and moves the still frame, never so far that the picture leaves
    /// an edge of the screen it was filling. Dragging is only for a zoomed
    /// frame; otherwise a sideways swipe changes wave.
    private func setStill(scale: CGFloat, offset: CGPoint) {
        let s = min(12, max(1, scale))
        let video = playerLayer.videoRect
        let reachX = max(0, (video.width * s - bounds.width) / 2)
        let reachY = max(0, (video.height * s - bounds.height) / 2)
        stillScale = s
        stillOffset = CGPoint(x: min(max(offset.x, -reachX), reachX), y: min(max(offset.y, -reachY), reachY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.setAffineTransform(CGAffineTransform(translationX: stillOffset.x, y: stillOffset.y)
            .scaledBy(x: s, y: s))
        CATransaction.commit()
        pan.isEnabled = s > 1.01
        for swipe in swipes { swipe.isEnabled = !pan.isEnabled }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(follow(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Moving the player's own picture around can't be done in step with its
    /// frames: the zoom changed a moment before or after the picture did, and
    /// the surfer was seen twice. So while following, each new frame is taken
    /// as it arrives, cropped around where they are in that same frame, and drawn.
    @objc private func follow(_ link: CADisplayLink) {
        guard let player = playerLayer.player else { return }
        // The looper queues copies of the wave ahead; each needs its own tap.
        for item in (player as? AVQueuePlayer)?.items() ?? [player.currentItem].compactMap({ $0 })
        where item.outputs.isEmpty {
            item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: nil))
        }
        guard let track, bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            followLayer.isHidden = true
            playerLayer.isHidden = false
            playerFrame = nil
            drawnFrame = nil
            return
        }
        if let output = player.currentItem?.outputs.first as? AVPlayerItemVideoOutput {
            let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
            var shownAt = CMTime.zero
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shownAt) {
                playerFrame = (shownAt.seconds, buffer)
            }
        }
        // While sliding, the frame got ready, until the player catches up
        // with a sharp one of the same moment.
        var frame = playerFrame
        if let slide = loop?.slideFrame,
           frame.map({ abs($0.time - slide.time) > 0.004 }) ?? true {
            frame = slide
        }
        guard let frame, needsRedraw || frame.buffer !== drawnFrame?.buffer else { return }
        needsRedraw = false
        drawnFrame = frame
        draw(frame.buffer, at: frame.time, following: track)
    }

    private func draw(_ buffer: CVPixelBuffer, at time: Double, following track: WaveTrack) {
        // Frames arrive as the camera stored them: on their side for a phone
        // held upright, upside down for one turned the other way.
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let w = image.extent.width, h = image.extent.height
        pictureAspect = w / h

        // What part of the picture to show, as fractions of it, from the top-left.
        // Zoomed out past an edge of the picture, the rest is black, out to
        // where the whole picture fits.
        let center = track.center(at: time)
        let shownH = min(CGFloat(Double(track.height) * Self.heightsInView / zoom), wholeHeight)
        let shownW = shownH * (bounds.width / bounds.height) * (h / w)
        // Never past the picture's edge. A surfer starts a wave at its right
        // edge, so the view waits there until they come into the middle; held
        // to the edge frame by frame it then set off at their full speed in
        // one jolt, and at a wide zoom it caught and let go of the top as they
        // rose and dropped. Averaged over a second around now, it eases off
        // the edge and back onto it instead, and is still exactly on them in
        // between. Once the whole width or height is in view, that way the
        // picture just sits in the middle, and they're only followed the other way.
        var left: CGFloat = 0, top: CGFloat = 0
        let offsets = (-5...5).map { Double($0) * 0.1 }
        for offset in offsets {
            let c = offset == 0 ? center : track.center(at: time + offset)
            left += shownW >= 1 ? (1 - shownW) / 2 : min(max(0, c.x - shownW / 2), 1 - shownW)
            top += shownH >= 1 ? (1 - shownH) / 2 : min(max(0, c.y - shownH / 2), 1 - shownH)
        }
        left /= CGFloat(offsets.count)
        top /= CGFloat(offsets.count)
        // Core Image measures from the bottom-left.
        let crop = CGRect(x: image.extent.minX + left * w, y: image.extent.minY + (1 - top - shownH) * h,
                          width: shownW * w, height: shownH * h)
        let pixels = bounds.height * traitCollection.displayScale
        var piece = image.cropped(to: crop)
        if !image.extent.contains(crop) {
            piece = image.composited(over: CIImage(color: .black)).cropped(to: crop)
        }
        if crop.height > pixels { piece = piece.transformed(by: CGAffineTransform(scaleX: pixels / crop.height, y: pixels / crop.height)) }
        guard let picture = context.createCGImage(piece, from: piece.extent) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        followLayer.contents = picture
        followLayer.isHidden = false
        playerLayer.isHidden = true
        CATransaction.commit()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let onTap else { return }
        // Through the still frame's zoom, to a point on the picture itself.
        let p = layer.convert(gesture.location(in: self), to: playerLayer)
        let f = playerLayer.videoRect
        guard f.contains(p) else { return }
        onTap(CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        if stillID != nil {
            // Keep the spot between the fingers under them.
            let p = gesture.location(in: self)
            let middle = CGPoint(x: bounds.midX, y: bounds.midY)
            let s = min(12, max(1, stillScale * gesture.scale))
            let k = s / stillScale
            setStill(scale: s, offset: CGPoint(x: p.x - middle.x - (p.x - middle.x - stillOffset.x) * k,
                                               y: p.y - middle.y - (p.y - middle.y - stillOffset.y) * k))
        } else if let track {
            // Out as far as the whole picture.
            let most = 4.0
            let least = Double(track.height) * Self.heightsInView / Double(wholeHeight)
            onZoom(min(max(least, zoom * Double(gesture.scale)), max(least, most)))
        }
        gesture.scale = 1
    }

    /// How much of the picture's height is shown with all of it in view, as
    /// a fraction of it: more than 1 when a wide picture is on a tall screen.
    private var wholeHeight: CGFloat {
        guard bounds.width > 0 else { return 1 }
        return max(1, pictureAspect * bounds.height / bounds.width)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let d = gesture.translation(in: self)
        setStill(scale: stillScale, offset: CGPoint(x: stillOffset.x + d.x, y: stillOffset.y + d.y))
        gesture.setTranslation(.zero, in: self)
    }

    /// Swiping left brings the next wave in, as paging through photos does.
    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onSwipe(gesture.direction == .left ? 1 : -1)
    }
}
