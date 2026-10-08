import SwiftUI

/// The whole video in one strip. Wherever your finger is, that's the moment
/// shown — drag along it to sweep through the hour and find the wave.
/// Marked waves are lines on it; passing over one snaps to its start.
struct OverviewStrip: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var dragging = false
    @State private var snappedTo: Wave.ID?
    private let haptics = UISelectionFeedbackGenerator()

    /// How close, in points, the finger must come to a wave line to land on it.
    private static let snapDistance: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // Show as many 16:9 thumbnails as fit, sampled from the full set.
            let slots = max(1, Int((width / (height * 16 / 9)).rounded(.up)))
            let all = model.thumbnails
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<slots, id: \.self) { slot in
                        let index = all.isEmpty ? 0 : min(all.count - 1, slot * all.count / slots)
                        ZStack {
                            Color.white.opacity(0.08)
                            if !all.isEmpty, let image = all[index] {
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: width / CGFloat(slots), height: height)
                        .clipped()
                    }
                }
                .opacity(0.75)

                ForEach(model.waves) { wave in
                    let wx = model.duration > 0 ? CGFloat(wave.time / model.duration) * width : 0
                    Rectangle()
                        .fill(Color.cyan)
                        .frame(width: 2, height: height)
                        .offset(x: wx - 1)
                    Text(wave.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color.cyan.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize()
                        .offset(x: wx + 2, y: -height / 2 + 7)
                }

                let x = model.duration > 0 ? CGFloat(model.currentTime / model.duration) * width : 0
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: 3, height: height + 8)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: x - 1.5)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging { dragging = true; model.beginScrub(); haptics.prepare() }
                        let fingerX = min(max(0, value.location.x), width)
                        let secondsPerPoint = model.duration / Double(width)
                        let near = model.waves.min {
                            abs(waveX($0, width) - fingerX) < abs(waveX($1, width) - fingerX)
                        }
                        if let near, abs(waveX(near, width) - fingerX) <= Self.snapDistance {
                            if snappedTo != near.id { snappedTo = near.id; haptics.selectionChanged() }
                            model.scrub(to: near.time, tolerance: 0)
                        } else {
                            snappedTo = nil
                            model.scrub(to: Double(fingerX) * secondsPerPoint, tolerance: secondsPerPoint)
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        snappedTo = nil
                        model.endScrub()
                    }
            )
        }
    }

    private func waveX(_ wave: Wave, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(wave.time / model.duration) * width : 0
    }
}

/// A tape measure centred on the current frame. Drag it like film through a
/// gate: slide left to go forward, right to go back. Pinch it to change how
/// much time fits across — from 1 second (frame by frame) up to 10 minutes.
/// The window button beside the play button flips it between 5s and 5m.
struct FineTape: View {
    @EnvironmentObject private var model: PlayerModel
    @AppStorage(FineTape.spanKey) private var span: Double = FineTape.defaultSpan
    @State private var dragStartTime: Double?
    @State private var pinchStartSpan: Double?

    static let spanKey = "tapeWindow"
    static let defaultSpan = 5.0
    static let minSpan = 1.0
    static let maxSpan = 600.0
    static let searchSpan = 300.0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in draw(ctx, size: size) }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard pinchStartSpan == nil else { return }
                        if dragStartTime == nil {
                            dragStartTime = model.currentTime
                            model.beginScrub()
                        }
                        let secondsPerPoint = span / Double(width)
                        let seconds = Double(value.translation.width) * secondsPerPoint
                        // Up to 30 s across, every frame is exact; wider than that the
                        // finger moves too fast to tell, so allow the nearby keyframe.
                        model.scrub(to: dragStartTime! - seconds,
                                    tolerance: span <= 30 ? 0 : secondsPerPoint * 2)
                    }
                    .onEnded { _ in
                        if dragStartTime != nil { model.endScrub() }
                        dragStartTime = nil
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStartSpan == nil {
                            pinchStartSpan = span
                            // The pinch takes over; re-anchor any drag at the current moment.
                            if dragStartTime != nil { dragStartTime = model.currentTime }
                        }
                        let next = pinchStartSpan! / Double(value.magnification)
                        span = min(max(next, Self.minSpan), Self.maxSpan)
                    }
                    .onEnded { _ in pinchStartSpan = nil }
            )
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let duration = model.duration
        guard duration > 0, size.width > 0 else { return }
        let pxPerSec = Double(size.width) / span
        let t0 = model.currentTime - span / 2
        let t1 = t0 + span
        func x(_ t: Double) -> CGFloat { CGFloat((t - t0) * pxPerSec) }

        // Grey out before the start and after the end.
        if t0 < 0 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x(0), height: size.height)), with: .color(.black.opacity(0.5)))
        }
        if t1 > duration {
            ctx.fill(Path(CGRect(x: x(duration), y: 0, width: size.width - x(duration), height: size.height)),
                     with: .color(.black.opacity(0.5)))
        }

        let major = Self.majorInterval(pxPerSec: pxPerSec)
        let frame = 1 / model.frameRate
        // One tick per frame when frames are far enough apart to see.
        let minor = frame * pxPerSec >= 5 ? frame : major / 5

        var minorPath = Path()
        var t = (max(t0, 0) / minor).rounded(.down) * minor
        while t <= min(t1, duration) {
            let px = x(t)
            minorPath.move(to: CGPoint(x: px, y: size.height * 0.62))
            minorPath.addLine(to: CGPoint(x: px, y: size.height))
            t += minor
        }
        ctx.stroke(minorPath, with: .color(.white.opacity(0.35)), lineWidth: 1)

        var majorPath = Path()
        t = (max(t0, 0) / major).rounded(.down) * major
        while t <= min(t1, duration) {
            let px = x(t)
            majorPath.move(to: CGPoint(x: px, y: size.height * 0.42))
            majorPath.addLine(to: CGPoint(x: px, y: size.height))
            ctx.draw(Text(formatTime(t, decimals: major < 1 ? 1 : 0))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7)),
                     at: CGPoint(x: px, y: size.height * 0.30))
            t += major
        }
        ctx.stroke(majorPath, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

        // The playhead.
        let mid = size.width / 2
        ctx.fill(Path(CGRect(x: mid - 1.5, y: 0, width: 3, height: size.height)), with: .color(.yellow))
    }

    /// The labelled tick spacing: the smallest round interval at least 70pt apart.
    static func majorInterval(pxPerSec: Double) -> Double {
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 * pxPerSec >= 70 } ?? 600
    }

    /// 5s, 30s, 2m, 2.5m.
    static func spanLabel(_ span: Double) -> String {
        if span < 60 { return String(format: "%.0fs", span) }
        let minutes = span / 60
        return minutes == minutes.rounded() ? String(format: "%.0fm", minutes) : String(format: "%.1fm", minutes)
    }
}

/// 1:02:03.45, or 2:03.45 under an hour.
func formatTime(_ seconds: Double, decimals: Int = 2) -> String {
    let s = max(0, seconds)
    let whole = Int(s)
    let h = whole / 3600, m = (whole % 3600) / 60, sec = whole % 60
    var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    if decimals > 0 {
        let scale = pow(10, Double(decimals))
        let frac = Int(((s - Double(whole)) * scale).rounded(.down))
        out += String(format: ".%0\(decimals)d", frac)
    }
    return out
}
