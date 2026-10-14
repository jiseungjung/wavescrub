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
    @State private var controlsHidden = false
    @State private var showLoops = false
    @AppStorage(FineTape.spanKey) private var tapeSpan: Double = FineTape.defaultSpan

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if model.hasVideo {
                    if landscape { landscapeLayout } else { portraitLayout }
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
        .fullScreenCover(isPresented: $showLoops) {
            WaveLoopView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
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
            HStack(spacing: 18) {
                openMenu
                loopButton
                Spacer()
                Text(model.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
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
                        openMenu
                        loopButton
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
            Text("Open a long video and find your wave.\nNothing is copied into the app.")
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

    private var openMenu: some View {
        Menu {
            Button { openPhotos() } label: { Label("From Photos", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("From Files", systemImage: "folder") }
            if !model.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.recents) { recent in
                        Menu {
                            Button { model.openRecent(recent) } label: { Label("Open", systemImage: "play.fill") }
                            Button(role: .destructive) { model.removeRecent(recent.id) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        } label: {
                            Label(recent.title, systemImage: recent.kind == .photo ? "photo" : "doc")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "film.stack").font(.title3)
        }
    }

    /// Opens the screen that loops each marked wave, following you.
    private var loopButton: some View {
        Button { showLoops = true } label: {
            Image(systemName: "repeat").font(.title3)
        }
        .disabled(model.waves.isEmpty)
    }

    private var timeLabel: some View {
        Text(formatTime(model.currentTime))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
    }

    private var transport: some View {
        // Every label is its own width (no padding frames), so the gaps
        // between them are exactly the spacing and all equal.
        HStack(spacing: 14) {
            // Off a wave, marks one here. On a wave, deletes it.
            if let wave = selectedWave {
                Button { model.deleteWave(wave.id) } label: {
                    Image(systemName: "trash").font(.title3)
                }
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

/// A wave's name you can type into directly, and its dot: tap the dot for
/// the next color.
struct WaveTag: View {
    @EnvironmentObject private var model: PlayerModel
    let wave: Wave
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Button {
                let all = WaveColor.allCases
                let next = all[(all.firstIndex(of: wave.color)! + 1) % all.count]
                model.setColor(wave.id, to: next)
            } label: {
                Circle().fill(wave.color.color).frame(width: 12, height: 12)
                    .padding(4)
            }
            TextField("Name", text: $name)
                .submitLabel(.done)
                .fixedSize()
                .onChange(of: name) { model.renameWave(wave.id, to: name) }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.leading, 2)
        .padding(.trailing, 9)
        .padding(.vertical, 1)
        .background(wave.color.color.opacity(0.35), in: Capsule())
        .onAppear { name = wave.name }
        .onChange(of: wave.id) { name = wave.name }
    }
}
