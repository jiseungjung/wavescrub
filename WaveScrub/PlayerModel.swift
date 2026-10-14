import AVFoundation
import Combine
import ImageIO
import Photos
import SwiftUI
import UIKit

/// A marked wave: where it starts, what you called it, and its color.
struct Wave: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var time: Double
    var color: WaveColor = .cyan

    enum CodingKeys: String, CodingKey { case id, name, time, color }

    init(id: UUID = UUID(), name: String, time: Double, color: WaveColor = .cyan) {
        self.id = id
        self.name = name
        self.time = time
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        time = try c.decode(Double.self, forKey: .time)
        color = try c.decodeIfPresent(WaveColor.self, forKey: .color) ?? .cyan
    }
}

/// A small, fixed set of flag colors — no color wheel.
enum WaveColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, cyan, blue, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }

    var name: String { rawValue.capitalized }
}

/// A previously opened video, kept so it can be reopened without copying it.
struct RecentVideo: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case photo, file }

    var id = UUID()
    var title: String
    var lastOpened: Date
    var kind: Kind
    var photoID: String?
    var filePath: String?
    var fileBookmark: Data?
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
    /// How the camera stored the frames relative to how they're watched.
    @Published private(set) var videoOrientation: CGImagePropertyOrientation = .up
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [UIImage?] = []
    @Published private(set) var loadingMessage: String?
    @Published private(set) var waves: [Wave] = []
    @Published var selectedWaveID: Wave.ID?
    @Published private(set) var recents: [RecentVideo] = []
    @Published var errorMessage: String?
    /// Where you are through each wave, keyed by the wave, once worked out.
    @Published private(set) var tracks: [Wave.ID: WaveTrack] = [:]
    /// The wave being worked out right now.
    @Published private(set) var trackingWaveID: Wave.ID?
    /// Waves where nobody could be found at the bookmark; they wait for a tap.
    @Published private(set) var unfoundWaveIDs: Set<Wave.ID> = []
    /// The wave on the loop screen, worked out before the rest.
    var priorityWaveID: Wave.ID? {
        didSet {
            // Drop whichever wave is half done for this one; it starts again later.
            if let id = priorityWaveID, trackingWaveID != nil, trackingWaveID != id,
               tracks[id] == nil, !unfoundWaveIDs.contains(id) {
                stopTracking()
            }
            trackPending()
        }
    }
    @Published var rate: Float = 1 {
        didSet { player.defaultRate = rate; if isPlaying { player.rate = rate } }
    }

    private(set) var asset: AVAsset?
    /// Which video the waves belong to: the Photos id or the file's path.
    private var videoKey: String?
    private var securityScopedURL: URL?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var lastSavedAt = Date.distantPast
    private var trackingTask: Task<Void, Never>?
    /// Which run of the tracker is current, so a cancelled one can't land.
    private var trackingRun = UUID()

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
        loadRecents()
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
        addRecent(title: title, kind: .photo, photoID: id, filePath: nil, fileBookmark: nil)
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
            addRecent(title: url.deletingPathExtension().lastPathComponent, kind: .file,
                      photoID: nil, filePath: url.path, fileBookmark: bookmark)
        }
        loadingMessage = "Opening…"
        Task {
            await load(AVURLAsset(url: url), title: url.deletingPathExtension().lastPathComponent,
                       key: "file:" + url.path, resumeAt: resumeAt)
        }
    }

    /// Reopens a previously opened video in place; nothing was ever copied.
    func openRecent(_ recent: RecentVideo) {
        switch recent.kind {
        case .photo:
            guard let id = recent.photoID else { return }
            openPhotoAsset(id: id)
        case .file:
            guard let data = recent.fileBookmark else { return }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
                errorMessage = "That file can't be found anymore."
                removeRecent(recent.id)
                return
            }
            openFile(url)
        }
    }

    func removeRecent(_ id: RecentVideo.ID) {
        recents.removeAll { $0.id == id }
        saveRecents()
    }

    private func addRecent(title: String, kind: RecentVideo.Kind, photoID: String?, filePath: String?, fileBookmark: Data?) {
        recents.removeAll {
            $0.kind == kind && (kind == .photo ? $0.photoID == photoID : $0.filePath == filePath)
        }
        recents.insert(RecentVideo(title: title, lastOpened: Date(), kind: kind,
                                    photoID: photoID, filePath: filePath, fileBookmark: fileBookmark), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        saveRecents()
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: Keys.recents)
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Keys.recents),
              let list = try? JSONDecoder().decode([RecentVideo].self, from: data) else { return }
        recents = list
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
        stopTracking()
        player.pause()
        do {
            let duration = try await asset.load(.duration).seconds
            var fps = 30.0
            var size = CGSize.zero
            var orientation = CGImagePropertyOrientation.up
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (rate, natural, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
                if rate > 0 { fps = Double(rate) }
                let r = CGRect(origin: .zero, size: natural).applying(transform)
                size = CGSize(width: abs(r.width), height: abs(r.height))
                switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
                case (0, 1, -1, 0): orientation = .right
                case (0, -1, 1, 0): orientation = .left
                case (-1, 0, 0, -1): orientation = .down
                default: orientation = .up
                }
            }
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            self.asset = asset
            self.title = title
            self.duration = duration
            self.frameRate = fps
            self.videoSize = size
            self.videoOrientation = orientation
            self.videoKey = key
            self.waves = Self.loadWaves(key: key)
            self.tracks = Self.loadTracks(key: key)
            self.unfoundWaveIDs = []
            self.selectedWaveID = nil
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
        trackPending()
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
    ///
    /// The wave you're on follows the finger: its name shows while you're on
    /// it and clears as soon as you move off.
    func scrub(to seconds: Double, tolerance: Double) {
        seek(to: seconds, tolerance: tolerance)
        let frame = 1 / frameRate
        selectedWaveID = waves.first { abs($0.time - currentTime) < frame }?.id
    }

    func endScrub() {
        scrubbing = false
        seek(to: currentTime, tolerance: 0)
        savePosition()
        let frame = 1 / frameRate
        selectedWaveID = waves.first { abs($0.time - currentTime) < frame }?.id
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
        let wave = Wave(name: "Wave \(next)", time: currentTime, color: lastWaveColor)
        waves.append(wave)
        waves.sort { $0.time < $1.time }
        saveWaves()
        selectedWaveID = wave.id
        trackPending()
    }

    func renameWave(_ id: Wave.ID, to name: String) {
        guard let i = waves.firstIndex(where: { $0.id == id }) else { return }
        waves[i].name = name
        saveWaves()
    }

    func setColor(_ id: Wave.ID, to color: WaveColor) {
        guard let i = waves.firstIndex(where: { $0.id == id }) else { return }
        waves[i].color = color
        saveWaves()
        lastWaveColor = color
    }

    func deleteWave(_ id: Wave.ID) {
        waves.removeAll { $0.id == id }
        saveWaves()
        forgetTracks()
        if selectedWaveID == id { selectedWaveID = nil }
    }

    func deleteWaves(at offsets: IndexSet) {
        waves.remove(atOffsets: offsets)
        saveWaves()
        forgetTracks()
    }

    /// Which color a newly marked wave gets: whatever was last picked.
    private var lastWaveColor: WaveColor {
        get { WaveColor(rawValue: UserDefaults.standard.string(forKey: Keys.lastWaveColor) ?? "") ?? .cyan }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.lastWaveColor) }
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

    // MARK: Following you through each wave

    /// Works out the next wave not yet followed, one at a time, in the
    /// background — the one on the loop screen first.
    func trackPending() {
        guard trackingTask == nil, let asset, let videoKey else { return }
        let waiting = waves.filter { tracks[$0.id] == nil && !unfoundWaveIDs.contains($0.id) }
        guard let wave = waiting.first(where: { $0.id == priorityWaveID }) ?? waiting.first else { return }
        startTracking(wave, tap: nil, asset: asset, key: videoKey)
    }

    /// You tapped yourself, on the bookmark's frame or one a little after it:
    /// follow whoever is there instead. `point` is a fraction of the picture,
    /// from its top-left.
    func retrack(_ id: Wave.ID, tappedAt point: CGPoint, time: Double) {
        guard let asset, let videoKey, let wave = waves.first(where: { $0.id == id }) else { return }
        stopTracking()
        tracks[id] = nil
        unfoundWaveIDs.remove(id)
        saveTracks()
        startTracking(wave, tap: (point, time), asset: asset, key: videoKey)
    }

    private func startTracking(_ wave: Wave, tap: (point: CGPoint, time: Double)?, asset: AVAsset, key: String) {
        let run = UUID()
        trackingRun = run
        trackingWaveID = wave.id
        trackingTask = Task.detached(priority: .utility) { [weak self] in
            let track = try? await WaveTracker.track(asset: asset, from: wave.time, tap: tap)
            await self?.finishTracking(wave.id, run: run, track: track)
        }
    }

    private func finishTracking(_ id: Wave.ID, run: UUID, track: WaveTrack?) {
        guard run == trackingRun else { return }
        trackingTask = nil
        trackingWaveID = nil
        if waves.contains(where: { $0.id == id }) {
            if let track {
                tracks[id] = track
                saveTracks()
            } else {
                unfoundWaveIDs.insert(id)
            }
        }
        trackPending()
    }

    private func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        trackingWaveID = nil
        trackingRun = UUID()
    }

    /// Drops the paths of deleted waves, and stops following one mid-way.
    private func forgetTracks() {
        let ids = Set(waves.map(\.id))
        if let id = trackingWaveID, !ids.contains(id) {
            stopTracking()
            trackPending()
        }
        tracks = tracks.filter { ids.contains($0.key) }
        unfoundWaveIDs.formIntersection(ids)
        saveTracks()
    }

    /// Paths live in a file per video rather than with the waves: a few
    /// hundred positions each would bloat the settings store. The folder's
    /// number goes up whenever the tracker changes, so old paths are redone.
    private static func tracksURL(key: String) -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent("WaveTracks2", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "video"
        return folder.appendingPathComponent(name + ".json")
    }

    private func saveTracks() {
        guard let videoKey, let url = Self.tracksURL(key: videoKey) else { return }
        let byName = Dictionary(uniqueKeysWithValues: tracks.map { ($0.key.uuidString, $0.value) })
        try? JSONEncoder().encode(byName).write(to: url, options: .atomic)
    }

    private static func loadTracks(key: String) -> [Wave.ID: WaveTrack] {
        guard let url = tracksURL(key: key), let data = try? Data(contentsOf: url),
              let byName = try? JSONDecoder().decode([String: WaveTrack].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: byName.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
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
        static let recents = "recentVideos"
        static let lastWaveColor = "lastWaveColor"
    }
}
