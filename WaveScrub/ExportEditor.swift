import AVFoundation
import SwiftUI
import UIKit

/// One chosen wave in the export editor: the part of it that goes in the
/// export, and how close it's zoomed.
struct EditClip: Identifiable, Equatable {
    let id: Wave.ID
    let title: String
    let color: Color
    /// The part of the video got ready for this wave: its loop, and any part
    /// it's been stretched into since.
    var loop: ClosedRange<Double>
    var track: WaveTrack
    var start: Double
    var end: Double
    /// How much closer than the video's zoom: 2 shows half as much.
    var zoom: CGFloat = 1
}

/// Putting the chosen waves together before exporting, like InShot or Edits:
/// the finished video plays at the top, exactly as it will be exported, and
/// every wave lies along a timeline under it. Slide the timeline to move
/// through the whole video, pinch it to see more or less. Tap a wave to
/// trim it with the handles at its ends, past its loop if wanted (the surfer
/// is then followed into the new part); while a handle moves the video shows
/// that frame. Pinch the video to zoom the wave under the playhead.
struct ExportEditor: View {
    let asset: AVAsset
    let orientation: CGImagePropertyOrientation
    let shown: (w: CGFloat, h: CGFloat)
    @Binding var rate: Float
    let title: String
    /// How long the whole video is.
    let duration: Double
    /// Follows the surfer through more of a wave, for a part it's been
    /// stretched into; the path that came of it.
    var follow: (Wave.ID, ClosedRange<Double>) async -> WaveTrack?
    /// The waves as they were left, and whether the video was exported.
    var onClose: ([EditClip], Bool) -> Void

    @State private var clips: [EditClip]
    @StateObject private var preview = EditorPlayer()
    /// Small copies of every frame, for sliding without waiting.
    @State private var frames = EditorFrames()
    @Environment(\.dismiss) private var dismiss
    @State private var selected: EditClip.ID?
    /// Points per second of the finished video, along the timeline.
    @State private var pps: CGFloat = 40
    @State private var pinchBase: CGFloat?
    /// Where the timeline was when a finger started sliding it.
    @State private var scrubFrom: Double?
    @State private var trim: TrimDrag?
    /// Each change made in the editor, to undo, and those undone, to redo.
    @State private var undos: [Snapshot] = []
    @State private var redos: [Snapshot] = []
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
    /// Waves whose surfer is being followed into a part stretched into.
    @State private var following: Set<EditClip.ID> = []
    /// Two fingers zooming the video, for the wave under the playhead.
    @State private var zoomPinch: ZoomPinch?

    private static let clipHeight: CGFloat = 60
    private static let tileWidth: CGFloat = 40
    private static let handleWidth: CGFloat = 16
    private static let shortest = 0.5
    /// The finished video is shown at this width while editing: plenty for a
    /// phone screen, and light enough to play smoothly.
    private static let previewWidth: CGFloat = 720

    private enum Edge { case start, end }

    private struct ZoomPinch {
        let id: EditClip.ID
        let base: CGFloat
        var scale: CGFloat
    }

    /// How far past what's ready a handle can go in one go.
    private static let reach = 15.0
    /// The closest a wave can be zoomed, past the video's zoom.
    private static let mostZoom: CGFloat = 6

    /// Holding a wave turns the timeline into one tile per wave, to drag
    /// it to a new place, as in InShot or CapCut.
    private struct MoveDrag {
        let id: EditClip.ID
        /// Where the finger is.
        var x: CGFloat
        /// How far the row of tiles is moved over so the held wave's own
        /// tile starts under the finger.
        var shift: CGFloat
    }

    /// A handle being held. The timeline stays as it was when it was taken
    /// hold of, so the handle stays under the finger; the waves close up
    /// when it's let go.
    /// The waves and the speed, as they were before a change.
    private struct Snapshot {
        let clips: [EditClip]
        let rate: Float
    }

    private struct TrimDrag {
        let before: Snapshot
        let id: EditClip.ID
        let edge: Edge
        let start: Double
        let end: Double
        let time: Double
    }

    init(asset: AVAsset, orientation: CGImagePropertyOrientation, clips: [EditClip],
         shown: (w: CGFloat, h: CGFloat), rate: Binding<Float>, title: String, duration: Double,
         follow: @escaping (Wave.ID, ClosedRange<Double>) async -> WaveTrack?,
         onClose: @escaping ([EditClip], Bool) -> Void) {
        self.asset = asset
        self.orientation = orientation
        self.shown = shown
        _rate = rate
        self.title = title
        self.duration = duration
        self.follow = follow
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
        .onAppear {
            rebuild(at: 0, play: true)
            // The wave the video starts on first, then the rest in order.
            preview.configure(shown: shown, orientation: orientation)
            frames.setUp(asset: asset, orientation: orientation)
            for c in clips {
                frames.want(c.id, range: c.loop, track: c.track, shown: view(of: c), fresh: false)
            }
        }
        .onDisappear {
            exportJob?.cancel()
            preview.stop()
            frames.cancel()
        }
        .task { await makeThumbs(clips) }
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
                    record(snapshot)
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
        EditorVideoView(player: preview)
            .overlay {
                // While sliding: the frame got ready, until the video catches up.
                if let still = preview.still {
                    Image(decorative: still, scale: 1).resizable().scaledToFill()
                }
            }
            .aspectRatio(preview.aspect, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .top) {
                if let zoomPinch {
                    badge(String(format: "%.1f×", clampZoom(zoomPinch.base * zoomPinch.scale)))
                } else if !following.isEmpty {
                    badge("Following the surfer…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { preview.toggle() }
            .simultaneousGesture(zoomGesture)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.top, 10)
            .allowsHitTesting(false)
    }

    private var playRow: some View {
        HStack {
            HStack(spacing: 4) {
                Text(clock(preview.time))
                    .foregroundStyle(.white)
                Text("/ " + clock(totalLength))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 110, alignment: .leading)
            Spacer()
            Button { preview.toggle() } label: {
                Image(systemName: preview.playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 36)
            }
            .foregroundStyle(.white)
            Spacer()
            // As wide as the time on the left, so play sits in the middle.
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(undos.isEmpty || trim != nil || moving != nil)
                Button(action: redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(redos.isEmpty || trim != nil || moving != nil)
            }
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 110)
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Trimming the wave under the playhead to it, as in Premiere; then the
    /// selected wave and removing it.
    private var clipBar: some View {
        HStack(spacing: 8) {
            cutButton("Start here", icon: "arrow.right.to.line", edge: .start)
            cutButton("End here", icon: "arrow.left.to.line", edge: .end)
            // Removes the selected wave; there whether one is selected or not,
            // so the buttons never move.
            Button(role: .destructive) {
                removeSelected()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 34)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            .accessibilityLabel("Remove")
            .disabled(selected == nil || trim != nil || moving != nil)
            Spacer(minLength: 4)
            if let c = clips.first(where: { $0.id == selected }) {
                Circle().fill(c.color).frame(width: 8, height: 8)
                Text(c.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(String(format: "%.1fs", (c.end - c.start) / Double(rate)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private func cutButton(_ title: String, icon: String, edge: Edge) -> some View {
        Button { cut(edge) } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 34)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel(title)
        .disabled(cutPoint(edge) == nil || trim != nil || moving != nil)
    }

    /// The wave under the playhead and the moment in it the playhead is at,
    /// if cutting there leaves at least half a second of it.
    private func cutPoint(_ edge: Edge) -> (index: Int, left: Double, source: Double)? {
        let t = preview.time
        let items = layout
        guard let i = items.firstIndex(where: { t >= $0.left && t < $0.right }) else { return nil }
        let c = items[i].clip
        let source = c.start + (t - items[i].left) * Double(max(0.05, rate))
        let left = edge == .start ? c.end - source : source - c.start
        return left >= Self.shortest ? (i, items[i].left, source) : nil
    }

    /// Cuts the wave under the playhead to it; the rest closes up, and the
    /// picture stays on the same frame.
    private func cut(_ edge: Edge) {
        guard let (i, left, source) = cutPoint(edge) else { return }
        record(snapshot)
        preview.pause()
        if edge == .start {
            clips[i].start = source
            rebuild(at: left)
        } else {
            let t = preview.time
            clips[i].end = source
            rebuild(at: max(left, t - 0.02))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Timeline

    /// Where each wave sits along the finished video, in its seconds.
    private var layout: [(clip: EditClip, left: Double, right: Double)] {
        let speed = Double(max(0.05, rate))
        var cursor = 0.0
        return clips.map { c in
            let length = (c.end - c.start) / speed
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
            let now = trim.map { $0.time - trimShift } ?? preview.time
            let origin = width / 2 - CGFloat(now) * pps
            let items = layout
            ZStack(alignment: .topLeading) {
                Color.clear
                if let moving {
                    reorderRow(moving, width: width)
                        .onReceive(Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()) { _ in
                            scrollRow(width: width)
                        }
                } else {
                ForEach(items, id: \.clip.id) { item in
                    let x = origin + CGFloat(item.left) * pps
                    let w = max(2, CGFloat(item.right - item.left) * pps)
                    clipView(item.clip, width: w, x: x, screen: width)
                        .frame(width: w, height: Self.clipHeight)
                        .offset(x: x, y: 10)
                        .allowsHitTesting(false)
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
            // Taps are worked out here rather than on each wave: a wave
            // listening for its own tap held sliding back until the finger
            // had gone a long way.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                tapTimeline(at: tap.location, origin: origin)
            })
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
                // Measured on the screen, not on the handle: the handle moves
                // with the finger, and measuring on it fed back as jitter.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in moveHandle(edge, of: clip.id, by: value.translation.width) }
                    .onEnded { _ in letGo() }
            )
    }

    /// A tap on a wave selects it, or lets it go; anywhere else lets go.
    private func tapTimeline(at point: CGPoint, origin: CGFloat) {
        guard moving == nil, trim == nil else { return }
        let t = Double((point.x - origin) / pps)
        if point.y >= 10, point.y <= 10 + Self.clipHeight,
           let item = layout.first(where: { t >= $0.left && t < $0.right }) {
            selected = selected == item.clip.id ? nil : item.clip.id
        } else {
            selected = nil
        }
    }

    /// Sliding the timeline moves through the whole video.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard trim == nil, pinchBase == nil, moving == nil else { return }
                if scrubFrom == nil {
                    scrubFrom = preview.time
                    preview.pause()
                    print(String(format: "WSLAG start after %.0fpt", abs(value.translation.width)))
                }
                let t = (scrubFrom ?? 0) - Double(value.translation.width / pps)
                let now = min(max(0, t), max(0, totalLength - 0.01))
                slide(to: now)
            }
            .onEnded { _ in
                guard scrubFrom != nil else { return }
                scrubFrom = nil
                preview.settle()
            }
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
        52
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

    /// The held wave near either edge of the screen scrolls the row that
    /// way, faster the closer it is, until its last tile is in view.
    private func scrollRow(width: CGFloat) {
        guard let moving else { return }
        let tile = tileSize(width)
        let left = rowLeft(width) + moving.shift
        let right = left + CGFloat(clips.count) * (tile + 6) - 6
        let zone: CGFloat = 50
        if moving.x < zone, left < 12 {
            self.moving?.shift += min(12 - left, 8 * (zone - moving.x) / zone)
        } else if moving.x > width - zone, right > width - 12 {
            self.moving?.shift -= min(right - (width - 12), 8 * (moving.x - (width - zone)) / zone)
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
        let left = rowLeft(width)
        // The held wave stays where it was pressed; the others line up on
        // either side of it, off the screen if need be.
        let shift = point.x - (left + CGFloat(i) * (tile + 6) + tile / 2)
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
        if from != to { record(snapshot) }
        let clip = clips.remove(at: from)
        clips.insert(clip, at: to)
        self.moving = nil
        selected = nil
        if from != to { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        // The video goes to the start of the wave just moved, as in CapCut,
        // to see the cut into it straight away.
        let now = min(layout[to].left + 0.01, max(0, totalLength - 0.01))
        preview.seek(now)
        rebuild(at: now)
    }

    // MARK: Trimming

    private func moveHandle(_ edge: Edge, of id: EditClip.ID, by dx: CGFloat) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if trim == nil {
            trim = TrimDrag(before: snapshot, id: id, edge: edge, start: clips[i].start, end: clips[i].end,
                            time: preview.time)
            preview.pause()
            preview.showSource(segment(clips[i]), asset: asset, at: edge == .start ? clips[i].start : clips[i].end)
        }
        guard let trim else { return }
        let c = clips[i]
        let moved = Double(dx / pps) * Double(max(0.05, rate))
        let whole = stretch(of: c)
        if edge == .start {
            clips[i].start = min(max(whole.lowerBound, trim.start + moved), c.end - Self.shortest)
            showFrame(c.id, at: clips[i].start)
            preview.seekSource(clips[i].start)
        } else {
            clips[i].end = max(min(whole.upperBound, trim.end + moved), c.start + Self.shortest)
            showFrame(c.id, at: clips[i].end)
            preview.seekSource(clips[i].end)
        }
    }

    /// The timeline stays just as it is when the handle is let go: the
    /// playhead is on whatever's under it now.
    private func letGo() {
        guard let trim else { return }
        let shift = trimShift
        self.trim = nil
        if let c = clips.first(where: { $0.id == trim.id }), c.start != trim.start || c.end != trim.end {
            record(trim.before)
        }
        rebuild(at: min(max(0, trim.time - shift), max(0, totalLength - 0.01)))
        followIfStretched(trim.id)
    }

    /// While a start handle moves, the timeline moves with it, so the handle
    /// stays under the finger and the waves before it stay flush; the waves
    /// after it stay put. In seconds of the finished video.
    private var trimShift: Double {
        guard let trim, trim.edge == .start, let c = clips.first(where: { $0.id == trim.id }) else { return 0 }
        return (c.start - trim.start) / Double(max(0.05, rate))
    }

    private func segment(_ c: EditClip) -> EditorPlayer.Segment {
        EditorPlayer.Segment(id: c.id, start: c.start, end: c.end, track: c.track, zoom: c.zoom)
    }

    /// How far a wave's handles go: some way past what's ready, as far as the
    /// video goes.
    private func stretch(of c: EditClip) -> ClosedRange<Double> {
        max(0, c.loop.lowerBound - Self.reach)...min(max(duration, c.loop.upperBound), c.loop.upperBound + Self.reach)
    }

    /// A wave stretched past what's ready: the surfer is followed into the
    /// new part, and its frames got ready. The loop itself stays as it was.
    private func followIfStretched(_ id: EditClip.ID) {
        guard let c = clips.first(where: { $0.id == id }),
              c.start < c.loop.lowerBound - 0.02 || c.end > c.loop.upperBound + 0.02 else { return }
        let wanted = min(c.start, c.loop.lowerBound)...max(c.end, c.loop.upperBound)
        following.insert(id)
        Task {
            let track = await follow(id, wanted) ?? c.track
            following.remove(id)
            guard let now = clips.first(where: { $0.id == id }) else { return }
            let old = now.loop
            let loop = min(old.lowerBound, wanted.lowerBound)...max(old.upperBound, wanted.upperBound)
            // Undoing keeps the longer path too: it's the same surfer.
            func adopt(_ list: [EditClip]) -> [EditClip] {
                list.map { c in
                    guard c.id == id else { return c }
                    var c = c
                    c.track = track
                    c.loop = min(c.loop.lowerBound, loop.lowerBound)...max(c.loop.upperBound, loop.upperBound)
                    return c
                }
            }
            clips = adopt(clips)
            undos = undos.map { Snapshot(clips: adopt($0.clips), rate: $0.rate) }
            redos = redos.map { Snapshot(clips: adopt($0.clips), rate: $0.rate) }
            guard let c = clips.first(where: { $0.id == id }) else { return }
            if loop.lowerBound < old.lowerBound {
                frames.want(id, range: loop.lowerBound...old.lowerBound, track: track, shown: view(of: c), fresh: false)
            }
            if loop.upperBound > old.upperBound {
                frames.want(id, range: old.upperBound...loop.upperBound, track: track, shown: view(of: c), fresh: false)
            }
            Task { await makeThumbs([c]) }
            if trim == nil, moving == nil { rebuild(at: preview.time) }
        }
    }

    // MARK: Zooming

    /// What a wave shows of the picture at its zoom.
    private func view(of c: EditClip) -> (w: CGFloat, h: CGFloat) {
        (shown.w / c.zoom, shown.h / c.zoom)
    }

    /// Out as far as the picture's edge, in as far as `mostZoom`.
    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, max(shown.w, shown.h)), Self.mostZoom)
    }

    /// Pinching the video zooms the wave under the playhead, and selects it.
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if zoomPinch == nil {
                    let t = preview.time
                    guard trim == nil, moving == nil,
                          let item = layout.first(where: { t >= $0.left && t < $0.right }) ?? layout.last else { return }
                    preview.pause()
                    // The frame got ready is cut at the old zoom: the video's
                    // own frame, cut afresh each moment, shows instead.
                    preview.showStill(nil)
                    selected = item.clip.id
                    zoomPinch = ZoomPinch(id: item.clip.id, base: item.clip.zoom, scale: 1)
                }
                zoomPinch?.scale = scale
                if let pinch = zoomPinch { preview.setZoom(pinch.id, clampZoom(pinch.base * pinch.scale)) }
            }
            .onEnded { _ in
                guard let pinch = zoomPinch else { return }
                let z = clampZoom(pinch.base * pinch.scale)
                if let i = clips.firstIndex(where: { $0.id == pinch.id }), abs(z - clips[i].zoom) > 0.01 {
                    record(snapshot)
                    clips[i].zoom = z
                    rezoom(clips[i])
                } else {
                    preview.setZoom(pinch.id, pinch.base)
                }
                zoomPinch = nil
            }
    }

    /// A wave at a new zoom: the video already cuts it so; its frames for
    /// sliding and its strip are made again.
    private func rezoom(_ c: EditClip) {
        preview.setZoom(c.id, c.zoom)
        frames.want(c.id, range: c.loop, track: c.track, shown: view(of: c), fresh: true)
        thumbs[c.id] = nil
        Task { await makeThumbs([c]) }
    }

    // MARK: Undo

    private var snapshot: Snapshot { Snapshot(clips: clips, rate: rate) }

    /// Keeps how things were before a change; a new change can't be redone past.
    private func record(_ before: Snapshot) {
        undos.append(before)
        if undos.count > 100 { undos.removeFirst() }
        redos = []
    }

    private func undo() {
        guard let last = undos.popLast() else { return }
        redos.append(snapshot)
        restore(last)
    }

    private func redo() {
        guard let next = redos.popLast() else { return }
        undos.append(snapshot)
        restore(next)
    }

    /// Puts the waves and speed back, staying at about the same moment.
    private func restore(_ state: Snapshot) {
        preview.pause()
        let speedChanged = state.rate != rate
        let rezoomed = state.clips.filter { c in clips.first(where: { $0.id == c.id }).map { $0.zoom != c.zoom } ?? false }
        clips = state.clips
        for c in rezoomed {
            frames.want(c.id, range: c.loop, track: c.track, shown: view(of: c), fresh: true)
            thumbs[c.id] = nil
            Task { await makeThumbs([c]) }
        }
        if !clips.contains(where: { $0.id == selected }) { selected = nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if speedChanged {
            // Changing the speed puts the video together again itself.
            rate = state.rate
        } else {
            rebuild(at: min(preview.time, max(0, totalLength - 0.01)))
        }
    }

    private func removeSelected() {
        guard let i = clips.firstIndex(where: { $0.id == selected }) else { return }
        record(snapshot)
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
        let pieces = clips.map { ClipExport.Piece(start: $0.start, end: $0.end, track: $0.track, zoom: $0.zoom) }
        guard !pieces.isEmpty else { return }
        Task {
            guard let built = try? await ClipExport.build(asset: asset, orientation: orientation, pieces: pieces,
                                                          shown: shown, rate: rate, width: Self.previewWidth),
                  run == buildRun else { return }
            let at = min(max(0, time), max(0, built.duration - 0.01))
            preview.load(built, segments: clips.map(segment), rate: rate, at: at, play: play)
            if !play { showReady(at: at) }
        }
    }

    /// The frame got ready for a moment of the finished video, held over it,
    /// so the picture looks the same as while sliding.
    private func showReady(at t: Double) {
        let items = layout
        guard let item = items.first(where: { t < $0.right }) ?? items.last else { return }
        let source = min(item.clip.start + (t - item.left) * Double(max(0.05, rate)), item.clip.end)
        frames.show(item.clip.id, at: source) { image in
            guard abs(preview.time - t) < 0.0005, !preview.playing else { return }
            preview.showStill(image)
        }
    }

    /// The timeline moves at once; the picture follows with the frame got
    /// ready for that moment, or, without one, by seeking the video.
    private func slide(to t: Double) {
        let items = layout
        guard let item = items.first(where: { t < $0.right }) ?? items.last else { return }
        let source = min(item.clip.start + (t - item.left) * Double(max(0.05, rate)), item.clip.end)
        preview.slide(to: t)
        let asked = Date()
        frames.show(item.clip.id, at: source) { image in
            // Only the latest moment asked for counts.
            guard abs(preview.time - t) < 0.0005, scrubFrom != nil else { return }
            print(String(format: "WSLAG slide %.2f %@ %.0fms", t, image == nil ? "SEEK" : "frame",
                         Date().timeIntervalSince(asked) * 1000))
            if let image { preview.showStill(image) } else { preview.seek(t) }
        }
    }

    /// While a handle moves: the frame at it, when it's ready.
    private func showFrame(_ id: EditClip.ID, at source: Double) {
        frames.show(id, at: source) { image in
            guard trim != nil else { return }
            preview.showStill(image)
        }
    }

    private func nearest(_ id: EditClip.ID, _ t: Double) -> UIImage? {
        thumbs[id]?.min { abs($0.time - t) < abs($1.time - t) }?.image
    }

    /// A small frame of each wave every half second, cut as it will be
    /// exported. Every wave gets a rough set first, then the rest. Stops for
    /// a wave zoomed again meanwhile: it gets a new set.
    private func makeThumbs(_ clips: [EditClip]) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        for pass in [2.0, 0.5] {
            for c in clips {
                for t in stride(from: c.loop.lowerBound, through: c.loop.upperBound, by: pass) {
                    guard !Task.isCancelled else { return }
                    guard self.clips.first(where: { $0.id == c.id })?.zoom == c.zoom else { break }
                    if thumbs[c.id]?.contains(where: { abs($0.time - t) < 0.2 }) == true { continue }
                    guard let made = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                    else { continue }
                    let image = made.image
                    let v = view(of: c)
                    let r = FollowView(track: c.track, shownW: v.w, shownH: v.h).rect(at: t)
                    let w = CGFloat(image.width), h = CGFloat(image.height)
                    let crop = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
                        .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
                    let piece = crop.isEmpty ? image : (image.cropping(to: crop) ?? image)
                    guard self.clips.first(where: { $0.id == c.id })?.zoom == c.zoom else { break }
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
        let pieces = clips.map { ClipExport.Piece(start: $0.start, end: $0.end, track: $0.track, zoom: $0.zoom) }
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
