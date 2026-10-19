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
    /// Opens the list of videos; it lives with the app, not this screen.
    var videosButton = AnyView(EmptyView())
    /// Switches to finding waves.
    var onFind: () -> Void = {}
    /// Opening the app or a video starts on the first wave; coming back from
    /// finding waves starts where you were.
    var startAtFirst = true
    @StateObject private var loop = LoopPlayer()
    @State private var waveID: Wave.ID?
    @State private var picking = false
    /// The frame shown to tap the surfer on.
    @State private var pickTime: Double = 0
    @State private var rate: Float = 1
    @State private var comparing = false
    /// Tap the video to hide or show the bars, like finding waves sideways.
    @State private var controlsHidden = false
    /// Only this surfer's waves, or everyone's.
    @State private var onlySurfer: Surfer.ID?
    /// Only starred waves; goes with the surfer choice.
    @State private var starredOnly = false
    /// The wave last watched with each choice, to come back to it.
    @State private var lastWave: [String: Wave.ID] = [:]
    private var choice: String { (onlySurfer?.uuidString ?? "all") + (starredOnly ? "★" : "") }
    /// Choosing waves to export, rather than just watching them.
    @State private var exporting = false
    @State private var chosen: Set<Wave.ID> = []
    /// Where each chosen wave starts and ends in the export, kept while
    /// going back and forth between choosing waves and editing them.
    @State private var exportCuts: [Wave.ID: ExportCut] = [:]
    /// The order the waves were put in, in the editor. Waves chosen later go
    /// after them, in time order.
    @State private var exportOrder: [Wave.ID] = []
    /// The export editor is open.
    @State private var editing = false
    /// A word that fades after a moment, like "Saved to Photos".
    @State private var note: String?
    /// How big the video is on screen, for exports as wide as what you see.
    @State private var viewSize: CGSize = .zero
    /// Moving where the wave's clip starts and ends, on the strip of frames.
    @State private var trimming = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

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
                track: picking || trimming ? nil : track,
                span: span,
                stillID: picking || trimming ? waveID : nil,
                onTap: picking ? { point in pick(point) } : nil,
                onPlainTap: {
                    guard !trimming else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { controlsHidden.toggle() }
                },
                onSwipe: { if !trimming { step($0) } },
                onZoom: { model.loopSpan = $0 }
            )
            .ignoresSafeArea()
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewSize = geo.size }
                        .onChange(of: geo.size) { viewSize = geo.size }
                }
            }

            VStack(spacing: 0) {
                if showsControls { topBar.transition(.opacity) }
                Spacer()
                if model.waves.isEmpty {
                    noWaves
                } else if let status {
                    statusLabel(status)
                } else if let note {
                    noteLabel(note)
                }
                Spacer()
                if !model.waves.isEmpty && showsControls { bottomPanel.transition(.opacity) }
            }
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $comparing, onDismiss: {
            model.priorityWaveID = waveID
            refresh()
            loop.play()
        }) {
            if let wave {
                CompareView(first: wave)
                    .environmentObject(model)
                    .preferredColorScheme(.dark)
            }
        }
        .onAppear {
            model.player.pause()
            loop.rate = rate
            // Back from finding waves: start on the one just marked, or near
            // where you were. Otherwise from the first wave.
            if let marked = model.lastMarkedWaveID.flatMap({ id in model.waves.first { $0.id == id } }) {
                waveID = marked.id
            } else if startAtFirst {
                waveID = model.waves.first?.id
            } else {
                waveID = model.selectedWaveID
                    ?? model.waves.last(where: { $0.time <= model.currentTime })?.id
                    ?? model.waves.first?.id
            }
            model.lastMarkedWaveID = nil
            keepSpan()
        }
        .onDisappear {
            loop.stop()
            model.priorityWaveID = nil
        }
        .onChange(of: waveID) {
            trimming = false
            picking = waveID.map { model.unfoundWaveIDs.contains($0) } ?? false
            pickTime = wave?.time ?? 0
            if let wave { remember(wave) }
            model.priorityWaveID = waveID
            refresh()
        }
        .onChange(of: track) {
            keepSpan()
            // The frame being looked at stays put while moving the start and end.
            if !trimming { refresh() }
        }
        // Another video opened: start it fresh, from its first wave.
        .onChange(of: model.openedCount) {
            editing = false
            exporting = false
            trimming = false
            chosen = []
            onlySurfer = nil
            starredOnly = false
            lastWave = [:]
            waveID = model.waves.first?.id
        }
        .onChange(of: model.unfoundWaveIDs) {
            if let waveID, model.unfoundWaveIDs.contains(waveID), !picking {
                beginPicking()
            }
        }
        .onChange(of: rate) { loop.rate = rate }
        .fullScreenCover(isPresented: $editing, onDismiss: { loop.play() }) {
            if let asset = model.asset {
                ExportEditor(
                    asset: asset,
                    orientation: model.videoOrientation,
                    clips: editClips,
                    shown: ClipExport.shown(span: span, screen: viewSize, picture: model.videoSize),
                    rate: $rate,
                    title: model.title
                ) { clips, exported in
                    for c in clips { exportCuts[c.id] = ExportCut(start: c.start, end: c.end) }
                    chosen = Set(clips.map(\.id))
                    exportOrder = clips.map(\.id)
                    if exported { setExporting(false) }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private var wave: Wave? { model.waves.first { $0.id == waveID } }
    /// The bars always show while tapping the surfer, moving the start and
    /// end, or with nothing marked.
    private var showsControls: Bool { !controlsHidden || picking || trimming || model.waves.isEmpty }
    /// The waves you can go through: everyone's, or one surfer's.
    private var shownWaves: [Wave] {
        model.waves.filter {
            (onlySurfer == nil || $0.surferID == onlySurfer) && (!starredOnly || $0.starred)
        }
    }

    /// The surfer choices only show once there's more than one surfer.
    private var showsFilter: Bool { model.surfers.count > 1 }
    /// The star toggle shows once something is starred.
    private var showsStarToggle: Bool { starredOnly || model.waves.contains(where: \.starred) }
    private var track: WaveTrack? { waveID.flatMap { model.tracks[$0] } }
    /// This video's zoom, the same for every wave in it.
    private var span: Double { model.loopSpan ?? track.map(PlayerModel.startingSpan) ?? 0.5 }

    /// A video's first followed wave sets its zoom, as it looked before.
    private func keepSpan() {
        if model.loopSpan == nil, let track { model.loopSpan = PlayerModel.startingSpan(for: track) }
    }

    // MARK: Pieces

    private var topBar: some View {
        Group {
            if exporting { exportTopBar } else if trimming { trimTopBar } else { watchTopBar }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var speedButton: some View {
        Button {
            rate = rate == 1 ? 0.5 : rate == 0.5 ? 0.25 : 1
        } label: {
            Text(rate == 1 ? "1×" : rate == 0.5 ? "½×" : "¼×")
                .font(.system(.callout, design: .monospaced))
        }
    }

    /// Choosing waves to export: Cancel, and the speed, since it's the speed
    /// they're exported at.
    private var exportTopBar: some View {
        ZStack {
            Text("Export").font(.headline)
            HStack {
                Button("Cancel") { setExporting(false) }
                Spacer()
                speedButton
            }
        }
        .foregroundStyle(.white)
    }

    /// Moving the start and end: Cancel leaves the clip as it was.
    private var trimTopBar: some View {
        ZStack {
            Text("Start and end").font(.headline)
            HStack {
                Button("Cancel") { setTrimming(false) }
                Spacer()
                Button("Done") { finishTrimming() }
                    .font(.body.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
    }

    private var watchTopBar: some View {
        HStack(spacing: 18) {
            videosButton
            Text(model.title)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 8)
            // This wave beside another, from this video or a different one.
            Button {
                loop.pause()
                comparing = true
            } label: {
                Image(systemName: "rectangle.split.1x2").font(.title3)
            }
            .disabled(picking || wave == nil)
            if let wave {
                StarButton(wave: wave)
            }
            speedButton
            // Things done now and then.
            Menu {
                Button { setExporting(true) } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button { model.showingPeople = true } label: {
                    Label("Who's surfing", systemImage: "person.2")
                }
                // The tracker started or ended the ride in the wrong place.
                Button { setTrimming(true) } label: {
                    Label("Adjust start and end", systemImage: "timeline.selection")
                }
                .disabled(picking || track == nil)
                // Wrong person, or the ride cut short: track the surfer again.
                Button { beginPicking() } label: {
                    Label("Track the surfer", systemImage: "person.crop.rectangle")
                }
                .disabled(picking || wave == nil)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
    }

    private var findButton: some View {
        Button(action: onFind) {
            Label("Find waves", systemImage: "flag")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.16), in: Capsule())
        }
    }

    /// A video with nothing marked yet: one step, find waves.
    private var noWaves: some View {
        VStack(spacing: 14) {
            Text("No waves marked yet")
                .font(.headline)
                .foregroundStyle(.white)
            Button(action: onFind) {
                Label("Find waves", systemImage: "flag")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private enum Status { case pick, finding, extending }

    private var status: Status? {
        guard let waveID, !trimming else { return nil }
        if picking { return .pick }
        if model.isExtending(waveID) { return .extending }
        return model.tracks[waveID] == nil ? .finding : nil
    }

    private func statusLabel(_ status: Status) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .pick:
                Image(systemName: "hand.tap")
                Text("Pinch to zoom, tap the surfer to track")
            case .finding:
                ProgressView()
                Text("Finding the surfer…")
            case .extending:
                ProgressView()
                Text("Following the surfer into the new part…")
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
            if trimming {
                if let asset = model.asset {
                    TrimStrip(asset: asset, duration: model.duration, start: $trimStart, end: $trimEnd) {
                        loop.show($0)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            } else if picking, let wave {
                pickTimeBar(wave)
            } else if wave != nil {
                LoopScrubBar(loop: loop, clock: loop.clock)
            }
            // Moving the start and end stays on this one wave.
            if !trimming {
                if showsFilter { surferFilter.padding(.top, wave == nil ? 12 : 4) }
                waveNames
                    .padding(.top, showsFilter ? 10 : wave == nil ? 12 : 2)
                if exporting {
                    exportBar
                        .padding(.bottom, 6)
                } else {
                    findButton
                        .padding(.bottom, 6)
                }
            }
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

    /// All · each surfer: go through only one surfer's waves.
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
    }

    /// A wave watched counts as the last one for every choice it fits, not
    /// just the one it was watched in: watching A's fifth wave under All
    /// brings you back to it when choosing A.
    private func remember(_ wave: Wave) {
        var fits = ["all"]
        if let surfer = wave.surferID { fits.append(surfer.uuidString) }
        if wave.starred { fits += fits.map { $0 + "★" } }
        for key in fits { lastWave[key] = wave.id }
    }

    /// Stay on the wave you're watching if it's in the new choice; otherwise
    /// go back to the one you last watched there, or its first wave.
    private func keepPlace() {
        let shown = shownWaves
        guard !shown.contains(where: { $0.id == waveID }) else { return }
        if let last = lastWave[choice], shown.contains(where: { $0.id == last }) {
            waveID = last
        } else {
            waveID = shown.first?.id
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

    /// Every wave by its name, in time order, with its surfer's color when
    /// there's more than one surfer. The star toggle stays put at the start
    /// while the waves scroll beside it.
    private var waveNames: some View {
        HStack(spacing: 0) {
            if showsStarToggle {
                Button { starredOnly.toggle() } label: {
                    Image(systemName: starredOnly ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(starredOnly ? .black : .yellow)
                        .frame(width: 38, height: 38)
                        .background(starredOnly ? Color.yellow : Color.white.opacity(0.12), in: Circle())
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
            }
            waveChips
                // Chips scrolled past the star fade out rather than being cut.
                .mask {
                    HStack(spacing: 0) {
                        if showsStarToggle {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 16)
                        }
                        Color.black
                    }
                }
        }
        .padding(.bottom, 8)
    }

    private var waveChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if shownWaves.isEmpty {
                        Text(starredOnly ? "No starred waves yet" : "No waves")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(shownWaves) { w in
                        Button { tapWave(w) } label: {
                            HStack(spacing: 6) {
                                if exporting {
                                    // A wave can be exported once its surfer is followed.
                                    Image(systemName: model.tracks[w.id] == nil ? "circle.dashed"
                                          : chosen.contains(w.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(w.id) ? Color.yellow : .white.opacity(0.7))
                                } else if model.surfers.count > 1 {
                                    Circle().fill(w.color.color).frame(width: 10, height: 10)
                                }
                                Text(w.title).font(.callout).lineLimit(1)
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
                .padding(.leading, showsStarToggle ? 4 : 16)
                .padding(.trailing, 16)
            }
            .onChange(of: waveID) {
                withAnimation { proxy.scrollTo(waveID, anchor: .center) }
            }
            // The list is rebuilt for the new choice; bring the wave back into view.
            .onChange(of: choice) {
                DispatchQueue.main.async { proxy.scrollTo(waveID, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(waveID, anchor: .center) }
        }
        .onChange(of: onlySurfer) { keepPlace() }
        .onChange(of: starredOnly) { keepPlace() }
    }

    // MARK: Exporting

    /// Every wave you can see along the bottom that's followed, chosen or not.
    private var choosable: [Wave.ID] { shownWaves.map(\.id).filter { model.tracks[$0] != nil } }

    private var exportBar: some View {
        let allChosen = !choosable.isEmpty && choosable.allSatisfy { chosen.contains($0) }
        let count = chosen.count
        return HStack {
            Button(allChosen ? "Deselect all" : "Select all shown") {
                if allChosen {
                    chosen.subtract(choosable)
                } else {
                    chosen.formUnion(choosable)
                }
            }
            .font(.callout)
            .foregroundStyle(.white)
            .disabled(choosable.isEmpty)
            Spacer()
            Button(action: startEditing) {
                Label(count == 1 ? "Edit 1 wave" : count == 0 ? "Edit" : "Edit \(count) waves",
                      systemImage: "film.stack")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            .disabled(count == 0)
        }
        .padding(.horizontal, 16)
    }

    private func noteLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Fades in like finding waves, with the wave you're watching chosen.
    private func setExporting(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            exporting = on
            chosen = on ? Set([waveID].compactMap { $0 }.filter { model.tracks[$0] != nil }) : []
        }
        exportCuts = [:]
        exportOrder = []
    }

    /// While exporting, a tap chooses the wave (or lets it go), and plays it.
    private func tapWave(_ w: Wave) {
        if exporting, model.tracks[w.id] != nil {
            if chosen.contains(w.id) { chosen.remove(w.id) } else { chosen.insert(w.id) }
        }
        waveID = w.id
    }

    /// The chosen waves in time order, each as long as its loop unless
    /// trimmed in the editor already.
    private var editClips: [EditClip] {
        let place = { (w: Wave) in exportOrder.firstIndex(of: w.id) ?? Int.max }
        return model.waves.filter { chosen.contains($0.id) }
            .sorted { (place($0), $0.time) < (place($1), $1.time) }
            .compactMap { w in
            guard let track = model.tracks[w.id] else { return nil }
            let clip = w.clip(track)
            let cut = exportCuts[w.id]
            let start = min(max(cut?.start ?? clip.lowerBound, clip.lowerBound), clip.upperBound - 0.5)
            let end = max(min(cut?.end ?? clip.upperBound, clip.upperBound), start + 0.5)
            return EditClip(id: w.id, title: w.title, color: w.color.color, loop: clip,
                            track: track, start: start, end: end)
        }
    }

    private func startEditing() {
        guard !editClips.isEmpty else { return }
        loop.pause()
        editing = true
    }

    private func show(note text: String) {
        withAnimation { note = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { if note == text { note = nil } }
        }
    }

    // MARK: Actions

    private func step(_ by: Int) {
        let waves = shownWaves
        guard let i = waves.firstIndex(where: { $0.id == waveID }) else { return }
        let next = i + by
        guard waves.indices.contains(next) else { return }
        waveID = waves[next].id
    }

    /// Shows the frame at the clip's start, still, with the strip of frames
    /// under it. Cancel or Done goes back to looping.
    private func setTrimming(_ on: Bool) {
        if on, let wave, let track {
            let clip = wave.clip(track)
            trimStart = clip.lowerBound
            trimEnd = clip.upperBound
        }
        withAnimation(.easeInOut(duration: 0.2)) { trimming = on }
        controlsHidden = false
        refresh()
    }

    private func finishTrimming() {
        if let waveID { model.setClip(waveID, start: trimStart, end: trimEnd) }
        setTrimming(false)
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
        if trimming {
            loop.still(asset, at: trimStart)
        } else if picking {
            loop.still(asset, at: pickTime)
        } else if let track {
            let clip = wave.clip(track)
            loop.loop(asset, from: clip.lowerBound, to: clip.upperBound, followed: true)
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
    private let frames: LoopFrames
    private var looper: AVPlayerLooper?
    private var range: CMTimeRange?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?

    /// A compact player is one of two side by side: silent, and keeping the
    /// whole wave ready for sliding once it's been got ready, at a little less
    /// detail. Two clips at once get ready half as fast, and linked sliding
    /// sweeps the whole wave back and forth: keeping only a few seconds, the
    /// same ones were made over and over and the picture kept stopping.
    init(compact: Bool = false) {
        frames = compact ? LoopFrames(reach: 15) : LoopFrames()
        player.isMuted = compact
        defer {
            // A second got ready while the finger waits on it: catch up.
            frames.onReady = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.scrubbing, let frame = self.frames.frame(at: self.clock.time) else { return }
                    self.slideFrame = frame
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, !self.scrubbing, self.player.currentItem != nil else { return }
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
    /// shown by the player as it is. Given a moment, the loop starts there,
    /// playing or not; otherwise it plays from the start.
    func loop(_ asset: AVAsset, from start: Double, to end: Double, followed: Bool = false,
              at time: Double? = nil, playing: Bool = true) {
        let wanted = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                 end: CMTime(seconds: max(end, start + 0.5), preferredTimescale: 60000))
        defer {
            if let time {
                if !playing { player.pause() }
                jump(min(max(time, clock.start), clock.end))
            }
        }
        guard wanted != range else { return }
        clear()
        range = wanted
        clock.start = wanted.start.seconds
        clock.end = wanted.end.seconds
        clock.time = clock.start
        frames.reset(followed ? asset : nil, from: wanted.start.seconds, to: wanted.end.seconds)
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset), timeRange: wanted)
        player.defaultRate = rate
        if playing { player.play() }
    }

    /// The exact frame at the bookmark, or a little after, held still, to tap
    /// the surfer on.
    func still(_ asset: AVAsset, at time: Double) {
        clear()
        frames.reset(nil, from: 0, to: 0)
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

    /// Moves while sliding: to a frame got ready, when there is one. While
    /// frames are being got ready, one that isn't yet holds the picture until
    /// it is, rather than seeking: seeks took as long as getting a whole
    /// second ready, slowed it down, and landed out of step, so the picture
    /// lurched. The exact frame is shown when the finger lifts.
    func slide(_ time: Double) {
        if let frame = frames.frame(at: time) {
            clock.time = time
            slideFrame = frame
        } else if scrubbing, frames.isActive {
            clock.time = time
        } else {
            show(time)
        }
    }

    /// Moves to a moment without stopping, to keep a linked clip in step.
    func jump(_ time: Double) {
        slideFrame = nil
        clock.time = time
        wantedFrame = CMTime(seconds: time, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    var isPlaying: Bool { player.rate != 0 }

    /// What the view shows of the picture while following, so frames for
    /// sliding are made to fit it.
    func follow(_ view: FollowView, pixels: CGFloat, orientation: CGImagePropertyOrientation) {
        frames.follow(view, pixels: pixels, orientation: orientation)
    }

    func play() {
        slideFrame = nil
        player.play()
    }
    func pause() { player.pause() }

    /// While a finger is on the bar, only the finger moves it: the playing
    /// loop's own clock is ignored until the finger lifts.
    private(set) var scrubbing = false

    func beginScrub() {
        scrubbing = true
        player.pause()
    }

    /// Lands on the exact frame and stays paused there.
    func endScrub() {
        scrubbing = false
        show(clock.time)
    }

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
        frames.reset(nil, from: 0, to: 0)
    }

    /// Frames got ready are left to `loop`, which keeps them when it can.
    private func clear() {
        seeking = false
        seekRun += 1
        slideFrame = nil
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
/// the bar for tapping the surfer does. Touching it pauses the loop, and it
/// stays paused on the frame you let go of.
struct LoopScrubBar: View {
    let loop: LoopPlayer
    @ObservedObject var clock: LoopClock
    @State private var dragging = false

    var body: some View {
        let end = max(clock.end, clock.start + 0.1)
        HStack(spacing: 12) {
            Button {
                clock.playing ? loop.pause() : loop.play()
            } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            bar(end: end)
            Text(String(format: "%.1fs", max(0, clock.time - clock.start)))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Touch anywhere on it to pause and jump there, then slide. It stays
    /// paused when you let go; press play to carry on.
    private func bar(end: Double) -> some View {
        GeometryReader { geo in
            let thumb: CGFloat = dragging ? 26 : 22
            let usable = max(1, geo.size.width - thumb)
            let fraction = (min(max(clock.time, clock.start), end) - clock.start) / (end - clock.start)
            let x = thumb / 2 + usable * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                Capsule().fill(.white).frame(width: x, height: 4)
                Circle().fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: x - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            loop.beginScrub()
                        }
                        let f = min(max(0, (value.location.x - thumb / 2) / usable), 1)
                        loop.slide(clock.start + Double(f) * (end - clock.start))
                    }
                    .onEnded { _ in
                        dragging = false
                        loop.endScrub()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 32)
    }
}

/// The video, moved and scaled every screen refresh so the surfer stays in the
/// middle, showing as much of the picture as you've zoomed to. Without a path it shows the
/// whole picture, and a tap reports where in the picture it landed. A still
/// frame to tap on can be pinched and dragged to look closer.
struct FollowingVideoView: UIViewRepresentable {
    let loop: LoopPlayer
    let videoSize: CGSize
    let orientation: CGImagePropertyOrientation
    let track: WaveTrack?
    /// How much of the picture's height is shown top to bottom, as a share of it.
    let span: Double
    /// The wave whose still frame is up to tap the surfer on, if any. A new one
    /// starts unzoomed.
    var stillID: Wave.ID?
    var onTap: ((CGPoint) -> Void)?
    /// A tap when there's no point to tap on: hides or shows the bars.
    var onPlainTap: (() -> Void)?
    var onSwipe: (Int) -> Void
    var onZoom: (Double) -> Void
    /// One of two clips being compared: drag to look around, double-tap to
    /// centre, no swiping to another wave.
    var comparing = false

    func makeUIView(context: Context) -> FollowingPlayerView {
        FollowingPlayerView(loop: loop, comparing: comparing)
    }

    func updateUIView(_ view: FollowingPlayerView, context: Context) {
        view.videoSize = videoSize
        view.orientation = orientation
        view.track = track
        view.span = span
        view.stillID = stillID
        view.onTap = onTap
        view.onPlainTap = onPlainTap
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
    var track: WaveTrack? {
        didSet { if track != oldValue { updateGestures() } }
    }
    var span: Double = 0.5 {
        didSet { if span != oldValue { needsRedraw = true } }
    }
    var stillID: UUID? {
        didSet { if stillID != oldValue { setStill(scale: 1, offset: .zero) } }
    }
    var onTap: ((CGPoint) -> Void)?
    var onPlainTap: (() -> Void)?
    var onSwipe: (Int) -> Void = { _ in }
    var onZoom: (Double) -> Void = { _ in }
    private let comparing: Bool
    /// Where the view has been dragged to while following, as a share of what's
    /// shown: the surfer stays put that far from the middle.
    private var lookOffset: CGPoint = .zero
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
    /// The copy of the clip the player's newest frame came from. Once it's
    /// gone, so is the frame: the last frame of the video before, drawn with
    /// the new one's turn, showed for a moment upside down.
    private weak var playerFrameItem: AVPlayerItem?
    private var drawnFrame: LoopFrames.Frame?
    private var needsRedraw = false

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// How many surfers fit top to bottom, at zoom 1, back when zoom went by
    /// the surfer's size: what the clips cut by hand showed.
    static let heightsInView = 9.0
    /// The closest you can zoom in, as a share of the picture's height.
    static let leastSpan = 0.04

    init(loop: LoopPlayer, comparing: Bool = false) {
        let player = loop.player
        self.loop = loop
        self.comparing = comparing
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
        if comparing {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] where !comparing {
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
        updateGestures()
    }

    /// Dragging moves a zoomed frame, or, when comparing, where the view looks
    /// while following; otherwise a sideways swipe changes wave.
    private func updateGestures() {
        pan.isEnabled = stillScale > 1.01 || (comparing && track != nil)
        for swipe in swipes { swipe.isEnabled = !pan.isEnabled }
    }

    /// Back to the surfer in the middle, or the whole picture.
    private func recenter() {
        lookOffset = .zero
        needsRedraw = true
        setStill(scale: 1, offset: .zero)
    }

    /// A clip being compared that isn't followed is pinched and dragged as
    /// the still frame is.
    private var zoomsPicture: Bool {
        stillID != nil || (comparing && track == nil)
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
                playerFrame = (shownAt.seconds, buffer, nil)
                playerFrameItem = player.currentItem
            }
        }
        let items = (player as? AVQueuePlayer)?.items() ?? [player.currentItem].compactMap { $0 }
        if let item = playerFrameItem, !items.contains(item) { playerFrameItem = nil }
        if playerFrameItem == nil { playerFrame = nil }
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
        draw(frame, following: track)
    }

    private func draw(_ frame: LoopFrames.Frame, following track: WaveTrack) {
        // Frames from the player arrive as the camera stored them: on their
        // side for a phone held upright, upside down for one turned the other
        // way. Those got ready for sliding are already upright, and only the
        // part around the surfer.
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let region = frame.region ?? whole
        let image = frame.region == nil
            ? CIImage(cvPixelBuffer: frame.buffer).oriented(orientation)
            : CIImage(cvPixelBuffer: frame.buffer, options: [.colorSpace: Self.sRGB])
        if frame.region == nil {
            pictureAspect = image.extent.width / image.extent.height
        } else if videoSize.height > 0 {
            pictureAspect = videoSize.width / videoSize.height
        }
        // How many pixels the whole picture would be, in this image's pixels.
        let w = image.extent.width / region.width, h = image.extent.height / region.height

        // What part of the picture to show, as fractions of it, from the top-left.
        // Zoomed out past an edge of the picture, the rest is black, out to
        // where the whole picture fits.
        let shownH = min(CGFloat(span), wholeHeight)
        let shownW = shownH * (bounds.width / bounds.height) / pictureAspect
        let view = FollowView(track: track, shownW: shownW, shownH: shownH, look: lookOffset)
        let pixels = bounds.height * traitCollection.displayScale
        // Compared clips keep their whole wave ready, so at 2× rather than 3×.
        loop?.follow(view, pixels: comparing ? bounds.height * min(2, traitCollection.displayScale) : pixels,
                     orientation: orientation)
        let shown = view.rect(at: frame.time)
        // Core Image measures from the bottom-left.
        let crop = CGRect(x: image.extent.minX + (shown.minX - region.minX) * w,
                          y: image.extent.minY + (region.maxY - shown.maxY) * h,
                          width: shown.width * w, height: shown.height * h)
        let scale = min(1, pixels / crop.height)
        let piece = LoopFrames.cut(image, to: crop, size: CGSize(width: crop.width * scale, height: crop.height * scale))
        guard let picture = context.createCGImage(piece, from: piece.extent) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        followLayer.contents = picture
        followLayer.isHidden = false
        playerLayer.isHidden = true
        CATransaction.commit()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let onTap else { onPlainTap?(); return }
        // Through the still frame's zoom, to a point on the picture itself.
        let p = layer.convert(gesture.location(in: self), to: playerLayer)
        let f = playerLayer.videoRect
        guard f.contains(p) else { return }
        onTap(CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        if zoomsPicture {
            // Keep the spot between the fingers under them.
            let p = gesture.location(in: self)
            let middle = CGPoint(x: bounds.midX, y: bounds.midY)
            let s = min(12, max(1, stillScale * gesture.scale))
            let k = s / stillScale
            setStill(scale: s, offset: CGPoint(x: p.x - middle.x - (p.x - middle.x - stillOffset.x) * k,
                                               y: p.y - middle.y - (p.y - middle.y - stillOffset.y) * k))
        } else if track != nil {
            // Out as far as the whole picture.
            let most = Double(wholeHeight)
            onZoom(min(max(Self.leastSpan, min(span, most) / Double(gesture.scale)), most))
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
        if comparing, track != nil, stillID == nil {
            // The picture moves with the finger, at most until the surfer
            // reaches the edge of the view.
            lookOffset = CGPoint(x: min(max(lookOffset.x - d.x / bounds.width, -0.5), 0.5),
                                 y: min(max(lookOffset.y - d.y / bounds.height, -0.5), 0.5))
            needsRedraw = true
            gesture.setTranslation(.zero, in: self)
            return
        }
        setStill(scale: stillScale, offset: CGPoint(x: stillOffset.x + d.x, y: stillOffset.y + d.y))
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func handleDoubleTap() { recenter() }

    /// Swiping left brings the next wave in, as paging through photos does.
    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onSwipe(gesture.direction == .left ? 1 : -1)
    }
}

/// The frames around a wave's clip, with a handle at each end to move where
/// it starts and ends, as trimming a video in Photos does. It shows a few
/// seconds either side to drag out into; holding a handle against either end
/// of the strip brings in more of the video that way, faster the longer it's
/// held, as far as the video goes.
struct TrimStrip: View {
    let asset: AVAsset
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// The moment to show while a handle moves.
    var onMove: (Double) -> Void

    /// The stretch of the video the strip shows.
    @State private var lo: Double?
    @State private var hi: Double = 0
    @State private var thumbs: [(time: Double, image: UIImage)] = []
    @State private var held: Handle?
    @State private var heldSince = Date()
    @State private var fingerX: CGFloat = 0
    /// How far from the handle's middle the finger took hold of it.
    @State private var grab: CGFloat = 0
    @State private var width: CGFloat = 1

    private enum Handle { case start, end }
    /// Seconds shown either side of the clip to begin with.
    private static let pad = 3.0
    private static let shortest = 0.5
    private static let handle: CGFloat = 16
    /// A finger this close to either end of the strip brings in more video.
    private static let edgeZone: CGFloat = 30
    private static let tick = 1.0 / 30

    var body: some View {
        VStack(spacing: 8) {
            Text(String(format: "%.1fs", end - start))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white)
            GeometryReader { geo in
                strip(height: geo.size.height)
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { width = geo.size.width }
            }
            .frame(height: 52)
            .coordinateSpace(name: "trim")
            .padding(.horizontal, 16)
        }
        .onAppear {
            guard lo == nil else { return }
            lo = max(0, start - Self.pad)
            hi = min(duration, end + Self.pad)
        }
        .onReceive(Timer.publish(every: Self.tick, on: .main, in: .common).autoconnect()) { _ in bringInMore() }
        .task(id: thumbKey) { await makeThumbs() }
    }

    // MARK: Drawing

    private var inner: CGFloat { max(1, width - 2 * Self.handle) }
    private var slotCount: Int { max(4, Int(inner / 36)) }

    private func x(_ t: Double) -> CGFloat {
        guard let lo, hi > lo else { return Self.handle }
        return Self.handle + inner * CGFloat((t - lo) / (hi - lo))
    }

    private func time(_ x: CGFloat) -> Double {
        guard let lo, hi > lo else { return 0 }
        let f = min(max(0, (x - Self.handle) / inner), 1)
        return lo + Double(f) * (hi - lo)
    }

    private func slotTime(_ i: Int) -> Double {
        guard let lo else { return 0 }
        return lo + (Double(i) + 0.5) * (hi - lo) / Double(slotCount)
    }

    private func strip(height: CGFloat) -> some View {
        let xs = x(start), xe = x(end)
        let count = slotCount
        let slot = inner / CGFloat(count)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    Group {
                        if let image = nearest(slotTime(i)) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: slot, height: height)
                    .clipped()
                }
            }
            .offset(x: Self.handle)
            // Outside the clip is dimmed.
            Rectangle().fill(.black.opacity(0.6))
                .frame(width: max(0, xs - Self.handle), height: height)
                .offset(x: Self.handle)
            Rectangle().fill(.black.opacity(0.6))
                .frame(width: max(0, width - Self.handle - xe), height: height)
                .offset(x: xe)
            // The clip, edged in yellow.
            Rectangle().strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(0, xe - xs), height: height)
                .offset(x: xs)
            handleView(.start, height: height).offset(x: xs - Self.handle)
            handleView(.end, height: height).offset(x: xe)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func handleView(_ which: Handle, height: CGFloat) -> some View {
        UnevenRoundedRectangle(cornerRadii: which == .start
                               ? .init(topLeading: 6, bottomLeading: 6)
                               : .init(bottomTrailing: 6, topTrailing: 6))
            .fill(Color.yellow)
            .overlay {
                Image(systemName: which == .start ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(width: Self.handle, height: height)
            // Easier to catch than it is to see.
            .contentShape(Rectangle().inset(by: -14))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                    .onChanged { value in
                        if held != which {
                            held = which
                            heldSince = Date()
                            let middle = which == .start ? x(start) - Self.handle / 2 : x(end) + Self.handle / 2
                            grab = value.startLocation.x - middle
                        }
                        fingerX = value.location.x
                        follow()
                    }
                    .onEnded { _ in held = nil }
            )
    }

    private func nearest(_ t: Double) -> UIImage? {
        thumbs.min { abs($0.time - t) < abs($1.time - t) }?.image
    }

    // MARK: Moving

    /// Puts the held handle under the finger.
    private func follow() {
        guard let held else { return }
        let middle = fingerX - grab
        if held == .start {
            start = min(max(0, time(middle + Self.handle / 2)), end - Self.shortest)
            onMove(start)
        } else {
            end = max(min(duration, time(middle - Self.handle / 2)), start + Self.shortest)
            onMove(end)
        }
    }

    /// A handle held against an end of the strip brings in more of the video
    /// that way, faster the further in and the longer it's held.
    private func bringInMore() {
        guard held != nil, let lo else { return }
        let heldFor = Date().timeIntervalSince(heldSince)
        let speed = 3 * (1 + min(heldFor, 10) / 2)
        let left = (Self.edgeZone - fingerX) / Self.edgeZone
        let right = (fingerX - (width - Self.edgeZone)) / Self.edgeZone
        if left > 0, lo > 0 {
            self.lo = max(0, lo - speed * Double(min(1, max(0.3, left))) * Self.tick)
            follow()
        } else if right > 0, hi < duration {
            hi = min(duration, hi + speed * Double(min(1, max(0.3, right))) * Self.tick)
            follow()
        }
    }

    // MARK: Frames

    /// Changes whenever the strip shows a different stretch.
    private var thumbKey: String {
        guard let lo else { return "" }
        return String(format: "%.2f-%.2f-%d", lo, hi, slotCount)
    }

    /// A small frame for each slot, once the strip has stopped moving. Ones
    /// already made are kept, so the strip fills in rather than flashing.
    private func makeThumbs() async {
        guard let lo, hi > lo else { return }
        try? await Task.sleep(for: .milliseconds(150))
        let count = slotCount
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        let near = (hi - lo) / Double(count) / 2
        let tolerance = CMTime(seconds: near, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        for i in 0..<count {
            guard !Task.isCancelled else { return }
            let t = lo + (Double(i) + 0.5) * (hi - lo) / Double(count)
            if thumbs.contains(where: { abs($0.time - t) < near }) { continue }
            guard let made = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            thumbs.append((t, UIImage(cgImage: made.image)))
        }
        if thumbs.count > 120 { thumbs.removeFirst(thumbs.count - 120) }
    }
}

/// A finished export, and whether it made it into Photos.
struct SharedFile: Identifiable {
    let url: URL
    var saved = false
    var id: URL { url }
}

/// Where a wave starts and ends in an export.
struct ExportCut: Equatable {
    var start: Double
    var end: Double
}

/// The system share sheet: AirDrop, Messages, Instagram, Save to Files…
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var excluded: [UIActivity.ActivityType] = []

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = excluded
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
