import AVFoundation
import SwiftUI
import UIKit

/// Plays one wave over and over, zoomed in and following you. Swipe sideways,
/// or tap a name along the bottom, to switch to another wave.
///
/// A wave not yet followed loops unzoomed from its bookmark until it is. If
/// nobody could be found at the bookmark, or the wrong person was picked, the
/// bookmark's frame is shown still and you tap yourself. Pinch and drag to
/// look closer, and slide a little past the bookmark if you're easier to see
/// there; you're followed back to the bookmark either way.
struct WaveLoopView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loop = LoopPlayer()
    @State private var waveID: Wave.ID?
    @State private var picking = false
    /// The frame shown to tap yourself on.
    @State private var pickTime: Double = 0
    @State private var rate: Float = 1
    @AppStorage("loopZoom") private var zoom: Double = 1

    /// How long to loop from a bookmark while you're still being found.
    private static let unfollowedLength = 12.0
    /// How far past the bookmark you can go to find a clearer frame of you.
    private static let pickReach = 10.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FollowingVideoView(
                player: loop.player,
                videoSize: model.videoSize,
                orientation: model.videoOrientation,
                track: picking ? nil : track,
                zoom: zoom,
                stillID: picking ? waveID : nil,
                onTap: picking ? { point in pick(point) } : nil,
                onSwipe: { step($0) },
                onPinch: { zoom = min(4, max(0.4, zoom * $0)) }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let status { statusLabel(status) }
                Spacer()
                if picking, let wave { pickTimeBar(wave) }
                waveNames
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
    private var track: WaveTrack? { waveID.flatMap { model.tracks[$0] } }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3)
            }
            Spacer()
            // Wrong person, or the ride cut short: tap yourself again.
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
                Text("Pinch to zoom, tap yourself")
            case .finding:
                ProgressView()
                Text("Finding you…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    /// Slides the still frame on from the bookmark, to one where you're easier
    /// to make out.
    private func pickTimeBar(_ wave: Wave) -> some View {
        let last = max(wave.time, min(model.duration, wave.time + Self.pickReach))
        let frame = 1 / max(1, model.frameRate)
        return HStack(spacing: 12) {
            Button { pickTime = max(wave.time, pickTime - frame) } label: {
                Image(systemName: "backward.frame.fill")
            }
            .disabled(pickTime <= wave.time)
            Slider(value: Binding(get: { pickTime }, set: { pickTime = $0 }), in: wave.time...max(last, wave.time + frame))
                .tint(.white)
            Button { pickTime = min(last, pickTime + frame) } label: {
                Image(systemName: "forward.frame.fill")
            }
            .disabled(pickTime >= last)
            Text(String(format: "+%.1fs", pickTime - wave.time))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8))
        .onChange(of: pickTime) { loop.show(pickTime) }
    }

    /// Every wave by the name and color you gave its bookmark, in time order.
    private var waveNames: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.waves) { w in
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
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    // MARK: Actions

    private func step(_ by: Int) {
        guard let i = model.waves.firstIndex(where: { $0.id == waveID }) else { return }
        let next = i + by
        guard model.waves.indices.contains(next) else { return }
        waveID = model.waves[next].id
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
            loop.loop(asset, from: track.start, to: track.end)
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
    private var looper: AVPlayerLooper?
    private var range: CMTimeRange?

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    func loop(_ asset: AVAsset, from start: Double, to end: Double) {
        let wanted = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                 end: CMTime(seconds: max(end, start + 0.5), preferredTimescale: 60000))
        guard wanted != range else { return }
        clear()
        range = wanted
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset), timeRange: wanted)
        player.defaultRate = rate
        player.play()
    }

    /// The exact frame at the bookmark, or a little after, held still, to tap
    /// yourself on.
    func still(_ asset: AVAsset, at time: Double) {
        clear()
        let item = AVPlayerItem(asset: asset)
        player.insert(item, after: nil)
        player.pause()
        show(time)
    }

    /// Moves the still frame. While a seek is under way only the latest
    /// wanted frame is kept, so sliding quickly never queues up a backlog.
    func show(_ time: Double) {
        wantedFrame = CMTime(seconds: time, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    private var wantedFrame = CMTime.zero
    private var seeking = false

    private func seekToWanted() {
        guard looper == nil, let item = player.currentItem else { return }
        seeking = true
        let target = wantedFrame
        item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
        looper?.disableLooping()
        looper = nil
        range = nil
        player.pause()
        player.removeAllItems()
    }
}

/// The video, moved and scaled every screen refresh so you stay in the middle
/// at the size you'd have zoomed to by hand. Without a path it shows the
/// whole picture, and a tap reports where in the picture it landed. A still
/// frame to tap on can be pinched and dragged to look closer.
struct FollowingVideoView: UIViewRepresentable {
    let player: AVPlayer
    let videoSize: CGSize
    let orientation: CGImagePropertyOrientation
    let track: WaveTrack?
    let zoom: Double
    /// The wave whose still frame is up to tap yourself on, if any. A new one
    /// starts unzoomed.
    var stillID: Wave.ID?
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: (Int) -> Void
    var onPinch: (Double) -> Void

    func makeUIView(context: Context) -> FollowingPlayerView {
        FollowingPlayerView(player: player)
    }

    func updateUIView(_ view: FollowingPlayerView, context: Context) {
        view.videoSize = videoSize
        view.orientation = orientation
        view.track = track
        view.zoom = zoom
        view.stillID = stillID
        view.onTap = onTap
        view.onSwipe = onSwipe
        view.onPinch = onPinch
    }
}

final class FollowingPlayerView: UIView {
    private let playerLayer = AVPlayerLayer()
    /// While following you, each frame is cropped and drawn here instead.
    private let followLayer = CALayer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var displayLink: CADisplayLink?
    var videoSize: CGSize = .zero
    var orientation: CGImagePropertyOrientation = .up
    var track: WaveTrack?
    var zoom: Double = 1
    var stillID: UUID? {
        didSet { if stillID != oldValue { setStill(scale: 1, offset: .zero) } }
    }
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: (Int) -> Void = { _ in }
    var onPinch: (Double) -> Void = { _ in }
    /// How far the still frame is zoomed and moved from the middle.
    private var stillScale: CGFloat = 1
    private var stillOffset: CGPoint = .zero
    private let pan = UIPanGestureRecognizer()
    private var swipes: [UISwipeGestureRecognizer] = []

    /// How many of you fit top to bottom, at zoom 1: what the clips you cut
    /// by hand showed.
    static let heightsInView = 9.0

    init(player: AVPlayer) {
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
    /// you were seen twice. So while following, each new frame is taken as it
    /// arrives, cropped around where you are in that same frame, and drawn.
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
            return
        }
        guard let output = player.currentItem?.outputs.first as? AVPlayerItemVideoOutput else { return }
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var shownAt = CMTime.zero
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shownAt) else { return }

        // Frames arrive as the camera stored them: on their side for a phone
        // held upright, upside down for one turned the other way.
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let w = image.extent.width, h = image.extent.height

        // What part of the picture to show, as fractions of it, from the top-left.
        let center = track.center(at: shownAt.seconds)
        var shownH = CGFloat(Double(track.height) * Self.heightsInView / zoom)
        var shownW = shownH * (bounds.width / bounds.height) * (h / w)
        let over = max(shownW, shownH)
        if over > 1 {
            shownW /= over
            shownH /= over
        }
        let left = min(max(0, center.x - shownW / 2), 1 - shownW)
        let top = min(max(0, center.y - shownH / 2), 1 - shownH)
        // Core Image measures from the bottom-left.
        let crop = CGRect(x: image.extent.minX + left * w, y: image.extent.minY + (1 - top - shownH) * h,
                          width: shownW * w, height: shownH * h)
        let pixels = bounds.height * traitCollection.displayScale
        var piece = image.cropped(to: crop)
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
        } else {
            onPinch(Double(gesture.scale))
        }
        gesture.scale = 1
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
