import Combine
import SwiftUI

/// Two waves looping together to compare, from the same video or different
/// ones: one above the other upright, side by side turned sideways. Each is
/// followed and zoomed so the two surfers are the same size, and each has its
/// own tape to slide through it. Linked, sliding or playing one moves both,
/// lined up on the moment they were linked at.
struct CompareView: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = CompareSession()
    /// The wave the loop screen was on; it goes in the first clip.
    let first: Wave
    @State private var choosingFor: ComparePane?
    @AppStorage("compareTapeSpan") private var tapeSpan: Double = 4
    @AppStorage("loopZoom") private var loopZoom: Double = 1

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            // No gap between the clips: they meet edge to edge.
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            // The videos fill the screen; the buttons float over the top of it.
            ZStack(alignment: .top) {
                layout {
                    ForEach(session.panes) { pane in
                        ComparePaneView(session: session, pane: pane, tapeSpan: $tapeSpan, compact: landscape) {
                            choosingFor = pane
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .ignoresSafeArea(edges: .top)
                topBar(landscape: landscape)
                    .background(
                        LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                    )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .sheet(item: $choosingFor) { pane in
            CompareChooser { session.choose($0, for: pane) }
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .onAppear {
            session.start(model: model, first: first, zoom: loopZoom)
            // Once this screen has finished coming up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { choosingFor = session.panes[1] }
        }
        .onDisappear { session.stop() }
        .onChange(of: model.tracks) { session.tracksChanged() }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            session.keepInStep()
        }
    }

    private func topBar(landscape: Bool) -> some View {
        HStack(spacing: 22) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3)
            }
            Spacer()
            Button { session.toggleLink() } label: {
                Image(systemName: "link")
                    .font(.title3)
                    .foregroundStyle(session.linked ? Color.black : Color.white)
                    .padding(6)
                    .background(session.linked ? Color.yellow : Color.clear, in: Circle())
            }
            .disabled(!session.ready)
            Button { session.swap() } label: {
                Image(systemName: landscape ? "arrow.left.arrow.right" : "arrow.up.arrow.down").font(.title3)
            }
            Button {
                session.rate = session.rate == 1 ? 0.5 : session.rate == 0.5 ? 0.25 : 1
            } label: {
                Text(session.rate == 1 ? "1×" : session.rate == 0.5 ? "½×" : "¼×")
                    .font(.system(.callout, design: .monospaced))
            }
            Button { session.playPauseAll() } label: {
                Image(systemName: session.anyPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 24)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// One of the two clips: the video as large as it can be, with its wave's
/// name (tap to choose another) and the tape to slide through it laid over
/// the bottom of the picture.
struct ComparePaneView: View {
    @EnvironmentObject private var model: PlayerModel
    @ObservedObject var session: CompareSession
    @ObservedObject var pane: ComparePane
    @Binding var tapeSpan: Double
    let compact: Bool
    let onChoose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Color.black
                if let clip = pane.clip {
                    FollowingVideoView(
                        loop: pane.loop,
                        videoSize: clip.video.info.size,
                        orientation: clip.video.info.orientation,
                        track: session.track(for: pane),
                        zoom: pane.zoom,
                        onSwipe: { _ in },
                        onZoom: { session.zoom(pane, to: $0) },
                        comparing: true
                    )
                }
                if let status = pane.status {
                    Text(status)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                } else if pane.clip == nil {
                    Button(action: onChoose) {
                        Label("Choose a wave", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if pane.clip != nil {
                VStack(spacing: 6) {
                    header
                    if let clip = pane.clip {
                        HStack(spacing: 10) {
                            PanePlayButton(clock: pane.loop.clock) { session.playPause(pane) }
                            LoopTape(clock: pane.loop.clock, frameRate: clip.video.info.frameRate, span: $tapeSpan,
                                     onBegin: { session.beginSlide(pane) },
                                     onSlide: { session.slide(pane, to: $0) },
                                     onEnd: { session.endSlide(pane) })
                        }
                        .frame(height: compact ? 34 : 42)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
            }
        }
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onChoose) {
                HStack(spacing: 6) {
                    if let wave = pane.clip?.wave {
                        Circle().fill(wave.color.color).frame(width: 10, height: 10)
                        Text(wave.title).lineLimit(1)
                    } else {
                        Text("No wave")
                    }
                    Image(systemName: "chevron.down").font(.caption)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((pane.clip?.wave.color.color ?? .white).opacity(0.3), in: Capsule())
            }
            Spacer()
            if let clip = pane.clip, session.track(for: pane) == nil {
                if clip.video.key == model.videoKey, model.trackingWaveID == clip.wave.id {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Finding the surfer…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    NotFollowedTag()
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

struct NotFollowedTag: View {
    var body: some View {
        Text("Not followed")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.35), in: Capsule())
    }
}

private struct PanePlayButton: View {
    @ObservedObject var clock: LoopClock
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                .frame(width: 20)
        }
        .foregroundStyle(.white)
    }
}

/// A tape through one loop, like the main screen's: the moment shown sits
/// under the yellow line, and dragging the tape slides through the loop.
/// Pinch it to fit more or less of the loop across.
struct LoopTape: View {
    @ObservedObject var clock: LoopClock
    let frameRate: Double
    @Binding var span: Double
    var onBegin: () -> Void
    var onSlide: (Double) -> Void
    var onEnd: () -> Void
    @State private var dragStart: Double?
    @State private var pinchStart: Double?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard pinchStart == nil else { return }
                            if dragStart == nil {
                                dragStart = clock.time
                                onBegin()
                            }
                            let seconds = Double(value.translation.width) * span / Double(max(1, geo.size.width))
                            onSlide(min(max(dragStart! - seconds, clock.start), clock.end))
                        }
                        .onEnded { _ in
                            if dragStart != nil { onEnd() }
                            dragStart = nil
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchStart == nil {
                                pinchStart = span
                                if dragStart != nil { dragStart = clock.time }
                            }
                            span = min(max(pinchStart! / Double(value.magnification), 1), 30)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
        }
    }

    /// Ticks are labelled from the start of the loop.
    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let start = clock.start, end = max(clock.end, clock.start + 0.1)
        guard size.width > 0 else { return }
        let pxPerSec = Double(size.width) / span
        let t0 = clock.time - span / 2
        let t1 = t0 + span
        func x(_ t: Double) -> CGFloat { CGFloat((t - t0) * pxPerSec) }

        // The tape is only as long as the clip: past either end there's
        // nothing over the picture.
        let left = max(x(start), 0), right = min(x(end), size.width)
        if right > left {
            ctx.fill(Path(roundedRect: CGRect(x: left, y: 0, width: right - left, height: size.height),
                          cornerRadius: 6),
                     with: .color(.black.opacity(0.35)))
        }

        let major = FineTape.majorInterval(pxPerSec: pxPerSec)
        let frame = 1 / max(1, frameRate)
        let minor = frame * pxPerSec >= 5 ? frame : major / 5
        let first = max(t0, start) - start, last = min(t1, end) - start

        var minorPath = Path()
        var r = (first / minor).rounded(.up) * minor
        while r <= last {
            let px = x(start + r)
            minorPath.move(to: CGPoint(x: px, y: size.height * 0.62))
            minorPath.addLine(to: CGPoint(x: px, y: size.height))
            r += minor
        }
        ctx.stroke(minorPath, with: .color(.white.opacity(0.35)), lineWidth: 1)

        var majorPath = Path()
        r = (first / major).rounded(.up) * major
        while r <= last {
            let px = x(start + r)
            majorPath.move(to: CGPoint(x: px, y: size.height * 0.42))
            majorPath.addLine(to: CGPoint(x: px, y: size.height))
            ctx.draw(Text(String(format: major < 1 ? "%.1fs" : "%.0fs", r))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7)),
                     at: CGPoint(x: px, y: size.height * 0.26))
            r += major
        }
        ctx.stroke(majorPath, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

        let mid = size.width / 2
        ctx.fill(Path(CGRect(x: mid - 1.5, y: 0, width: 3, height: size.height)), with: .color(.yellow))
    }
}

// MARK: - Choosing a wave

enum VideoRef {
    /// The video open on the main screen.
    case current
    case recent(RecentVideo)
}

struct CompareChoice {
    let video: VideoRef
    let wave: Wave
}

/// Your videos, the open one first; tap one for its waves, then a wave.
struct CompareChooser: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (CompareChoice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    videoRow(.current, title: model.title, icon: "play.rectangle", waves: model.waves, isOpen: true)
                }
                let others = model.recents.filter { $0.videoKey != nil && $0.videoKey != model.videoKey }
                if !others.isEmpty {
                    Section("Recent") {
                        ForEach(others) { recent in
                            videoRow(.recent(recent), title: recent.title,
                                     icon: recent.kind == .photo ? "photo" : "doc",
                                     waves: PlayerModel.loadWaves(key: recent.videoKey!), isOpen: false)
                        }
                    }
                }
            }
            .navigationTitle("Compare with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func videoRow(_ ref: VideoRef, title: String, icon: String, waves: [Wave], isOpen: Bool) -> some View {
        NavigationLink {
            CompareWaveList(ref: ref, title: title, waves: waves) { wave in
                onPick(CompareChoice(video: ref, wave: wave))
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.cyan).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(waves.count == 1 ? "1 wave" : "\(waves.count) waves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isOpen {
                    Text("Open now")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.3), in: Capsule())
                }
            }
        }
        .disabled(waves.isEmpty)
        .opacity(waves.isEmpty ? 0.4 : 1)
    }
}

/// One video's waves, by the names and colors you gave them.
private struct CompareWaveList: View {
    @EnvironmentObject private var model: PlayerModel
    let ref: VideoRef
    let title: String
    let waves: [Wave]
    let onPick: (Wave) -> Void
    @State private var followed: Set<Wave.ID> = []

    var body: some View {
        List(waves) { wave in
            Button { onPick(wave) } label: {
                HStack(spacing: 10) {
                    Circle().fill(wave.color.color).frame(width: 12, height: 12)
                    Text(wave.title).foregroundStyle(.white).lineLimit(1)
                    Text(formatTime(wave.time, decimals: 0))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !followed.contains(wave.id) { NotFollowedTag() }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            switch ref {
            case .current:
                followed = Set(model.tracks.keys)
            case .recent(let recent):
                followed = Set(PlayerModel.loadTracks(key: recent.videoKey ?? "").keys)
            }
        }
    }
}

// MARK: - The two clips and what links them

struct CompareClip {
    let video: OpenedVideo
    let wave: Wave
    /// The surfer's path, as saved when the clip was opened.
    let track: WaveTrack?
}

@MainActor
final class ComparePane: ObservableObject, Identifiable {
    let id = UUID()
    let loop = LoopPlayer(compact: true)
    @Published var clip: CompareClip?
    /// Opening, downloading, or why it couldn't be opened.
    @Published var status: String?
    @Published var zoom: Double = 1
    /// While linked, the part of the wave both clips have.
    var linkedRange: ClosedRange<Double>?
}

@MainActor
final class CompareSession: ObservableObject {
    @Published private(set) var panes = [ComparePane(), ComparePane()]
    /// While linked, where each clip was at the moment of linking: moving one
    /// moves the other by the same amount from there.
    @Published private(set) var anchors: [ComparePane.ID: Double]?
    @Published var rate: Float = 1 {
        didSet { for pane in panes { pane.loop.rate = rate } }
    }
    @Published private(set) var anyPlaying = false
    private weak var model: PlayerModel?
    private var watchers: [AnyCancellable] = []
    private var sliding = false
    private var wasPlaying: Set<ComparePane.ID> = []
    private var startZoom = 1.0

    /// How long to loop from a bookmark when the surfer hasn't been followed.
    private static let unfollowedLength = 12.0

    init() {
        for pane in panes {
            watchers.append(pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
            watchers.append(pane.loop.clock.$playing.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePlaying() }
            })
        }
    }

    var linked: Bool { anchors != nil }
    var ready: Bool { panes.allSatisfy { $0.clip != nil } }

    func start(model: PlayerModel, first: Wave, zoom: Double) {
        guard self.model == nil else { return }
        self.model = model
        startZoom = zoom
        choose(CompareChoice(video: .current, wave: first), for: panes[0])
    }

    func stop() {
        for pane in panes {
            pane.loop.stop()
            pane.clip = nil
        }
    }

    /// A wave from the open video follows along as the surfer is found.
    func track(for pane: ComparePane) -> WaveTrack? {
        guard let clip = pane.clip else { return nil }
        if let model, clip.video.key == model.videoKey { return model.tracks[clip.wave.id] }
        return clip.track
    }

    func tracksChanged() {
        // Unchanged loops carry on as they are.
        for pane in panes where pane.clip?.video.key == model?.videoKey && pane.linkedRange == nil {
            refresh(pane)
        }
    }

    func choose(_ choice: CompareChoice, for pane: ComparePane) {
        guard let model else { return }
        if linked { unlink() }
        pane.status = "Opening…"
        Task {
            do {
                let video: OpenedVideo
                switch choice.video {
                case .recent(let recent) where recent.videoKey != model.videoKey:
                    video = try await OpenedVideo.open(recent) { pane.status = "Downloading from iCloud… \($0)%" }
                default:
                    guard let asset = model.asset, let key = model.videoKey else { throw CocoaError(.fileNoSuchFile) }
                    video = OpenedVideo(asset: asset, info: model.videoInfo, key: key)
                }
                let saved = video.key == model.videoKey ? [:] : PlayerModel.loadTracks(key: video.key)
                // Another wave in a clip keeps its zoom; only an empty one
                // starts at the loop screen's.
                if pane.clip == nil { pane.zoom = startZoom }
                pane.clip = CompareClip(video: video, wave: choice.wave, track: saved[choice.wave.id])
                pane.status = nil
                pane.loop.rate = rate
                refresh(pane)
                if video.key == model.videoKey, model.tracks[choice.wave.id] == nil {
                    model.priorityWaveID = choice.wave.id
                }
            } catch {
                pane.status = "Couldn't open that video."
            }
        }
    }

    private func fullRange(_ pane: ComparePane) -> ClosedRange<Double> {
        guard let clip = pane.clip else { return 0...0 }
        if let track = track(for: pane) { return track.start...max(track.end, track.start + 0.5) }
        let end = min(clip.video.info.duration, clip.wave.time + Self.unfollowedLength)
        return clip.wave.time...max(end, clip.wave.time + 0.5)
    }

    private func refresh(_ pane: ComparePane, at time: Double? = nil, playing: Bool = true) {
        guard let clip = pane.clip else { return pane.loop.stop() }
        let range = pane.linkedRange ?? fullRange(pane)
        pane.loop.loop(clip.video.asset, from: range.lowerBound, to: range.upperBound,
                       followed: track(for: pane) != nil, at: time, playing: playing)
    }

    // MARK: Playing

    private func updatePlaying() {
        anyPlaying = panes.contains { $0.loop.clock.playing }
    }

    func playPauseAll() {
        if panes.contains(where: { $0.loop.isPlaying }) {
            for pane in panes { pane.loop.pause() }
        } else {
            lineUp()
            for pane in panes where pane.clip != nil { pane.loop.play() }
        }
    }

    /// Linked, both play and pause together.
    func playPause(_ pane: ComparePane) {
        if linked { return playPauseAll() }
        pane.loop.isPlaying ? pane.loop.pause() : pane.loop.play()
    }

    /// Where the other clip should be, linked, when this one is at `time`.
    private func time(of other: ComparePane, when pane: ComparePane, is time: Double) -> Double {
        guard let anchors, let mine = anchors[pane.id], let theirs = anchors[other.id] else { return other.loop.clock.time }
        let clock = other.loop.clock
        return min(max(time - mine + theirs, clock.start), clock.end)
    }

    /// Puts the second clip back in step with the first.
    private func lineUp() {
        guard linked else { return }
        let lead = panes[0], other = panes[1]
        other.loop.jump(time(of: other, when: lead, is: lead.loop.clock.time))
    }

    /// Two players drift apart a little, and each starts its loop over on its
    /// own; linked and playing, the second is nudged back whenever it's out.
    func keepInStep() {
        guard linked, !sliding, panes.allSatisfy({ $0.loop.isPlaying }) else { return }
        let lead = panes[0], other = panes[1]
        let wanted = time(of: other, when: lead, is: lead.loop.clock.time)
        if abs(other.loop.clock.time - wanted) > 0.1 { other.loop.jump(wanted) }
    }

    // MARK: Sliding

    private func group(_ pane: ComparePane) -> [ComparePane] {
        linked ? panes : [pane]
    }

    func beginSlide(_ pane: ComparePane) {
        sliding = true
        let group = group(pane)
        wasPlaying = Set(group.filter { $0.loop.isPlaying }.map(\.id))
        for p in group { p.loop.pause() }
    }

    func slide(_ pane: ComparePane, to time: Double) {
        pane.loop.slide(time)
        guard linked else { return }
        for other in panes where other !== pane {
            other.loop.slide(self.time(of: other, when: pane, is: time))
        }
    }

    func endSlide(_ pane: ComparePane) {
        sliding = false
        for p in group(pane) {
            p.loop.show(p.loop.clock.time)
            if wasPlaying.contains(p.id) { p.loop.play() }
        }
        wasPlaying = []
    }

    // MARK: Linking, swapping, zooming

    /// Links the two clips where they are now. Each then loops over only the
    /// part of its wave the other has too, so they start over together.
    func toggleLink() {
        if linked { return unlink() }
        guard ready else { return }
        let a = panes[0], b = panes[1]
        let ta = a.loop.clock.time, tb = b.loop.clock.time
        let d = tb - ta
        let ra = fullRange(a), rb = fullRange(b)
        let lo = max(ra.lowerBound, rb.lowerBound - d), hi = min(ra.upperBound, rb.upperBound - d)
        guard hi - lo >= 0.5 else { return }
        let playing = panes.contains { $0.loop.isPlaying }
        a.linkedRange = lo...hi
        b.linkedRange = (lo + d)...(hi + d)
        anchors = [a.id: ta, b.id: tb]
        refresh(a, at: ta, playing: playing)
        refresh(b, at: tb, playing: playing)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func unlink() {
        anchors = nil
        for pane in panes {
            pane.linkedRange = nil
            refresh(pane, at: pane.loop.clock.time, playing: pane.loop.isPlaying)
        }
    }

    func swap() {
        panes.swapAt(0, 1)
    }

    /// Linked, both zoom by the same amount, so the surfers stay the same size.
    func zoom(_ pane: ComparePane, to zoom: Double) {
        if linked, pane.zoom > 0 {
            let k = zoom / pane.zoom
            for other in panes where other !== pane {
                other.zoom = min(max(other.zoom * k, 0.05), 4)
            }
        }
        pane.zoom = zoom
    }
}
