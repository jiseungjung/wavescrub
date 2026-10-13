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
    @State private var renamingWave: Wave?
    @State private var renameText = ""
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
        .alert("Can't open video", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Rename Wave", isPresented: Binding(
            get: { renamingWave != nil },
            set: { if !$0 { renamingWave = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let wave = renamingWave { model.renameWave(wave.id, to: renameText) }
            }
        }
        .task { model.restoreLast() }
    }

    // MARK: Layouts

    /// Upright: video on top, both scrubbers big underneath for your thumb.
    private var portraitLayout: some View {
        VStack(spacing: 10) {
            HStack {
                openMenu
                Spacer()
                Text(model.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14)

            video

            VStack(spacing: 10) {
                HStack {
                    timeLabel
                    Spacer()
                    transport
                }
                if let wave = selectedWave { WaveInlineEditor(wave: wave) }
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
                        timeLabel
                        Spacer()
                        transport
                    }
                    .frame(height: 26)
                    if let wave = selectedWave { WaveInlineEditor(wave: wave) }
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

    private var timeLabel: some View {
        Text(formatTime(model.currentTime))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
    }

    private var transport: some View {
        // Every label is its own width (no padding frames), so the gaps
        // between them are exactly the spacing and all equal.
        HStack(spacing: 14) {
            // Tap: mark a wave here. Hold: jump, rename, recolor, or delete one.
            Menu {
                Button { model.markWave() } label: { Label("Mark wave here", systemImage: "flag") }
                if !model.waves.isEmpty {
                    Section("Waves") {
                        ForEach(model.waves) { wave in
                            Menu {
                                Button { model.jump(to: wave) } label: {
                                    Label("Jump", systemImage: "arrow.right.circle")
                                }
                                Button {
                                    renameText = wave.name
                                    renamingWave = wave
                                } label: { Label("Rename…", systemImage: "pencil") }
                                Menu {
                                    ForEach(WaveColor.allCases) { c in
                                        Button {
                                            model.setColor(wave.id, to: c)
                                        } label: {
                                            if wave.color == c {
                                                Label(c.name, systemImage: "checkmark")
                                            } else {
                                                Text(c.name)
                                            }
                                        }
                                    }
                                } label: { Label("Color", systemImage: "paintpalette") }
                                Button(role: .destructive) { model.deleteWave(wave.id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Label("\(wave.name)  ·  \(formatTime(wave.time, decimals: 0))", systemImage: "flag.fill")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "flag.fill").font(.title3)
            } primaryAction: {
                model.markWave()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            // How much time the top bar spans: tap to flip between finding the
            // wave and watching it slowly.
            Button {
                tapeSpan = tapeSpan < 60 ? FineTape.searchSpan : FineTape.defaultSpan
            } label: {
                Text(FineTape.spanLabel(tapeSpan))
                    .font(.system(.callout, design: .monospaced))
            }
            Menu {
                ForEach([0.1, 0.25, 0.5, 1, 2] as [Float], id: \.self) { r in
                    Button("\(rateLabel(r))×") { model.rate = r }
                }
            } label: {
                Text("\(rateLabel(model.rate))×")
                    .font(.system(.callout, design: .monospaced))
            }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 22, height: 28)
            }
        }
    }

    private func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)
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

/// Shown inline whenever playback lands exactly on a wave's time.
struct WaveInlineEditor: View {
    @EnvironmentObject private var model: PlayerModel
    let wave: Wave
    @State private var name = ""
    @State private var showColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { showColors.toggle() } label: {
                    Circle().fill(wave.color.color).frame(width: 18, height: 18)
                }
                TextField("Name", text: $name, onCommit: { model.renameWave(wave.id, to: name) })
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { model.renameWave(wave.id, to: name) }
                Text(formatTime(wave.time, decimals: 0))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { model.deleteWave(wave.id) } label: {
                    Image(systemName: "trash").font(.callout)
                }
                Button { model.selectedWaveID = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                }
            }
            if showColors {
                HStack(spacing: 10) {
                    ForEach(WaveColor.allCases) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white, lineWidth: wave.color == c ? 2 : 0))
                            .onTapGesture {
                                model.setColor(wave.id, to: c)
                                showColors = false
                            }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { name = wave.name }
        .onChange(of: wave.id) {
            name = wave.name
            showColors = false
        }
    }
}
