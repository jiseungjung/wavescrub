// Runs the app's own tracker on a clip that starts at a wave's bookmark, on a
// Mac, and prints what it saw frame by frame. Built and run by the "Tracker
// lab" workflow against the clips in the test-clips release.
import AVFoundation
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: trackclip <video>")
    exit(1)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
do {
    let track = try await WaveTracker.track(asset: asset, from: 0, tap: nil) { print($0) }
    for (i, x) in track.xs.enumerated() {
        print(String(format: "point,%.3f,%.4f,%.4f", track.start + Double(i) * track.step, x, track.ys[i]))
    }
    print(String(format: "result,%.3f,%.3f,%.4f", track.start, track.end, track.height))
} catch {
    print("error,\(error)")
}
