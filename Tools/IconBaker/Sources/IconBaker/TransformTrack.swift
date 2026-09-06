import Foundation

/// Evaluates a Lottie layer transform into the three curves the client needs.
///
/// This is the whole of Ask C's reduction: walk `layers[i].ks`, evaluate scale,
/// rotation and opacity at N even instants, and hand back arrays. It is small
/// because the hard part was deciding it was possible, not doing it.
struct TransformTrack {

    var scale: [Double]
    var rotation: [Double]     // radians
    var opacity: [Double]      // 0…1

    /// Why a file was refused, when it was.
    enum Refusal: Error, CustomStringConvertible {
        case noLayer
        case animatedPosition
        case nonUniformScale

        var description: String {
            switch self {
            case .noLayer: "no animated layer transform"
            case .animatedPosition: "animated position — MotionTrack has no translate channel"
            case .nonUniformScale: "non-uniform scale — MotionTrack carries one scale"
            }
        }
    }

    /// Samples the composition's single animated layer.
    ///
    /// `count` samples over the CLOSED interval, so the caller gets the closing
    /// value for interpolated playback and can drop it for stepped playback —
    /// the same convention `IconMotionTrack` uses on the client. The two have to
    /// agree or the loop is one frame long in one of them.
    static func extract(
        from document: LottieDocument, samples count: Int
    ) -> Result<TransformTrack, Refusal> {
        guard let layers = document.json["layers"] as? [[String: Any]],
              let layer = layers.first(where: { hasAnimation($0["ks"]) }),
              let transform = layer["ks"] as? [String: Any]
        else { return .failure(.noLayer) }

        if hasAnimation(transform["p"]) { return .failure(.animatedPosition) }

        let length = document.sourceFrameCount
        let inPoint = document.json["ip"] as? Double ?? 0

        var scale: [Double] = [], rotation: [Double] = [], opacity: [Double] = []
        for index in 0...count {
            let frame = inPoint + length * Double(index) / Double(count)
            let s = value(transform["s"], at: frame, fallback: [100, 100])
            if abs(s[0] - (s.count > 1 ? s[1] : s[0])) > 0.5 {
                return .failure(.nonUniformScale)
            }
            scale.append(s[0] / 100)
            rotation.append(value(transform["r"], at: frame, fallback: [0])[0] * .pi / 180)
            opacity.append(value(transform["o"], at: frame, fallback: [100])[0] / 100)
        }
        return .success(TransformTrack(scale: scale, rotation: rotation, opacity: opacity))
    }

    private static func hasAnimation(_ node: Any?) -> Bool {
        guard let dictionary = node as? [String: Any] else { return false }
        if dictionary["a"] as? Int == 1 { return true }
        return dictionary.values.contains { hasAnimation($0) }
    }

    /// One animatable property, evaluated at a source frame.
    ///
    /// Handles both shapes Lottie uses: static (`a: 0`, `k` is the value) and
    /// animated (`a: 1`, `k` is a keyframe array). Keyframes are held before the
    /// first and after the last, as After Effects does.
    static func value(_ node: Any?, at frame: Double, fallback: [Double]) -> [Double] {
        guard let property = node as? [String: Any] else { return fallback }
        guard property["a"] as? Int == 1 else { return numbers(property["k"]) ?? fallback }
        guard let keyframes = property["k"] as? [[String: Any]], !keyframes.isEmpty else {
            return fallback
        }

        if frame <= (keyframes[0]["t"] as? Double ?? 0) {
            return numbers(keyframes[0]["s"]) ?? fallback
        }
        for index in 0..<(keyframes.count - 1) {
            let current = keyframes[index], next = keyframes[index + 1]
            let start = current["t"] as? Double ?? 0
            let end = next["t"] as? Double ?? 0
            guard frame < end, end > start else { continue }

            // `s` is this keyframe's value; `e` is the legacy end value, which
            // newer exporters omit in favour of the next keyframe's `s`.
            let from = numbers(current["s"]) ?? fallback
            let to = numbers(current["e"]) ?? numbers(next["s"]) ?? from
            if current["h"] as? Int == 1 { return from }   // hold keyframe

            let linear = (frame - start) / (end - start)
            let eased = ease(linear, out: current["o"], in: current["i"])
            return zip(from, to).map { $0 + ($1 - $0) * eased }
        }
        return numbers(keyframes[keyframes.count - 1]["s"])
            ?? numbers(keyframes[keyframes.count - 2]["e"]) ?? fallback
    }

    private static func numbers(_ node: Any?) -> [Double]? {
        if let value = node as? Double { return [value] }
        if let value = node as? Int { return [Double(value)] }
        if let array = node as? [Double] { return array }
        if let array = node as? [Any] {
            let mapped = array.compactMap { $0 as? Double ?? ($0 as? Int).map(Double.init) }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }

    /// After Effects' temporal easing: a cubic bezier from (0,0) to (1,1) with
    /// control points taken from the keyframe's `o` (out) and `i` (in).
    ///
    /// Ignoring this is the tempting shortcut and it is wrong in a way nothing
    /// catches: a linearly-sampled ease-in-out reaches the same poses, just at
    /// evenly spaced times, so the icon animates at a visibly different rhythm
    /// from the artwork and every automated check still passes.
    private static func ease(_ t: Double, out: Any?, in easeIn: Any?) -> Double {
        guard let outControl = control(out), let inControl = control(easeIn) else { return t }
        let (x1, y1) = outControl, (x2, y2) = inControl

        // Newton on x(u) = t, then read y(u). Ten iterations is far more than a
        // monotone cubic on [0,1] needs.
        func curve(_ a: Double, _ b: Double, _ u: Double) -> Double {
            let inverse = 1 - u
            return 3 * inverse * inverse * u * a + 3 * inverse * u * u * b + u * u * u
        }
        var u = t
        for _ in 0..<10 {
            let x = curve(x1, x2, u) - t
            let inverse = 1 - u
            let slope = 3 * inverse * inverse * x1 + 6 * inverse * u * (x2 - x1)
                + 3 * u * u * (1 - x2)
            if abs(slope) < 1e-6 { break }
            u -= x / slope
            u = min(max(u, 0), 1)
        }
        return curve(y1, y2, u)
    }

    private static func control(_ node: Any?) -> (Double, Double)? {
        guard let dictionary = node as? [String: Any] else { return nil }
        let x = numbers(dictionary["x"])?.first
        let y = numbers(dictionary["y"])?.first
        guard let x, let y else { return nil }
        return (x, y)
    }
}
