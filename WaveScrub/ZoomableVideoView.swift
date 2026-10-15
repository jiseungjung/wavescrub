import AVFoundation
import SwiftUI
import UIKit

/// The video, pinch-to-zoom and drag-to-pan. Double-tap zooms in 3× where you
/// tapped, or back out. A single tap is passed up (it hides the controls in
/// landscape).
struct ZoomableVideoView: UIViewRepresentable {
    let player: AVPlayer
    let videoSize: CGSize
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomingPlayerView {
        ZoomingPlayerView(player: player)
    }

    func updateUIView(_ view: ZoomingPlayerView, context: Context) {
        view.videoSize = videoSize
        view.onSingleTap = onSingleTap
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class ZoomingPlayerView: UIScrollView, UIScrollViewDelegate {
    private let content = PlayerLayerView()
    private var laidOutFor: CGSize = .zero
    var onSingleTap: () -> Void = {}
    var videoSize: CGSize = .zero {
        didSet { if oldValue != videoSize { relayout(keepZoom: false) } }
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        content.playerLayer.player = player
        content.playerLayer.videoGravity = .resizeAspect
        addSubview(content)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 12
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A resize (the keyboard coming up to name a wave squashes the video)
        // keeps the zoom and the spot you were looking at, even when it
        // leaves the view wider than tall: turning the phone is a different
        // view altogether. A nudge of a point or two (the controls around it
        // re-laying out while playing) leaves everything exactly where it is.
        let size = bounds.size
        if abs(size.width - laidOutFor.width) > 40 || abs(size.height - laidOutFor.height) > 40 {
            relayout(keepZoom: true)
        } else if size != laidOutFor {
            laidOutFor = size
            centerContent()
        }
    }

    /// Sizes the video to fit exactly, so zooming never pans into black bars.
    private func relayout(keepZoom: Bool) {
        let old = laidOutFor
        laidOutFor = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = keepZoom ? zoomScale : 1
        // Where the middle of the view was, as a fraction across the video.
        let focus = contentSize.width > 0 && contentSize.height > 0
            ? CGPoint(x: min(max((contentOffset.x + old.width / 2) / contentSize.width, 0), 1),
                      y: min(max((contentOffset.y + old.height / 2) / contentSize.height, 0), 1))
            : CGPoint(x: 0.5, y: 0.5)
        zoomScale = 1
        let fit = videoSize == .zero
            ? bounds.size
            : AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: bounds.size)).size
        content.frame = CGRect(origin: .zero, size: fit)
        contentSize = fit
        zoomScale = scale
        centerContent()
        if scale > 1.01 {
            let x = focus.x * contentSize.width - bounds.width / 2
            let y = focus.y * contentSize.height - bounds.height / 2
            contentOffset = CGPoint(
                x: min(max(x, -contentInset.left), contentSize.width + contentInset.right - bounds.width),
                y: min(max(y, -contentInset.top), contentSize.height + contentInset.bottom - bounds.height))
        } else {
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleSingleTap() { onSingleTap() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: content)
        let scale: CGFloat = 3
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
