#if DEBUG
import AVFoundation
import QuartzCore
import UIKit

/// `-animation-audit`: what keeps the render server busy on a screen nobody
/// touches (#580).
///
/// An idle screen should cost nothing, but a Core Animation animation that
/// repeats forever — a pulse, a shimmer, a sprite sheet — is drawn by the
/// render server every frame without the app doing a thing, so the app's own
/// CPU says nothing about it. Every 5 s this walks every window's layer tree
/// and writes each running animation — its key, its kind, how it repeats and
/// the view that owns the layer — to `animation-audit.log` in the app's
/// Documents (read it with `xcrun simctl get_app_container <udid>
/// cn.wynn.core-platform-ios data`).
@MainActor
enum AnimationAudit {
    private static var timer: Timer?

    static func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-animation-audit"), timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { report() }
        }
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }

    private static func report() {
        var lines: [String] = []
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where !window.isHidden {
            walk(window.layer, in: window, lines: &lines)
        }
        let stamp = String(format: "%.1f", ProcessInfo.processInfo.systemUptime)
        write(["[\(stamp)] \(lines.count) animated layers"] + lines.map { "  " + $0 })
    }

    private static func walk(
        _ layer: CALayer, in window: UIWindow, hidden: Bool = false, paused: Bool = false, lines: inout [String]
    ) {
        // Hidden or transparent here or above: an animation that still runs
        // but draws nothing — the render server skips it, the app does not.
        let hidden = hidden || layer.isHidden || layer.opacity == 0
        // Speed 0 here or above: attached, frozen, and free.
        let paused = paused || layer.speed == 0
        // A playing video is no Core Animation animation, and costs a frame
        // every frame all the same.
        if let player = (layer as? AVPlayerLayer)?.player {
            lines.append("\(owners(of: layer)) AVPlayerLayer rate=\(player.rate)" + (hidden ? " HIDDEN" : ""))
        }
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let onScreen = layer.convert(layer.bounds, to: window.layer).intersects(window.bounds)
            for key in keys {
                guard let animation = layer.animation(forKey: key) else { continue }
                let repeats = animation.repeatCount == .infinity || animation.repeatDuration == .infinity
                    ? "forever" : (animation.repeatCount > 0 ? "x\(animation.repeatCount)" : "once")
                lines.append("\(owners(of: layer)) key=\(key) \(type(of: animation)) duration=\(animation.duration) \(repeats)"
                    + (hidden ? " HIDDEN" : "") + (paused ? " PAUSED" : "") + (onScreen ? "" : " OFFSCREEN"))
            }
        }
        for sublayer in layer.sublayers ?? [] {
            walk(sublayer, in: window, hidden: hidden, paused: paused, lines: &lines)
        }
    }

    /// The layer's view and the nearest view controller above it, so a line
    /// names the screen as well as the view.
    private static func owners(of layer: CALayer) -> String {
        var node: CALayer? = layer
        var view: UIView?
        while let current = node, view == nil {
            view = current.delegate as? UIView
            node = current.superlayer
        }
        let viewName = view.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
        let controller = view.flatMap { view in
            sequence(first: view as UIResponder, next: \.next).lazy.compactMap { $0 as? UIViewController }.first
        }
        return controller.map { "\(String(describing: type(of: $0)))/\(viewName)" } ?? viewName
    }

    private static func write(_ lines: [String]) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        let url = directory.appendingPathComponent("animation-audit.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
