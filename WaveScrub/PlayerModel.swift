import AVFoundation
import Combine
import Photos
import UIKit

/// A marked wave: where it starts, and what you called it.
struct Wave: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var time: Double
}

/// Owns the AVPlayer and everything the screens read about the open video.
///
/// Videos are never copied: a Photos video is opened through PHImageManager,
/// which hands back an asset reading the library's own file, and a Files video
/// is opened in place through a security-scoped URL.
@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var hasVideo = false
    @Published private(set) var title = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [UIImage?] = []
    @Published private(set) var loadingMessage: String?
    @Published private(set) var waves: [Wave] = []
    @Published var errorMessage: String?
    @Published var rate: Float = 1 {
        didSet { player.defaultRate = rate; if isPlaying { player.rate = rate } }
    }

    private var asset: AVAsset?
    /// Which video the waves belong to: the Photos id or the file's path.
    private var videoKey: String?
    private var securityScopedURL: URL?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var lastSavedAt = Date.distantPast

    // Seek chasing (Apple QA1820): only one seek is in flight at a time, and
    // when it lands we jump straight to wherever the finger is now, so a fast
    // drag never queues up hundreds of stale seeks.
    private var seekInFlight = false
    private var chaseTarget = CMTime.zero
    private var chaseTolerance = CMTime.zero
    private var chaseGeneration = 0
    private var scrubbing = false

    static let thumbnailCount = 60

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing, !self.seekInFlight else { return }
                self.currentTime = time.seconds
                if self.isPlaying, Date().timeIntervalSince(self.lastSavedAt) > 3 { self.savePosition() }
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let playing = status != .paused
                if self.isPlaying && !playing { self.savePosition() }
                self.isPlaying = playing
            }
            .store(in: &cancellables)
    }

    // MARK: Opening

    func openPhotoAsset(id: String, resumeAt: Double? = nil) {
        guard let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            errorMessage = "That video can't be read. In Settings › WaveScrub › Photos, choose Full Access."
            return
        }
        loadingMessage = "Opening…"
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress, _, _, _ in
            Task { @MainActor in
                self?.loadingMessage = "Downloading from iCloud… \(Int(progress * 100))%"
            }
        }
        let title = phAsset.creationDate.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "Video"
        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { [weak self] avAsset, _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let avAsset else {
                    self.loadingMessage = nil
                    self.errorMessage = "Photos couldn't open that video."
                    return
                }
                self.releaseSecurityScope()
                let defaults = UserDefaults.standard
                defaults.set("photos", forKey: Keys.source)
                defaults.set(id, forKey: Keys.photoID)
                await self.load(avAsset, title: title, key: "photo:" + id, resumeAt: resumeAt)
            }
        }
    }

    func openFile(_ url: URL, resumeAt: Double? = nil) {
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() { securityScopedURL = url }
        let defaults = UserDefaults.standard
        if let bookmark = try? url.bookmarkData() {
            defaults.set("file", forKey: Keys.source)
            defaults.set(bookmark, forKey: Keys.fileBookmark)
        }
        loadingMessage = "Opening…"
        Task {
            await load(AVURLAsset(url: url), title: url.deletingPathExtension().lastPathComponent,
                       key: "file:" + url.path, resumeAt: resumeAt)
        }
    }

    /// Reopens whatever was open last time, at the same moment.
    func restoreLast() {
        guard !hasVideo else { return }
        let defaults = UserDefaults.standard
        let time = defaults.double(forKey: Keys.time)
        switch defaults.string(forKey: Keys.source) {
        case "photos":
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited,
                  let id = defaults.string(forKey: Keys.photoID) else { return }
            openPhotoAsset(id: id, resumeAt: time)
        case "file":
            guard let data = defaults.data(forKey: Keys.fileBookmark) else { return }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
            openFile(url, resumeAt: time)
        default:
            break
        }
    }

    private func load(_ asset: AVAsset, title: String, key: String, resumeAt: Double?) async {
        thumbnailGenerator?.cancelAllCGImageGeneration()
        player.pause()
        do {
            let duration = try await asset.load(.duration).seconds
            var fps = 30.0
            var size = CGSize.zero
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (rate, natural, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
                if rate > 0 { fps = Double(rate) }
                let r = CGRect(origin: .zero, size: natural).applying(transform)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            self.asset = asset
            self.title = title
            self.duration = duration
            self.frameRate = fps
            self.videoSize = size
            self.videoKey = key
            self.waves = Self.loadWaves(key: key)
        } catch {
            loadingMessage = nil
            errorMessage = "Couldn't read that video."
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        currentTime = 0
        hasVideo = true
        loadingMessage = nil
        if let resumeAt, resumeAt > 0, resumeAt < duration { seek(to: resumeAt, tolerance: 0) }
        generateThumbnails()
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: Thumbnails for the whole-video strip

    private func generateThumbnails() {
        guard let asset else { return }
        let count = Self.thumbnailCount
        let duration = self.duration
        thumbnails = Array(repeating: nil, count: count)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // Nearest keyframe is plenty for a strip this small, and far faster.
        let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        thumbnailGenerator = generator

        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: (Double($0) + 0.5) * duration / Double(count), preferredTimescale: 600))
        }
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, cgImage, _, _, _ in
            guard let cgImage else { return }
            let image = UIImage(cgImage: cgImage)
            let index = Int(requested.seconds / duration * Double(count))
            Task { @MainActor in
                guard let self, self.thumbnailGenerator === generator,
                      self.thumbnails.indices.contains(index) else { return }
                self.thumbnails[index] = image
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0, tolerance: 0) }
            player.defaultRate = rate
            player.play()
        }
    }

    // MARK: Scrubbing

    func beginScrub() {
        scrubbing = true
        player.pause()
    }

    /// `tolerance` is how far, in seconds, the frame shown may be from the
    /// finger. Zero lands on the exact frame; a few seconds lets the player
    /// show the nearest keyframe instead, which is what makes sweeping across
    /// an hour feel instant. Lifting the finger always lands exactly.
    func scrub(to seconds: Double, tolerance: Double) {
        seek(to: seconds, tolerance: tolerance)
    }

    func endScrub() {
        scrubbing = false
        seek(to: currentTime, tolerance: 0)
        savePosition()
    }

    private func seek(to seconds: Double, tolerance: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        chaseTarget = CMTime(seconds: t, preferredTimescale: 60000)
        chaseTolerance = CMTime(seconds: tolerance, preferredTimescale: 600)
        chaseGeneration += 1
        if !seekInFlight { performChaseSeek() }
    }

    private func performChaseSeek() {
        seekInFlight = true
        let generation = chaseGeneration
        player.seek(to: chaseTarget, toleranceBefore: chaseTolerance, toleranceAfter: chaseTolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if generation == self.chaseGeneration {
                    self.seekInFlight = false
                } else {
                    self.performChaseSeek()
                }
            }
        }
    }

    // MARK: Waves

    func markWave() {
        guard hasVideo else { return }
        let next = (waves.compactMap { Int($0.name.dropFirst("Wave ".count)) }.max() ?? 0) + 1
        waves.append(Wave(name: "Wave \(next)", time: currentTime))
        waves.sort { $0.time < $1.time }
        saveWaves()
    }

    func renameWave(_ id: Wave.ID, to name: String) {
        guard let i = waves.firstIndex(where: { $0.id == id }) else { return }
        waves[i].name = name
        saveWaves()
    }

    func deleteWaves(at offsets: IndexSet) {
        waves.remove(atOffsets: offsets)
        saveWaves()
    }

    func jump(to wave: Wave) {
        player.pause()
        seek(to: wave.time, tolerance: 0)
        savePosition()
    }

    private func saveWaves() {
        guard let videoKey, let data = try? JSONEncoder().encode(waves) else { return }
        UserDefaults.standard.set(data, forKey: "waves." + videoKey)
    }

    private static func loadWaves(key: String) -> [Wave] {
        guard let data = UserDefaults.standard.data(forKey: "waves." + key),
              let waves = try? JSONDecoder().decode([Wave].self, from: data) else { return [] }
        return waves
    }

    private func savePosition() {
        lastSavedAt = Date()
        UserDefaults.standard.set(currentTime, forKey: Keys.time)
    }

    private enum Keys {
        static let source = "lastSource"
        static let photoID = "lastPhotoID"
        static let fileBookmark = "lastFileBookmark"
        static let time = "lastTime"
    }
}
