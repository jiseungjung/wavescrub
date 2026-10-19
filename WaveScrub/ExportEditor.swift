import AVFoundation
import SwiftUI
import UIKit

/// One chosen wave in the export editor: how far its loop goes, and the part
/// of it that goes in the export.
struct EditClip: Identifiable, Equatable {
    let id: Wave.ID
    let title: String
    let color: Color
    let loop: ClosedRange<Double>
    let track: WaveTrack
    var start: Double
    var end: Double
}

/// Putting the chosen waves together before exporting, like InShot or Edits:
/// the finished video plays at the top, exactly as it will be exported, and
/// every wave lies along a timeline under it. Slide the timeline to move
/// through the whole video, pinch it to see more or less. Tap a wave to
/// trim it with the handles at its ends, only as far as its loop goes;
/// while a handle moves the video shows that frame.
struct ExportEditor: View {
    let asset: AVAsset
    let orientation: CGImagePropertyOrientation
    let shown: (w: CGFloat, h: CGFloat)
    @Binding var rate: Float
    let title: String
    /// The waves as they were left, and whether the video was exported.
    var onClose: ([EditClip], Bool) -> Void

    @State private var clips: [EditClip]
    @StateObject private var preview = EditorPlayer()
    @Environment(\.dismiss) private var dismiss
    @State private var selected: EditClip.ID?
    /// Points per second of the finished video, along the timeline.
    @State private var pps: CGFloat = 40
    @State private var pinchBase: CGFloat?
    /// Where the timeline was when a finger started sliding it.
    @State private var scrubFrom: Double?
    @State private var trim: TrimDrag?
    /// A wave held and being dragged to a new place in the order.
    @State private var moving: MoveDrag?
    /// Waits for a finger held still on a wave, to pick it up.
    @State private var pressTask: Task<Void, Never>?
    @State private var pressAt: CGPoint = .zero
    @State private var thumbs: [EditClip.ID: [(time: Double, image: UIImage)]] = [:]
    @State private var buildRun = 0
    @State private var exportJob: Task<Void, Never>?
    @State private var exportProgress: Double?
    @State private var exportError: String?
    @State private var finished: SharedFile?
    @State private var shared: SharedFile?

    private static let clipHeight: CGFloat = 60
    private static let tileWidth: CGFloat = 40
    private static let handleWidth: CGFloat = 16
    private static let shortest = 0.5
    /// The finished video is shown at this width while editing: plenty for a
    /// phone screen, and light enough to play smoothly.
    private static let previewWidth: CGFloat = 720

    private enum Edge { case start, end }

    /// Holding a wave turns the timeline into one tile per wave, to drag
    /// it to a new place, as in InShot or CapCut.
    private struct MoveDrag {
        let id: EditClip.ID
        /// Where the finger is.
        var x: CGFloat
        /// How far the row of tiles is moved over so the held wave's own
        /// tile starts under the finger.
        let shift: CGFloat
    }

    /// A handle being held. The timeline stays as it was when it was taken
    /// hold of, so the handle stays under the finger; the waves close up
    /// when it's let go.
    private struct TrimDrag {
        let id: EditClip.ID
        let edge: Edge
        let start: Double
        let end: Double
        let lefts: [EditClip.ID: Double]
        let time: Double
    }

    init(asset: AVAsset, orientation: CGImagePropertyOrientation, clips: [EditClip],
         shown: (w: CGFloat, h: CGFloat), rate: Binding<Float>, title: String,
         onClose: @escaping ([EditClip], Bool) -> Void) {
        self.asset = asset
        self.orientation = orientation
        self.shown = shown
        _rate = rate
        self.title = title
        self.onClose = onClose
        _clips = State(initialValue: clips)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                previewArea
                playRow
                timeline
                    .padding(.top, 6)
                clipBar
                    .frame(height: 52)
                    .padding(.bottom, 4)
            }
            if exportProgress != nil || finished != nil {
                Color.black.opacity(0.5).ignoresSafeArea()
                if let exportProgress { exportingCard(exportProgress) }
                else if let finished { finishedCard(finished) }
            }
        }
        .statusBarHidden()
        .onAppear { rebuild(at: 0, play: true) }
        .onDisappear {
            exportJob?.cancel()
            preview.stop()
        }
        .task { await makeThumbs() }
        .onChange(of: rate) { old, new in
            rebuild(at: preview.time * Double(old / max(0.05, new)))
        }
        .sheet(item: $shared) { file in
            // Already in Photos: the share sheet doesn't offer to save it again.
            ShareSheet(items: [file.url], excluded: file.saved ? [.saveToCameraRoll] : [])
                .presentationDetents([.medium, .large])
        }
        .alert("Couldn't export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(clips.count == 1 ? "1 wave" : "\(clips.count) waves")
                    .font(.headline)
                Text(clock(totalLength))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 16) {
                Button { close(exported: false) } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                }
                Spacer()
                Button {
                    rate = rate == 1 ? 0.5 : rate == 0.5 ? 0.25 : 1
                } label: {
                    Text(rate == 1 ? "1×" : rate == 0.5 ? "½×" : "¼×")
                        .font(.system(.callout, design: .monospaced))
                }
                Button(action: startExport) {
                    Text("Export")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The finished video, framed as it will be.
    private var previewArea: some View {
        EditorPictureView(player: preview.player)
            .aspectRatio(preview.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { preview.toggle() }
    }

    private var playRow: some View {
        HStack {
            Text(clock(preview.time))
                .foregroundStyle(.white)
            Text("/ " + clock(totalLength))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button { preview.toggle() } label: {
                Image(systemName: preview.playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 36)
            }
            .foregroundStyle(.white)
            Spacer()
            // Balances the time on the left so play sits in the middle.
            Text(clock(totalLength) + " / " + clock(totalLength)).hidden()
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// The selected wave's length and what can be done to it, or a hint.
    private var clipBar: some View {
        HStack(spacing: 12) {
            if let c = clips.first(where: { $0.id == selected }) {
                Circle().fill(c.color).frame(width: 10, height: 10)
                Text(c.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(String(format: "%.1fs", (c.end - c.start) / Double(rate)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    resetSelected()
                } label: {
                    Label("Whole loop", systemImage: "arrow.counterclockwise")
                }
                .disabled(c.start == c.loop.lowerBound && c.end == c.loop.upperBound)
                Button(role: .destructive) {
                    removeSelected()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Spacer()
                Text(moving == nil ? "Tap to trim · hold and drag to reorder" : "Drag to a new place")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
        }
        .font(.callout)
        .labelStyle(.iconOnly)
        .imageScale(.large)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
    }

    // MARK: Timeline

    /// Where each wave sits along the finished video, in its seconds.
    private var layout: [(clip: EditClip, left: Double, right: Double)] {
        let speed = Double(max(0.05, rate))
        var cursor = 0.0
        return clips.map { c in
            let length = (c.end - c.start) / speed
            if let trim, let frozen = trim.lefts[c.id] {
                if c.id == trim.id {
                    let left = frozen + (c.start - trim.start) / speed
                    return (c, left, left + length)
                }
                return (c, frozen, frozen + length)
            }
            defer { cursor += length }
            return (c, cursor, cursor + length)
        }
    }

    private var totalLength: Double {
        clips.reduce(0) { $0 + ($1.end - $1.start) } / Double(max(0.05, rate))
    }

    private var timeline: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let now = trim?.time ?? preview.time
            let origin = width / 2 - CGFloat(now) * pps
            let items = layout
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                if let moving {
                    reorderRow(moving, width: width)
                } else {
                ForEach(items, id: \.clip.id) { item in
                    let x = origin + CGFloat(item.left) * pps
                    let w = max(2, CGFloat(item.right - item.left) * pps)
                    clipView(item.clip, width: w, x: x, screen: width)
                        .frame(width: w, height: Self.clipHeight)
                        .offset(x: x, y: 10)
                        .onTapGesture { selected = selected == item.clip.id ? nil : item.clip.id }
                }
                if let item = items.first(where: { $0.clip.id == selected }) {
                    let x0 = origin + CGFloat(item.left) * pps
                    let x1 = origin + CGFloat(item.right) * pps
                    Rectangle().strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: max(0, x1 - x0), height: Self.clipHeight)
                        .offset(x: x0, y: 10)
                        .allowsHitTesting(false)
                    handle(.start, clip: item.clip).offset(x: x0 - Self.handleWidth, y: 10)
                    handle(.end, clip: item.clip).offset(x: x1, y: 10)
                }
                // Where the video is: the frame showing above.
                Rectangle().fill(.white)
                    .frame(width: 2, height: Self.clipHeight + 16)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: width / 2 - 1, y: 2)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(scrub)
            .simultaneousGesture(pinch)
            .simultaneousGesture(reorder(origin: origin, width: width))
            .animation(.easeOut(duration: 0.18), value: moving?.id)
        }
        .frame(height: Self.clipHeight + 20)
    }

    /// The wave's frames, cut as they'll be exported, one every tile's width.
    /// Tiles stay with their moment in the video, so trimming uncovers or
    /// covers them rather than moving them.
    private func clipView(_ c: EditClip, width: CGFloat, x: CGFloat, screen: CGFloat) -> some View {
        let speed = Double(max(0.05, rate))
        let step = Double(Self.tileWidth / pps) * speed
        let first = max(0, Int(floor((c.start - c.loop.lowerBound) / step)))
        let last = max(first, Int(ceil((c.end - c.loop.lowerBound) / step)))
        let tiles = (first...last).filter { k in
            let tx = x + CGFloat((c.loop.lowerBound + Double(k) * step - c.start) / speed) * pps
            return tx + Self.tileWidth > 0 && tx < screen
        }
        return ZStack(alignment: .topLeading) {
            Color.white.opacity(0.08)
            ForEach(tiles, id: \.self) { k in
                let t = c.loop.lowerBound + Double(k) * step
                Group {
                    if let image = nearest(c.id, t + step / 2) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: Self.tileWidth, height: Self.clipHeight)
                .clipped()
                .offset(x: CGFloat((t - c.start) / speed) * pps)
            }
            Text(c.title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(c.color.opacity(0.85), in: Capsule())
                .padding(4)
        }
        .frame(width: width, height: Self.clipHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            // A thin gap between waves.
            Rectangle().fill(.black).frame(width: 1.5)
        }
    }

    private func handle(_ edge: Edge, clip: EditClip) -> some View {
        UnevenRoundedRectangle(cornerRadii: edge == .start
                               ? .init(topLeading: 6, bottomLeading: 6)
                               : .init(bottomTrailing: 6, topTrailing: 6))
            .fill(Color.yellow)
            .overlay {
                Image(systemName: edge == .start ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(width: Self.handleWidth, height: Self.clipHeight)
            // Easier to catch than it is to see.
            .contentShape(Rectangle().inset(by: -12))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in moveHandle(edge, of: clip.id, by: value.translation.width) }
                    .onEnded { _ in letGo() }
            )
    }

    /// Sliding the timeline moves through the whole video.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard trim == nil, pinchBase == nil, moving == nil else { return }
                if scrubFrom == nil {
                    scrubFrom = preview.time
                    preview.pause()
                }
                let t = (scrubFrom ?? 0) - Double(value.translation.width / pps)
                preview.seek(min(max(0, t), max(0, totalLength - 0.01)))
            }
            .onEnded { _ in scrubFrom = nil }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchBase == nil { pinchBase = pps }
                pps = min(max(8, (pinchBase ?? pps) * scale), 300)
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: Reordering

    /// How wide each wave's tile is while reordering: all of them fit.
    private func tileSize(_ width: CGFloat) -> CGFloat {
        min(56, max(26, (width - 32) / CGFloat(max(1, clips.count)) - 6))
    }

    private func rowLeft(_ width: CGFloat) -> CGFloat {
        let tile = tileSize(width)
        return (width - CGFloat(clips.count) * (tile + 6) + 6) / 2
    }

    /// Where the held wave would land, from where the finger is.
    private func target(_ moving: MoveDrag, width: CGFloat) -> Int {
        let tile = tileSize(width)
        let i = Int(((moving.x - rowLeft(width) - moving.shift - tile / 2) / (tile + 6)).rounded())
        return min(max(0, i), clips.count - 1)
    }

    private func reorderRow(_ moving: MoveDrag, width: CGFloat) -> some View {
        let tile = tileSize(width)
        let left = rowLeft(width) + moving.shift
        let landing = target(moving, width: width)
        let others = clips.filter { $0.id != moving.id }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(others.enumerated()), id: \.element.id) { i, c in
                let slot = i >= landing ? i + 1 : i
                tileView(c, size: tile)
                    .offset(x: left + CGFloat(slot) * (tile + 6), y: 10 + (Self.clipHeight - tile) / 2)
            }
            if let c = clips.first(where: { $0.id == moving.id }) {
                tileView(c, size: tile)
                    .scaleEffect(1.15)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow, lineWidth: 2).scaleEffect(1.15))
                    .offset(x: moving.x - tile / 2, y: 10 + (Self.clipHeight - tile) / 2)
                    .animation(nil, value: moving.x)
            }
        }
        .allowsHitTesting(false)
    }

    /// A wave as one square: its middle frame and its name.
    private func tileView(_ c: EditClip, size: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let image = nearest(c.id, (c.start + c.end) / 2) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: size, height: size)
            .clipped()
            Text(c.title)
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity)
                .background(c.color.opacity(0.85))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Hold a wave still for a moment and it lifts, ready to drag along to
    /// its new place. Moving first slides the timeline instead.
    private func reorder(origin: CGFloat, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                pressAt = value.location
                if moving != nil {
                    moving?.x = value.location.x
                    return
                }
                if pressTask == nil {
                    let down = value.startLocation
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        pickUp(at: down, origin: origin, width: width)
                    }
                }
                if hypot(value.translation.width, value.translation.height) > 8 { pressTask?.cancel() }
            }
            .onEnded { _ in
                pressTask?.cancel()
                pressTask = nil
                if moving != nil { drop(width: width) }
            }
    }

    /// Lifts the wave under the finger, with its tile right there.
    private func pickUp(at point: CGPoint, origin: CGFloat, width: CGFloat) {
        guard moving == nil, trim == nil, scrubFrom == nil, pinchBase == nil, clips.count > 1 else { return }
        let t = Double((point.x - origin) / pps)
        guard point.y >= 10, point.y <= 10 + Self.clipHeight,
              let held = layout.first(where: { t >= $0.left && t < $0.right })?.clip,
              let i = clips.firstIndex(where: { $0.id == held.id }) else { return }
        preview.pause()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let tile = tileSize(width)
        let row = CGFloat(clips.count) * (tile + 6) - 6
        let left = rowLeft(width)
        // The held tile's slot under the finger, as far as the row stays on screen.
        let wanted = point.x - (left + CGFloat(i) * (tile + 6) + tile / 2)
        let shift = min(max(wanted, 8 - left), max(8 - left, width - 8 - row - left))
        withAnimation(.easeOut(duration: 0.18)) {
            moving = MoveDrag(id: held.id, x: pressAt.x, shift: shift)
        }
    }

    private func drop(width: CGFloat) {
        guard let moving, let from = clips.firstIndex(where: { $0.id == moving.id }) else {
            self.moving = nil
            return
        }
        let to = target(moving, width: width)
        let clip = clips.remove(at: from)
        clips.insert(clip, at: to)
        self.moving = nil
        selected = nil
        if from != to { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        rebuild(at: layout[to].left + 0.01)
    }

    // MARK: Trimming

    private func moveHandle(_ edge: Edge, of id: EditClip.ID, by dx: CGFloat) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if trim == nil {
            let lefts = Dictionary(uniqueKeysWithValues: layout.map { ($0.clip.id, $0.left) })
            trim = TrimDrag(id: id, edge: edge, start: clips[i].start, end: clips[i].end,
                            lefts: lefts, time: preview.time)
            preview.pause()
            showWhole(clips[i])
        }
        guard let trim else { return }
        let c = clips[i]
        let moved = Double(dx / pps) * Double(max(0.05, rate))
        if edge == .start {
            clips[i].start = min(max(c.loop.lowerBound, trim.start + moved), c.end - Self.shortest)
            preview.seekLoose(clips[i].start - c.loop.lowerBound, speed: rate)
        } else {
            clips[i].end = max(min(c.loop.upperBound, trim.end + moved), c.start + Self.shortest)
            preview.seekLoose(clips[i].end - c.loop.lowerBound, speed: rate)
        }
    }

    /// While a handle moves, the video shows that wave's whole loop, so any
    /// frame of it can be shown, not only the part already in.
    private func showWhole(_ c: EditClip) {
        buildRun += 1
        let run = buildRun
        preview.awaitWhole()
        let piece = ClipExport.Piece(start: c.loop.lowerBound, end: c.loop.upperBound, track: c.track)
        Task {
            guard let built = try? await ClipExport.build(asset: asset, orientation: orientation, pieces: [piece],
                                                          shown: shown, rate: rate, width: Self.previewWidth),
                  run == buildRun else { return }
            preview.load(built, at: preview.wantedLoose ?? 0, play: false)
        }
    }

    /// The waves close up, and the video stops at the moment just trimmed:
    /// a new start, or just before a new end.
    private func letGo() {
        guard let trim else { return }
        self.trim = nil
        guard let item = layout.first(where: { $0.clip.id == trim.id }) else { return }
        rebuild(at: trim.edge == .start ? item.left : max(item.left, item.right - 0.05))
    }

    private func resetSelected() {
        guard let i = clips.firstIndex(where: { $0.id == selected }) else { return }
        clips[i].start = clips[i].loop.lowerBound
        clips[i].end = clips[i].loop.upperBound
        rebuild(at: layout[i].left)
    }

    private func removeSelected() {
        guard let i = clips.firstIndex(where: { $0.id == selected }) else { return }
        clips.remove(at: i)
        selected = nil
        if clips.isEmpty {
            close(exported: false)
        } else {
            rebuild(at: min(preview.time, layout[min(i, clips.count - 1)].left))
        }
    }

    // MARK: Playing

    /// Puts the finished video together again and shows it from `time`.
    private func rebuild(at time: Double, play: Bool = false) {
        buildRun += 1
        let run = buildRun
        let pieces = clips.map { ClipExport.Piece(start: $0.start, end: $0.end, track: $0.track) }
        guard !pieces.isEmpty else { return }
        Task {
            guard let built = try? await ClipExport.build(asset: asset, orientation: orientation, pieces: pieces,
                                                          shown: shown, rate: rate, width: Self.previewWidth),
                  run == buildRun else { return }
            preview.load(built, at: min(max(0, time), max(0, built.duration - 0.01)), play: play)
        }
    }

    private func nearest(_ id: EditClip.ID, _ t: Double) -> UIImage? {
        thumbs[id]?.min { abs($0.time - t) < abs($1.time - t) }?.image
    }

    /// A small frame of each wave every half second, cut as it will be
    /// exported. Every wave gets a rough set first, then the rest.
    private func makeThumbs() async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let clips = clips
        for pass in [2.0, 0.5] {
            for c in clips {
                for t in stride(from: c.loop.lowerBound, through: c.loop.upperBound, by: pass) {
                    guard !Task.isCancelled else { return }
                    if thumbs[c.id]?.contains(where: { abs($0.time - t) < 0.2 }) == true { continue }
                    guard let made = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                    else { continue }
                    let image = made.image
                    let r = FollowView(track: c.track, shownW: shown.w, shownH: shown.h).rect(at: t)
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    let crop = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
                        .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
                    let piece = crop.isEmpty ? image : (image.cropping(to: crop) ?? image)
                    thumbs[c.id, default: []].append((t, UIImage(cgImage: piece)))
                }
            }
        }
    }

    // MARK: Exporting

    private func startExport() {
        guard !clips.isEmpty, exportProgress == nil else { return }
        preview.pause()
        selected = nil
        let pieces = clips.map { ClipExport.Piece(start: $0.start, end: $0.end, track: $0.track) }
        let name = clips.count == 1 ? "\(title) \(clips[0].title)" : "\(title) \(clips.count) waves"
        exportProgress = 0
        exportJob = Task {
            defer {
                exportProgress = nil
                exportJob = nil
            }
            do {
                let url = try await ClipExport.export(asset: asset, orientation: orientation, pieces: pieces,
                                                      shown: shown, rate: rate, name: name) { exportProgress = $0 }
                let saved = (try? await ClipExport.saveToPhotos(url)) != nil
                finished = SharedFile(url: url, saved: saved)
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func close(exported: Bool) {
        exportJob?.cancel()
        preview.stop()
        onClose(clips, exported)
        dismiss()
    }

    private func exportingCard(_ progress: Double) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .tint(.yellow)
                .frame(width: 180)
            Text("Exporting… \(Int((progress * 100).rounded()))%")
                .font(.callout)
                .monospacedDigit()
            Button("Cancel") { exportJob?.cancel() }
                .font(.callout)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Done exporting: it's in Photos already, so the only thing left to
    /// offer is sharing it somewhere else.
    private func finishedCard(_ file: SharedFile) -> some View {
        VStack(spacing: 10) {
            Image(systemName: file.saved ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(file.saved ? .green : .yellow)
            Text(file.saved ? "Saved to Photos" : "Couldn't save to Photos")
                .font(.headline)
            Text(file.saved ? "In the WaveScrub album" : "Let WaveScrub add to Photos in Settings, or share it from here.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Done") { close(exported: true) }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button { shared = file } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
            }
            .padding(.top, 6)
            Button("Keep editing") { finished = nil }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 280)
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Plays the finished video while it's being edited.
@MainActor
final class EditorPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var time: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    /// The picture's width over its height.
    @Published private(set) var aspect: CGFloat = 9 / 16
    /// Where a handle being moved wants the video, in its wave's own seconds,
    /// for when that wave's whole loop is ready to show.
    private(set) var wantedLoose: Double?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var wanted: CMTime?
    private var seeking = false

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.wanted == nil, self.player.rate != 0 else { return }
                self.time = t.seconds
            }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playing = playing }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.time = self.duration
            }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ built: ClipExport.Built, at time: Double, play: Bool) {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let size = built.videoComposition.renderSize
        if size.height > 0 { aspect = size.width / size.height }
        player.replaceCurrentItem(with: item)
        duration = built.duration
        wantedLoose = nil
        seek(time)
        if play { player.play() }
    }

    /// Goes to an exact frame. While a seek is under way only the latest
    /// wanted frame is kept, so sliding quickly never queues up a backlog.
    func seek(_ t: Double) {
        time = t
        wanted = CMTime(seconds: t, preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    /// While a handle moves: a moment of that wave's whole loop, `offset`
    /// seconds into it.
    func seekLoose(_ offset: Double, speed: Float) {
        wantedLoose = offset / Double(max(0.05, speed))
        guard let wantedLoose, duration > 0 else { return }
        wanted = CMTime(seconds: min(wantedLoose, duration - 0.01), preferredTimescale: 60000)
        if !seeking { seekToWanted() }
    }

    /// Until the wave's whole loop is ready, handle moves wait for it rather
    /// than seeking the video as it was.
    func awaitWhole() {
        duration = 0
    }

    private func seekToWanted() {
        guard let target = wanted, player.currentItem != nil else { return }
        wanted = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if self.wanted != nil { self.seekToWanted() }
            }
        }
    }

    func toggle() {
        if playing {
            pause()
        } else {
            if time >= duration - 0.05 { seek(0) }
            player.play()
        }
    }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Shows a player's picture.
struct EditorPictureView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {}

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
