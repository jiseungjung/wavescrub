import AVFoundation
import SwiftUI
import UIKit

/// Plays one wave over and over, zoomed in and following you. Swipe sideways,
/// or tap a name along the bottom, to switch to another wave.
///
/// A wave not yet followed loops unzoomed from its bookmark until it is. If
/// nobody could be found at the bookmark, or the wrong person was picked, the
/// bookmark's frame is shown still and you tap yourself.
struct WaveLoopView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loop = LoopPlayer()
    @State private var waveID: Wave.ID?
    @State private var picking = false
    @State private var rate: Float = 1
    @AppStorage("loopZoom") private var zoom: Double = 1

    /// How long to loop from a bookmark while you're still being found.
    private static let unfollowedLength = 12.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FollowingVideoView(
                player: loop.player,
                videoSize: model.videoSize,
                orientation: model.videoOrientation,
                track: picking ? nil : track,
                zoom: zoom,
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
            model.priorityWaveID = waveID
            refresh()
        }
        .onChange(of: track) { refresh() }
        .onChange(of: model.unfoundWaveIDs) {
            if let waveID, model.unfoundWaveIDs.contains(waveID), !picking {
                picking = true
                refresh()
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
                picking = true
                refresh()
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
                Text("Tap yourself")
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

    private func pick(_ point: CGPoint) {
        guard let waveID else { return }
        model.retrack(waveID, tappedAt: point)
        picking = false
        refresh()
    }

    private func refresh() {
        guard let asset = model.asset, let wave else {
            loop.stop()
            return
        }
        if picking {
            loop.still(asset, at: wave.time)
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

    /// The exact frame at the bookmark, held still, to tap yourself on.
    func still(_ asset: AVAsset, at time: Double) {
        clear()
        let item = AVPlayerItem(asset: asset)
        player.insert(item, after: nil)
        player.pause()
        item.seek(to: CMTime(seconds: time, preferredTimescale: 60000),
                  toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
    }

    func stop() {
        clear()
    }

    private func clear() {
        looper?.disableLooping()
        looper = nil
        range = nil
        player.pause()
        player.removeAllItems()
    }
}

/// The video, moved and scaled every screen refresh so you stay in the middle
/// at the size you'd have zoomed to by hand. Without a path it shows the
/// whole picture, and a tap reports where in the picture it landed.
struct FollowingVideoView: UIViewRepresentable {
    let player: AVPlayer
    let videoSize: CGSize
    let orientation: CGImagePropertyOrientation
    let track: WaveTrack?
    let zoom: Double
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
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: (Int) -> Void = { _ in }
    var onPinch: (Double) -> Void = { _ in }

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
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        followLayer.frame = bounds
        CATransaction.commit()
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
        let p = gesture.location(in: self)
        let f = playerLayer.videoRect
        guard f.contains(p) else { return }
        onTap(CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        onPinch(Double(gesture.scale))
        gesture.scale = 1
    }

    /// Swiping left brings the next wave in, as paging through photos does.
    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onSwipe(gesture.direction == .left ? 1 : -1)
    }
}
