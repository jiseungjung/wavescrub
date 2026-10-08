import SwiftUI

/// The whole video in one strip. Wherever your finger is, that's the moment
/// shown — drag along it to sweep through the hour and find the wave.
struct OverviewStrip: View {
    @EnvironmentObject private var model: PlayerModel
    @State private var dragging = false

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
                        if !dragging { dragging = true; model.beginScrub() }
                        let fraction = min(max(0, value.location.x / width), 1)
                        model.scrub(to: Double(fraction) * model.duration, precise: false)
                    }
                    .onEnded { _ in
                        dragging = false
                        model.endScrub()
                    }
            )
        }
    }
}

/// A tape measure centred on the current frame. Drag it like film through a
/// gate: slide left to go forward, right to go back. Pinch it to change how
/// much time fits across — from 1 second (frame by frame) up to 10 minutes.
struct FineTape: View {
    @EnvironmentObject private var model: PlayerModel
    @AppStorage("tapeSpan") private var span: Double = 6
    @State private var dragStartTime: Double?
    @State private var pinchStartSpan: Double?

    static let minSpan = 1.0
    static let maxSpan = 600.0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size: size) }
                Text("↔ \(Self.spanLabel(span)) · pinch to change")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 6)
                    .padding(.top, 3)
            }
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
                        let seconds = Double(value.translation.width / width) * span
                        model.scrub(to: dragStartTime! - seconds, precise: span <= 30)
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

    static func spanLabel(_ span: Double) -> String {
        span < 60 ? String(format: "%.0f s", span) : String(format: "%.1f min", span / 60)
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
