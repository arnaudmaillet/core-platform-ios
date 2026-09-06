import CoreGraphics
import Foundation
import UIKit

/// # Animated pin icons
///
/// A text-only post may carry an animated icon, and the map draws it where the
/// author's avatar would go. This file is the client half of
/// `dev/issues/BACKEND_ANIMATED_PIN_ICONS.md`.
///
/// ## Two representations, and the difference is 24x
///
/// - **`.decomposed`** — one picture plus three curves. Where an icon's motion
///   is a rigid mark being scaled, rotated or faded, the sprite sheet a naive
///   pipeline would ship is a CACHE OF A TRANSFORM Core Animation applies for
///   free. Measured on the map's saturated worst case, 128 distinct icons:
///   **9.0 MB against 216.8 MB**, same picture, verified pixel-for-pixel.
/// - **`.sheet`** — every frame in one grid, for artwork whose pixels change
///   (a GIF, or a Lottie that is not transform-only). Correct, and expensive.
///
/// Both play through `CAKeyframeAnimation` on the render server, so the app's
/// main thread never wakes per frame in either case. The wire format changes
/// only what was baked, never how it plays.
///
/// ## The clock
///
/// Every icon in a catalogue changes on ONE grid: steps are integer multiples
/// of a shared base, so 128 markers composite at a bounded rate instead of
/// scattering their change instants across every refresh. That is worth up to
/// 20% of battery drain (WWDC22, *Power down*), and it is a property of the
/// BAKE — `Tools/IconBaker` guarantees it. See `AnimatedIconCatalog.isHarmonic`.

// MARK: - Motion

/// A motion expressed as animation rather than as pixels: three channels
/// sampled evenly over one loop.
public struct AnimatedIconMotionTrack: Sendable, Equatable {

    /// `frameCount + 1` samples over the CLOSED interval [0, 1].
    ///
    /// The closing sample exists for interpolated playback: without it, linear
    /// interpolation runs from the last keyframe back to the first and a full
    /// rotation unwinds a whole turn backwards at every loop boundary. Stepped
    /// playback drops it again, because `.discrete` divides the duration by
    /// `values.count` and an extra value would stretch the loop.
    public let scales: [Double]
    public let rotations: [Double]
    public let alphas: [Double]
    public let step: CFTimeInterval

    public var frameCount: Int { max(1, scales.count - 1) }
    public var loopDuration: CFTimeInterval { step * CFTimeInterval(frameCount) }

    /// Only the channels that actually move get an animation. A spin moves one,
    /// a flicker two — installing three unconditionally would put hundreds of
    /// animations on the render server where a fraction will do.
    public var movesScale: Bool { varies(scales) }
    public var movesRotation: Bool { varies(rotations) }
    public var movesAlpha: Bool { varies(alphas) }

    private func varies(_ channel: [Double]) -> Bool {
        guard let first = channel.first else { return false }
        return channel.contains { abs($0 - first) > 0.0005 }
    }

    public init(scales: [Double], rotations: [Double], alphas: [Double], step: CFTimeInterval) {
        self.scales = scales
        self.rotations = rotations
        self.alphas = alphas
        self.step = step
    }

    /// This marker's phased samples.
    ///
    /// Phase is applied by SAMPLING FROM A ROTATED GRID rather than by
    /// offsetting `beginTime`: marker *k* starts on sample *k % n* and every
    /// marker still changes on one shared clock. Staggering time instead would
    /// scatter the change instants across every refresh, which is exactly the
    /// battery cost the shared epoch exists to avoid.
    public func phased(by phase: Int) -> AnimatedIconMotionTrack {
        let count = frameCount
        guard count > 1 else { return self }
        let offset = ((phase % count) + count) % count

        func rotate(_ channel: [Double]) -> [Double] {
            let base = Array(channel.prefix(count))
            guard !base.isEmpty else { return channel }
            var rotated = (0..<count).map { base[(offset + $0) % count] }
            rotated.append(rotated[0])
            return rotated
        }
        return AnimatedIconMotionTrack(
            scales: rotate(scales),
            rotations: Self.unwrapped(rotate(rotations)),
            alphas: rotate(alphas),
            step: step
        )
    }

    /// Takes every step along its SHORT arc and accumulates, so a full-turn
    /// spin stays a monotone ramp whatever phase it starts on. Without it the
    /// sequence jumps from ~2pi back to 0 once per loop, wherever the phase
    /// boundary lands, and the icon snaps backwards once per turn.
    static func unwrapped(_ channel: [Double]) -> [Double] {
        guard channel.count > 1 else { return channel }
        var result = channel
        for i in 1..<result.count {
            var delta = result[i] - result[i - 1]
            if delta < -Double.pi { delta += 2 * .pi }
            if delta > Double.pi { delta -= 2 * .pi }
            result[i] = result[i - 1] + delta
        }
        return result
    }
}

// MARK: - The two shapes of art

/// One picture plus a motion track — the cheap representation.
public struct AnimatedIconStill: Sendable, Equatable {
    /// The only texture this icon owns.
    public let mark: UIImage
    public let track: AnimatedIconMotionTrack

    public var frameCount: Int { track.frameCount }
    public var frameDuration: CFTimeInterval { track.step }

    /// Texture PLUS track.
    ///
    /// Counting only the texture would make "frame rate costs no memory" true
    /// by construction of the metric, since the texture is the one thing frame
    /// rate does not scale. The samples are ~3 KB at 120 keys — 4% of the
    /// total. Small is a result; zero was a bookkeeping error.
    public var byteCost: Int {
        let texture = mark.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        return texture
            + (track.scales.count + track.rotations.count + track.alphas.count)
            * MemoryLayout<Double>.size
    }

    public init(mark: UIImage, track: AnimatedIconMotionTrack) {
        self.mark = mark
        self.track = track
    }
}

/// Every frame in one grid — for artwork whose pixels change.
public struct AnimatedIconSheet: Sendable, Equatable {
    public let sheet: UIImage
    public let frameCount: Int
    public let columns: Int
    public let frameDuration: CFTimeInterval
    /// The `contentsRect` for each frame, in UNIT coordinates — which survive
    /// the marker being resized between its pin, cluster and flight sizes
    /// without recomputation.
    public let frameRects: [CGRect]

    public var loopDuration: CFTimeInterval { frameDuration * CFTimeInterval(frameCount) }
    public var byteCost: Int { sheet.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }

    public init(sheet: UIImage, frameCount: Int, columns: Int, frameDuration: CFTimeInterval) {
        self.sheet = sheet
        self.frameCount = frameCount
        self.columns = columns
        self.frameDuration = frameDuration
        let rows = Int(ceil(Double(frameCount) / Double(columns)))
        let width = 1.0 / Double(columns)
        let height = 1.0 / Double(rows)
        self.frameRects = (0..<frameCount).map { index in
            CGRect(
                x: Double(index % columns) * width,
                // Row-major FROM THE TOP, which is what `contentsRect` means.
                // The baker writes the grid the same way; when it did not, the
                // client played the last row first and the partly-filled row —
                // read first — opened every loop with blank frames.
                y: Double(index / columns) * height,
                width: width, height: height
            )
        }
    }
}

/// The two kept apart at the type level, so a consumer must state which it is
/// looking at and a fallback can be counted rather than averaged away.
public enum AnimatedIconArt: Sendable, Equatable {
    case decomposed(AnimatedIconStill)
    case sheet(AnimatedIconSheet)

    public var byteCost: Int {
        switch self {
        case .decomposed(let still): still.byteCost
        case .sheet(let sheet): sheet.byteCost
        }
    }
    public var frameCount: Int {
        switch self {
        case .decomposed(let still): still.frameCount
        case .sheet(let sheet): sheet.frameCount
        }
    }
    public var frameDuration: CFTimeInterval {
        switch self {
        case .decomposed(let still): still.frameDuration
        case .sheet(let sheet): sheet.frameDuration
        }
    }
    public var isDecomposed: Bool {
        if case .decomposed = self { return true }
        return false
    }
}
