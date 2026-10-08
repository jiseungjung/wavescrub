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

    /// Sideways: video edge to edge, controls along the bottom.
    /// Tap the video to hide or show them.
    private var landscapeLayout: some View {
        ZStack(alignment: .bottom) {
            video.ignoresSafeArea()
            if !controlsHidden {
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        openMenu
                        timeLabel
                        Spacer()
                        transport
                    }
                    FineTape().frame(height: 58)
                    OverviewStrip().frame(height: 42)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
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
        Text("\(formatTime(model.currentTime)) / \(formatTime(model.duration, decimals: 0))")
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 16) {
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
                    .frame(width: 36)
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
