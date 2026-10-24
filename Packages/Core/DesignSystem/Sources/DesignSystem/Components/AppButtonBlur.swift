import Accelerate
import UIKit

/// The content change's pictures and curves (the owner, 2026-10-23): the
/// content blurs progressively, swaps at the peak, and clears, while the
/// button resizes on a spring, its ground staying sharp.
///
/// ⚠️ UIKIT HAS NO PUBLIC BLUR OF A VIEW'S OWN PIXELS. A `UIVisualEffectView`
/// blurs what is BEHIND it, through a tinted material — the grey veil this
/// replaced. So the button is drawn (`layer.render`) and its content blurred
/// on the CPU (vImage, a few milliseconds), a few levels per state, which
/// the stand-in's layers cross-fade.
@MainActor
enum AppButtonBlur {
    /// `rect` of `view` as it is laid out now, on a transparent margin `pad`
    /// wide for the blur to spread into.
    static func snapshot(of view: UIView, rect: CGRect, pad: CGFloat, scale: CGFloat) -> CGImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let size = CGSize(width: rect.width + pad * 2, height: rect.height + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: pad - rect.minX, y: pad - rect.minY)
            view.layer.render(in: context.cgContext)
        }.cgImage
    }

    /// A ground's inside, clear of its rounded corners — inset by 0.3 of the
    /// radius (1 − 1/√2) — to stretch to any size and cut to any shape.
    ///
    /// ⚠️ NOT STRETCHED BETWEEN ITS CORNERS: a symbol over its words stands
    /// taller than wide, its corners as deep as half its width, and turned
    /// into a wide capsule those corners overlap — a seam across its middle
    /// (filmed, 2026-10-23).
    static func inside(of ground: CGImage, pad: CGFloat, cap: CGFloat, scale: CGFloat) -> CGImage? {
        let inset = (pad + cap * 0.3) * scale
        let rect = CGRect(x: 0, y: 0, width: ground.width, height: ground.height).insetBy(dx: inset, dy: inset).integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return ground.cropping(to: rect)
    }

    /// `a` and `b` mixed, `b`'s share `mix`, at `b`'s size.
    static func mixed(_ a: CGImage, _ b: CGImage, mix: CGFloat) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: b.width, height: b.height)
        guard let context = bitmap(width: b.width, height: b.height) else { return nil }
        context.setAlpha(1 - mix)
        context.draw(a, in: rect)
        context.setAlpha(mix)
        context.draw(b, in: rect)
        return context.makeImage()
    }

    /// The content alone out of `whole` — the button drawn with its content
    /// — and `ground`, the same drawn without: what the content adds, at the
    /// weight the button draws it. Drawn over its ground (premultiplied),
    /// a pixel is `whole = ink + (1 − coverage) · ground`, so the colour
    /// follows from the coverage, which the alpha gives where the ground is
    /// see-through — `(whole.a − ground.a) / (1 − ground.a)`: off the
    /// ground, at its edge, on a translucent fill — and, where it is opaque,
    /// how far the pixel moved from the ground towards `foreground`.
    ///
    /// ⚠️ THE QUIET FILL IS TRANSLUCENT (`HeroTray.fill`, three quarters
    /// opaque): treated as no ground, its words came out at a fifth of
    /// their ink, the whole stand-in pale (dumped, 2026-10-23).
    ///
    /// Vectorised (vDSP): a loop over the pixels cost 30–47 ms a state in a
    /// debug build, the lag between the press and the change (measured,
    /// 2026-10-23).
    static func ink(of whole: CGImage, over ground: CGImage, foreground: UIColor) -> CGImage? {
        let width = whole.width
        let height = whole.height
        let count = width * height
        guard let drawnBytes = pixels(whole, width: width, height: height),
              let bareBytes = pixels(ground, width: width, height: height) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        foreground.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let ink = [Float(red * 255), Float(green * 255), Float(blue * 255)]
        let drawn = vDSP.integerToFloatingPoint(drawnBytes, floatingPointType: Float.self)
        let bare = vDSP.integerToFloatingPoint(bareBytes, floatingPointType: Float.self)
        // One channel of an interleaved RGBA buffer, as a plain array.
        func channel(_ buffer: [Float], _ index: Int) -> [Float] {
            var out = [Float](repeating: 0, count: count)
            buffer.withUnsafeBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    guard let base = source.baseAddress, let into = target.baseAddress else { return }
                    cblas_scopy(Int32(count), base + index, 4, into, 1)
                }
            }
            return out
        }
        let drawnChannels = (0..<4).map { channel(drawn, $0) }
        let bareChannels = (0..<4).map { channel(bare, $0) }
        // The coverage from the alpha, where the ground lets some through.
        let seeThrough = vDSP.add(255, vDSP.multiply(-1, bareChannels[3]))
        let byAlpha = vDSP.clip(
            vDSP.multiply(255, vDSP.divide(vDSP.subtract(drawnChannels[3], bareChannels[3]), vDSP.clip(seeThrough, to: 1...255))),
            to: 0...255
        )
        // The coverage from the colour, where the ground is opaque: the
        // largest channel of how far the pixel moved, over how far the ink
        // is.
        var moved = [Float](repeating: 0, count: count)
        var reach = [Float](repeating: 24, count: count)
        for index in 0..<3 {
            moved = vDSP.maximum(moved, vDSP.absolute(vDSP.subtract(drawnChannels[index], bareChannels[index])))
            reach = vDSP.maximum(reach, vDSP.absolute(vDSP.add(-ink[index], bareChannels[index])))
        }
        let byColour = vDSP.clip(vDSP.multiply(255, vDSP.divide(moved, reach)), to: 0...255)
        // The alpha's answer from a tenth see-through up, the colour's below.
        let trust = vDSP.clip(vDSP.multiply(1 / 25, vDSP.add(-25, seeThrough)), to: 0...1)
        let coverage = vDSP.add(byColour, vDSP.multiply(trust, vDSP.subtract(byAlpha, byColour)))
        var out = [Float](repeating: 0, count: count * 4)
        for index in 0..<4 {
            let value: [Float]
            if index == 3 {
                value = coverage
            } else {
                // ink = whole − (1 − coverage) · ground, never past the coverage.
                let under = vDSP.multiply(1 / 255, vDSP.multiply(vDSP.add(255, vDSP.multiply(-1, coverage)), bareChannels[index]))
                value = vDSP.minimum(vDSP.clip(vDSP.subtract(drawnChannels[index], under), to: 0...255), coverage)
            }
            value.withUnsafeBufferPointer { source in
                out.withUnsafeMutableBufferPointer { target in
                    guard let base = source.baseAddress, let into = target.baseAddress else { return }
                    cblas_scopy(Int32(count), base, 1, into + index, 4)
                }
            }
        }
        let bytes: [UInt8] = vDSP.floatingPointToInteger(out, integerType: UInt8.self, rounding: .towardNearestInteger)
        return image(bytes, width: width, height: height)
    }

    /// `image` blurred by about `radius` pixels (a Gaussian's sigma): two
    /// tent passes, on the CPU.
    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
        guard radius > 0.5 else { return image }
        let width = image.width
        let height = image.height
        guard var source = pixels(image, width: width, height: height) else { return image }
        var target = [UInt8](repeating: 0, count: source.count)
        // A tent `side` wide has a sigma of side/√24; two passes add in
        // squares.
        let side = UInt32(Int(radius / 2.squareRoot() * 24.squareRoot()) | 1)
        var clear: [UInt8] = [0, 0, 0, 0]
        let done = source.withUnsafeMutableBytes { source in
            target.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                let flags = vImage_Flags(kvImageBackgroundColorFill)
                guard vImageTentConvolve_ARGB8888(&input, &output, nil, 0, 0, side, side, &clear, flags) == kvImageNoError
                else { return false }
                return vImageTentConvolve_ARGB8888(&output, &input, nil, 0, 0, side, side, &clear, flags) == kvImageNoError
            }
        }
        guard done else { return image }
        return self.image(source, width: width, height: height) ?? image
    }

    /// How far a spring of `duration` and `bounce` — the model behind
    /// `UIView.animate(springDuration:bounce:)` — has gone at `time`, 0 → 1,
    /// so the drawn sizes follow the resize UIKit runs.
    static func springProgress(at time: TimeInterval, duration: TimeInterval, bounce: CGFloat) -> CGFloat {
        guard time > 0 else { return 0 }
        guard time < duration else { return 1 }
        let omega = 2 * Double.pi / duration
        let zeta = Double(1 - bounce)
        let t = time
        if zeta >= 1 {
            return CGFloat(1 - exp(-omega * t) * (1 + omega * t))
        }
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        return CGFloat(1 - decay * (cos(damped * t) + zeta * omega / damped * sin(damped * t)))
    }

    /// 0 before `from`, 1 after `to`, a smooth S between.
    static func smoothstep(_ x: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        let t = min(max((x - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One keyframe animation over `duration`, linear between its values.
    static func keyframes(_ keyPath: String, _ values: [Any], duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }

    // MARK: - Pixels

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// A premultiplied RGBA bitmap, 8 bits a channel.
    private static func bitmap(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = bitmap(width: width, height: height, data: buffer.baseAddress) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { buffer in
            bitmap(width: width, height: height, data: buffer.baseAddress)?.makeImage()
        }
    }
}
