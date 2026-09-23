import Metal
import QuartzCore
import UIKit

/// The optics of a lifted selection lens: a copy of the bar's own strip,
/// magnified about the lens's centre, bent outward along the rim, with a
/// chromatic fringe and a touch of blur where it bends — what the native tab
/// bar's private `_UILiquidLensView` does with a portal, a signed-distance
/// field and a `displacementMap` filter, done here with one Metal fragment
/// shader over a bitmap of the strip (`SelectorGlassLens` captures it).
///
/// ⚠️ **A SPIKE, behind `-selector-glass-lens`.** Chosen over Core Image on a
/// bench of the same shader on both (Metal: a third of the per-frame cost,
/// half the first-ever compile, and no `CIContext` beside the editor's); the
/// built-in `CIGlassLozenge` was ruled out on sight (a dark seam around the
/// lozenge). The shader is compiled from source at run time — no `.metal`
/// file in the package, nothing for the build to learn — once per process,
/// off the main thread, and the OS caches the compile across launches.
///
/// One per process: every lens shares the device, the queue and the pipeline,
/// and owns its own source texture. `-selector-glass-lens-optics-off` keeps
/// the glass pill without the copy; `-lens-mag 1.18 -lens-edge 14 -lens-bend
/// 10 -lens-ca 0.3 -lens-blur 1.5` retune the optics while filming against
/// the native bar.
@MainActor
final class LensRefractor {
    static let shared = LensRefractor()
    static let isSwitchedOff = ProcessInfo.processInfo.arguments.contains("-selector-glass-lens-optics-off")

    /// The lens's optics, in points — scaled to pixels at render time.
    struct Optics: Sendable {
        /// How much larger the strip reads through the lens's middle.
        var magnification: Float
        /// How far in from the rim the bend reaches.
        var edge: Float
        /// How far outward the rim pulls the strip, at the rim itself.
        var bend: Float
        /// The red/blue split of the bend, as a fraction of it.
        var aberration: Float
        /// The blur along the bend, at the rim.
        var blur: Float
        /// The strip captured beyond the lens on every side, for the bend and
        /// the magnification to sample into.
        static let captureMargin: CGFloat = 24

        /// Cut against the native tab bar's lens, filmed and measured on the
        /// same simulator: its held item reads 1.13–1.15× its resting size
        /// (text 108 → 124 px, glyph 64 → 72 px), and the neighbouring item's
        /// edge shows inside the rim, pulled in a little.
        static let standard = Optics(magnification: 1.15, edge: 14, bend: 6, aberration: 0.4, blur: 0.5)

        /// `standard`, with any `-lens-…` launch argument over it.
        static func fromArguments() -> Optics {
            let defaults = UserDefaults.standard
            func value(_ key: String, _ fallback: Float) -> Float {
                let read = defaults.double(forKey: key)
                return read > 0 ? Float(read) : fallback
            }
            var optics = standard
            optics.magnification = value("lens-mag", optics.magnification)
            optics.edge = value("lens-edge", optics.edge)
            optics.bend = value("lens-bend", optics.bend)
            optics.aberration = value("lens-ca", optics.aberration)
            optics.blur = value("lens-blur", optics.blur)
            return optics
        }
    }

    /// What one frame of the shader needs. Laid out as the Metal struct is:
    /// five float2, then five floats, padded to a multiple of 8 bytes.
    struct Uniforms {
        /// The output, in pixels.
        var size: SIMD2<Float>
        /// The lens's centre and half extents, in output pixels (`half` is a Metal type name).
        var centre: SIMD2<Float>
        var halfExtent: SIMD2<Float>
        /// Output pixel → source pixel: the source is the lens's box plus a
        /// margin, so the offset is that margin.
        var sourceOffset: SIMD2<Float>
        var sourceSize: SIMD2<Float>
        var magnification: Float
        var edge: Float
        var bend: Float
        var aberration: Float
        var blur: Float
        private var padding: SIMD3<Float> = .zero

        init(size: SIMD2<Float>, centre: SIMD2<Float>, halfExtent: SIMD2<Float>,
             sourceOffset: SIMD2<Float>, sourceSize: SIMD2<Float>,
             magnification: Float, edge: Float, bend: Float, aberration: Float, blur: Float) {
            self.size = size
            self.centre = centre
            self.halfExtent = halfExtent
            self.sourceOffset = sourceOffset
            self.sourceSize = sourceSize
            self.magnification = magnification
            self.edge = edge
            self.bend = bend
            self.aberration = aberration
            self.blur = blur
        }
    }

    /// Metal's objects are not `Sendable` to the compiler; they are immutable
    /// once built, and built once, on one background thread.
    private struct Compiled: @unchecked Sendable {
        let pipeline: MTLRenderPipelineState
    }

    private struct DeviceBox: @unchecked Sendable {
        let device: MTLDevice
    }

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var compile: Task<Void, Never>?

    /// Whether a frame can be rendered now.
    var isReady: Bool { pipeline != nil }

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    /// Compiles the shader, once, off the main thread. Safe to call at every
    /// bar's birth; the first lift renders as soon as it has finished.
    func prepare() {
        guard pipeline == nil, compile == nil, let device else { return }
        let box = DeviceBox(device: device)
        compile = Task { @MainActor [weak self] in
            let compiled = await Task.detached(priority: .userInitiated) { Self.compile(on: box.device) }.value
            self?.pipeline = compiled?.pipeline
            self?.compile = nil
        }
    }

    /// Waits for `prepare()` — a test has no frame to wait on.
    func ready() async {
        prepare()
        await compile?.value
    }

    private nonisolated static func compile(on device: MTLDevice) -> Compiled? {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "selector_lens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "selector_lens_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return Compiled(pipeline: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            #if DEBUG
            print("[LensRefractor] shader failed to compile: \(error)")
            #endif
            return nil
        }
    }

    // MARK: Textures

    /// A BGRA source texture the lens fills with `replace(region:)`.
    func makeSourceTexture(width: Int, height: Int) -> MTLTexture? {
        guard let device, width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Rendering

    /// One frame into the layer's next drawable. With
    /// `presentsWithTransaction` the drawable is presented from this thread
    /// after the command buffer is scheduled, so the copy lands in the same
    /// Core Animation commit as the lens's frame — otherwise it swims one
    /// frame behind the spring.
    @discardableResult
    func render(source: MTLTexture, into layer: CAMetalLayer, uniforms: Uniforms) -> Bool {
        guard let pipeline, let queue,
              layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return false }
        guard encode(source: source, into: drawable.texture, uniforms: uniforms, pipeline: pipeline, buffer: buffer) else { return false }
        if layer.presentsWithTransaction {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
        return true
    }

    #if DEBUG
    /// One frame into a texture, waited for — a test's way of reading the
    /// shader's output.
    func render(source: MTLTexture, into target: MTLTexture, uniforms: Uniforms) -> Bool {
        guard let pipeline, let queue, let buffer = queue.makeCommandBuffer() else { return false }
        guard encode(source: source, into: target, uniforms: uniforms, pipeline: pipeline, buffer: buffer) else { return false }
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.error == nil
    }

    /// A BGRA render target for `render(source:into:uniforms:)`.
    func makeTargetTexture(width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
    #endif

    private func encode(source: MTLTexture, into target: MTLTexture, uniforms: Uniforms,
                        pipeline: MTLRenderPipelineState, buffer: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    // MARK: The shader

    /// A full-screen triangle, then per pixel: the capsule's signed distance
    /// decides in or out; inside, the source is read magnified about the
    /// centre, pulled outward along the capsule's normal by a bend that
    /// falls off quadratically from the rim, split per channel for the
    /// fringe, and averaged along that normal for the blur. Premultiplied in
    /// and out; the edge is antialiased over one pixel.
    private nonisolated static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varyings { float4 position [[position]]; };

    vertex Varyings selector_lens_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id == 2) ? 3.0 : -1.0, (id == 1) ? 3.0 : -1.0);
        Varyings out; out.position = float4(p, 0.0, 1.0); return out;
    }

    struct Uniforms {
        float2 size; float2 centre; float2 halfExtent; float2 sourceOffset; float2 sourceSize;
        float magnification; float edge; float bend; float aberration; float blur; float3 padding;
    };

    // Signed distance to the capsule, negative inside, and the outward normal.
    static float capsuleDistance(float2 p, constant Uniforms& u, thread float2& normal) {
        float r = min(u.halfExtent.x, u.halfExtent.y);
        float2 q = p - u.centre;
        float2 k = max(abs(q) - (u.halfExtent - r), 0.0);
        normal = normalize(k * sign(q) + float2(1e-4, 0.0));
        return length(k) - r;
    }

    fragment float4 selector_lens_fragment(Varyings in [[stage_in]],
                                           texture2d<float> source [[texture(0)]],
                                           constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float2 p = in.position.xy;
        float2 n;
        float d = capsuleDistance(p, u, n);
        if (d > 0.5) return float4(0.0);
        float cover = clamp(0.5 - d, 0.0, 1.0);
        float t = 1.0 - smoothstep(0.0, u.edge, -d);            // 1 at the rim, 0 inside
        float2 base = u.centre + (p - u.centre) / u.magnification;
        float2 pull = n * u.bend * t * t;
        float2 step = n * u.blur * t;
        float4 sum = float4(0.0);
        for (int i = -2; i <= 2; i++) {
            float w = (i == 0) ? 0.4 : ((abs(i) == 1) ? 0.2 : 0.1);
            float2 s = base + pull + step * float(i);
            float4 g = source.sample(linear, (s + u.sourceOffset) / u.sourceSize);
            float r = source.sample(linear, (s + pull * u.aberration + u.sourceOffset) / u.sourceSize).r;
            float b = source.sample(linear, (s - pull * u.aberration + u.sourceOffset) / u.sourceSize).b;
            sum += w * float4(min(r, g.a), g.g, min(b, g.a), g.a);
        }
        return sum * cover;
    }
    """
}
