import Photos
import SwiftUI

@main
struct WaveScrubApp: App {
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showVideos = false
    @State private var controlsHidden = false
    /// Finding waves, rather than watching them on the loop screen.
    @State private var finding = false
    /// Whether the loop screen is coming back from finding waves, rather than
    /// starting on a freshly opened video.
    @State private var backFromFinding = false
    @AppStorage(FineTape.spanKey) private var tapeSpan: Double = FineTape.defaultSpan

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if model.hasVideo {
                    // The loop screen is home; finding waves is a mode you
                    // switch into in place, like editing in Photos.
                    if finding {
                        Group { if landscape { landscapeLayout } else { portraitLayout } }
                            .transition(.opacity)
                    } else {
                        WaveLoopView(videosButton: AnyView(openMenu), onFind: { setFinding(true) },
                                     startAtFirst: !backFromFinding)
                            .transition(.opacity)
                    }
                } else {
                    emptyState
                }
                if let message = model.loadingMessage {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(message).font(.callout)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .statusBarHidden(landscape)
            .persistentSystemOverlays(landscape ? .hidden : .automatic)
        }
        .overlayPreferenceValue(VideosButtonAnchor.self) { videosCard($0) }
        .sheet(isPresented: $showPhotos) {
            PhotoVideoPicker { id in
                showPhotos = false
                if let id { model.openPhotoAsset(id: id) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFiles) {
            VideoFilePicker { url in
                showFiles = false
                if let url { model.openFile(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $model.showingPeople) {
            PeopleSheet()
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
        // Every video opens on the loop screen.
        .onChange(of: model.openedCount) {
            finding = false
            backFromFinding = false
        }
        .alert("Can't open video", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { model.restoreLast() }
    }

    // MARK: Layouts

    /// Upright: video on top, both scrubbers big underneath for your thumb.
    private var portraitLayout: some View {
        VStack(spacing: 10) {
            ZStack {
                Text("Find waves").font(.headline)
                HStack {
                    doneButton
                    Spacer()
                    peopleButton
                }
            }
            .padding(.horizontal, 14)

            video

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    timeLabel
                    waveTag
                    Spacer(minLength: 8)
                    transport
                }
                FineTape().frame(height: 84)
                OverviewStrip().frame(height: 56)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    /// Sideways: video edge to edge, controls in a thin band just above the
    /// home bar. Tap the video to hide or show them.
    private var landscapeLayout: some View {
        ZStack(alignment: .bottom) {
            video.ignoresSafeArea()
            if !controlsHidden {
                VStack(spacing: 4) {
                    HStack(spacing: 14) {
                        doneButton
                        peopleButton
                        timeLabel
                        waveTag
                        Spacer(minLength: 8)
                        transport
                    }
                    .frame(height: 26)
                    FineTape().frame(height: 44)
                    OverviewStrip().frame(height: 34)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .center)
                )
                .transition(.opacity)
            }
        }
    }

    private var selectedWave: Wave? {
        guard let id = model.selectedWaveID else { return nil }
        return model.waves.first { $0.id == id }
    }

    private var video: some View {
        ZoomableVideoView(player: model.player, videoSize: model.videoSize) {
            withAnimation(.easeInOut(duration: 0.2)) { controlsHidden.toggle() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "water.waves").font(.system(size: 56)).foregroundStyle(.cyan)
            Text("WaveScrub").font(.largeTitle.bold())
            Text("Open a long video and find a wave.\nNothing is copied into the app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { openPhotos() } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: Pieces

    /// Opening a video: from Photos, from Files, or one opened before. Opens
    /// a card under the button (or above it, at the bottom of the screen).
    private var openMenu: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { showVideos.toggle() }
        } label: {
            Image(systemName: "film.stack").font(.title3)
        }
        .anchorPreference(key: VideosButtonAnchor.self, value: .bounds) { $0 }
    }

    /// The card, laid over everything, lined up with the videos button. A tap
    /// anywhere else closes it.
    private func videosCard(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geo in
            if showVideos, let anchor {
                let button = geo[anchor]
                let width = min(320, geo.size.width - 24)
                let height = videosCardHeight
                let below = button.maxY + 8 + height <= geo.size.height
                let x = min(max(12, button.minX - 6), geo.size.width - width - 12)
                let y = below ? button.maxY + 8 : button.minY - 8 - height
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showVideos = false } }
                    videosList
                        .frame(width: width, height: height)
                        .modifier(CardGlass())
                        .offset(x: x, y: y)
                        .transition(.scale(scale: 0.92, anchor: below ? .topLeading : .bottomLeading)
                            .combined(with: .opacity))
                }
            }
        }
    }

    private static let videoRowHeight: CGFloat = 50
    private static let visibleRecents = 5
    private static let recentHeader: CGFloat = 22

    private var videosCardHeight: CGFloat {
        let recents = model.recents.isEmpty ? 0 : Self.recentHeader + CGFloat(min(model.recents.count, Self.visibleRecents)) * Self.videoRowHeight
        return 2 * Self.videoRowHeight + 1 + recents + 6
    }

    private var videosList: some View {
        VStack(spacing: 0) {
            // Always there; only the recent videos below scroll.
            videoRow("From Photos", icon: "photo.on.rectangle", tint: .accentColor) { afterClosingVideos { openPhotos() } }
            Divider().overlay(Color.white.opacity(0.12)).padding(.leading, 54).padding(.trailing, 16)
            videoRow("From Files", icon: "folder", tint: .accentColor) { afterClosingVideos { showFiles = true } }
            if !model.recents.isEmpty {
                Text("Recent")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: Self.recentHeader, alignment: .bottom)
                List {
                    ForEach(model.recents) { recent in
                        videoRow(recent.title, icon: recent.kind == .photo ? "photo" : "doc", tint: .white) {
                            showVideos = false
                            model.openRecent(recent)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                        .listRowSeparator(recent.id == model.recents.last?.id ? .hidden : .visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 54 }
                    }
                    .onDelete { offsets in
                        for i in offsets { model.removeRecent(model.recents[i].id) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, Self.videoRowHeight)
            }
            Spacer(minLength: 0)
        }
    }

    private func videoRow(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.videoRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func afterClosingVideos(_ then: () -> Void) {
        showVideos = false
        then()
    }

    /// Back to watching, on the wave marked last.
    private var doneButton: some View {
        Button("Done") { setFinding(false) }
            .font(.body.weight(.semibold))
    }

    private func setFinding(_ on: Bool) {
        if !on {
            model.player.pause()
            backFromFinding = true
        }
        withAnimation(.easeInOut(duration: 0.25)) { finding = on }
    }

    /// Who's surfing in this video. Only you, unless you add someone.
    private var peopleButton: some View {
        Button { model.showingPeople = true } label: {
            Image(systemName: model.surfers.count > 1 ? "person.2.fill" : "person.2").font(.title3)
        }
    }

    private var timeLabel: some View {
        Text(formatTime(model.currentTime))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
            .fixedSize()
    }

    private var transport: some View {
        // Every label is its own width (no padding frames), so the gaps
        // between them are exactly the spacing and all equal.
        HStack(spacing: 14) {
            // Off a wave, marks one here: with the flag when it's only you, or
            // with the button of whoever is riding. On a wave, deletes it.
            if let wave = selectedWave {
                // Here, not beside the name, so it doesn't move as the name changes.
                StarButton(wave: wave)
                Button { model.deleteWave(wave.id) } label: {
                    Image(systemName: "trash").font(.title3)
                }
            } else if model.surfers.count > 1 {
                SurferButtons()
            } else {
                Button {
                    model.markWave()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: "flag.fill").font(.title3)
                }
            }
            // How much time the top bar spans: tap to flip between finding the
            // wave and watching it slowly.
            Button {
                tapeSpan = tapeSpan < 60 ? FineTape.searchSpan : FineTape.defaultSpan
            } label: {
                Text(FineTape.spanLabel(tapeSpan))
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize()
            }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 22, height: 28)
            }
        }
    }

    /// The wave you're on, beside the time. Empty between waves, so nothing
    /// else moves.
    @ViewBuilder private var waveTag: some View {
        if let wave = selectedWave { WaveTag(wave: wave) }
    }

    /// Full library access is what lets the app read the original file in
    /// place; with limited access only the videos you've allowed will open.
    private func openPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                if status == .authorized || status == .limited {
                    showPhotos = true
                } else {
                    model.errorMessage = "Allow Photos access in Settings › WaveScrub."
                }
            }
        }
    }
}

/// A wave's name you can type into directly, and its dot: tap the dot to
/// say who rode it. The color is always theirs.
struct WaveTag: View {
    @EnvironmentObject private var model: PlayerModel
    let wave: Wave
    @State private var name = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Surfer", selection: Binding(
                    get: { wave.surferID },
                    set: { if let id = $0 { model.setSurfer(wave.id, to: id) } }
                )) {
                    ForEach(model.surfers) { surfer in
                        Label(surfer.name.isEmpty ? "Me" : surfer.name, systemImage: "circle.fill")
                            .tint(surfer.color.color)
                            .tag(Optional(surfer.id))
                    }
                }
                Button { model.showingPeople = true } label: { Label("Add person", systemImage: "person.badge.plus") }
            } label: {
                Circle().fill(wave.color.color).frame(width: 12, height: 12)
                    .padding(4)
            }
            // Plain text until tapped, so the tap can't place the cursor or
            // select a word; the box that replaces it starts at the end.
            if typing {
                TextField("Name", text: $name)
                    .submitLabel(.done)
                    .fixedSize()
                    .focused($focused)
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) {
                        if !focused {
                            typing = false
                            name = wave.name
                        }
                    }
                    .onChange(of: name) { model.renameWave(wave.id, to: name) }
            } else {
                Text(name.isEmpty ? "Name" : name)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { typing = true }
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.leading, 2)
        .padding(.trailing, 9)
        .padding(.vertical, 1)
        .background(wave.color.color.opacity(0.35), in: Capsule())
        .onAppear { name = wave.name }
        .onChange(of: wave.id) {
            name = wave.name
            typing = false
        }
        // Renumbered or renamed from elsewhere.
        .onChange(of: wave.name) { if !typing { name = wave.name } }
    }
}

/// Tap to star a wave you'll want to find again; tap again to take it off.
struct StarButton: View {
    @EnvironmentObject private var model: PlayerModel
    let wave: Wave

    var body: some View {
        Button {
            model.toggleStar(wave.id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: wave.starred ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(wave.starred ? .yellow : .white.opacity(0.7))
        }
    }
}

/// Where the videos button is, so its card can line up with it.
private struct VideosButtonAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Liquid Glass where the system has it; a dark card before that.
private struct CardGlass: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color(white: 0.13), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.08)))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        }
    }
}
