import AVFoundation
import Combine
import Photos
import UIKit

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
    @Published var errorMessage: String?
    @Published var rate: Float = 1 {
        didSet { player.defaultRate = rate; if isPlaying { player.rate = rate } }
    }

    private var asset: AVAsset?
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
    private var chasePrecise = true
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
                await self.load(avAsset, title: title, resumeAt: resumeAt)
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
        Task { await load(AVURLAsset(url: url), title: url.deletingPathExtension().lastPathComponent, resumeAt: resumeAt) }
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

    private func load(_ asset: AVAsset, title: String, resumeAt: Double?) async {
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
        } catch {
            loadingMessage = nil
            errorMessage = "Couldn't read that video."
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        currentTime = 0
        hasVideo = true
        loadingMessage = nil
        if let resumeAt, resumeAt > 0, resumeAt < duration { seek(to: resumeAt, precise: true) }
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
            if currentTime >= duration - 0.05 { seek(to: 0, precise: true) }
            player.defaultRate = rate
            player.play()
        }
    }

    // MARK: Scrubbing

    func beginScrub() {
        scrubbing = true
        player.pause()
    }

    /// `precise` lands on the exact frame; otherwise the nearest keyframe,
    /// which is what makes sweeping across an hour feel instant.
    func scrub(to seconds: Double, precise: Bool) {
        seek(to: seconds, precise: precise)
    }

    func endScrub() {
        scrubbing = false
        seek(to: currentTime, precise: true)
        savePosition()
    }

    private func seek(to seconds: Double, precise: Bool) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        chaseTarget = CMTime(seconds: t, preferredTimescale: 60000)
        chasePrecise = precise
        chaseGeneration += 1
        if !seekInFlight { performChaseSeek() }
    }

    private func performChaseSeek() {
        seekInFlight = true
        let generation = chaseGeneration
        let tolerance = chasePrecise ? CMTime.zero : CMTime(seconds: 2, preferredTimescale: 600)
        player.seek(to: chaseTarget, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
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
