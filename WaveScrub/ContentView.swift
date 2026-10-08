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
    @State private var showWaves = false
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
        .sheet(isPresented: $showWaves) { WavesSheet() }
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
                FineTape().frame(height: 84)
                OverviewStrip().frame(height: 56)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    /// Sideways: video edge to edge, controls in a thin band hugging the
    /// bottom edge. Tap the video to hide or show them.
    private var landscapeLayout: some View {
        ZStack(alignment: .bottom) {
            video
            if !controlsHidden {
                VStack(spacing: 4) {
                    HStack(spacing: 14) {
                        openMenu
                        timeLabel
                        Spacer()
                        transport
                    }
                    .frame(height: 26)
                    FineTape().frame(height: 44)
                    OverviewStrip().frame(height: 34)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .center)
                )
                .transition(.opacity)
            }
        }
        // Down into the home-bar area; the first swipe there won't leave the app.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .defersSystemGestures(on: .bottom)
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
        HStack(spacing: 16) {
            // Tap: mark a wave here. Hold: jump to a wave, or rename them.
            Menu {
                Button { model.markWave() } label: { Label("Mark wave here", systemImage: "flag") }
                if !model.waves.isEmpty {
                    Section {
                        ForEach(model.waves) { wave in
                            Button("\(wave.name)  ·  \(formatTime(wave.time, decimals: 0))") { model.jump(to: wave) }
                        }
                    }
                    Button { showWaves = true } label: { Label("Rename or delete…", systemImage: "pencil") }
                }
            } label: {
                Image(systemName: "flag.fill").font(.title3)
            } primaryAction: {
                model.markWave()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            // How much time the top bar spans.
            Menu {
                ForEach(FineTape.spanChoices, id: \.self) { span in
                    Button(FineTape.spanLabel(span)) { tapeSpan = span }
                }
            } label: {
                Text(FineTape.spanLabel(tapeSpan))
                    .font(.system(.callout, design: .monospaced))
                    .frame(minWidth: 40)
            }
            Menu {
                ForEach([0.1, 0.25, 0.5, 1, 2] as [Float], id: \.self) { r in
                    Button("\(rateLabel(r))×") { model.rate = r }
                }
            } label: {
                Text("\(rateLabel(model.rate))×")
                    .font(.system(.callout, design: .monospaced))
                    .frame(minWidth: 44)
            }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 36, height: 28)
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

/// Every wave marked on this video: rename by typing, swipe to delete,
/// tap the arrow to go there.
struct WavesSheet: View {
    @EnvironmentObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.waves) { wave in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { wave.name },
                            set: { model.renameWave(wave.id, to: $0) }
                        ))
                        Text(formatTime(wave.time, decimals: 0))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            model.jump(to: wave)
                            dismiss()
                        } label: {
                            Image(systemName: "arrow.right.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { model.deleteWaves(at: $0) }
            }
            .navigationTitle("Waves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
