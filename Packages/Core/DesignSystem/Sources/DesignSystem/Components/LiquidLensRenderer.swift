import Metal
import QuartzCore
import UIKit

/// The selection pill's Liquid Glass lens, drawn by one Metal fragment shader
/// over a signed distance field of the lens capsule — ported from the
/// owner's `liquidglass` prototype (`LiquidSegmentedControl`), which
/// reverse-engineered iOS 27's `UISegmentedControl` lens (#1748).
///
/// What a frame draws, inside the capsule only:
/// - the pill's resting fill, fading out as the lens lifts;
/// - the native lens's rim, measured to the pixel on a flat background: a
///   dark hairline all round, a light line just inside it, a faint ring
///   shadow under the top edge and a light band along the bottom;
/// - the bar's titles REDRAWN inside the lens (`overlay`, captured from the
///   segment row), magnified about its centre like the tab bar's lens,
///   pushed outward near the rim the way the native portal is (amplitude
///   17.5pt over 11.2pt), with a spectral fringe at a fixed angle (2.316pt
///   at −15°, over an 8.8pt band);
/// - a whisper of shadow outside.
///
/// ⚠️ **NO BACKDROP.** The prototype samples a snapshot of what lies behind
/// its control; here the bar sits on live glass over moving pages, and a
/// snapshot of the page behind costs 26–280 ms on For You's grid and goes
/// stale as the pages scroll (spike #182, v13). The lens interior is
/// transparent instead, so the host's own glass shows through it live — the
/// native segmented control's lens shows its background raw too.
///
/// ⚠️ **Compiled from source at run time**: no `.metal` file in the Swift
/// package, so the build needs no Metal Toolchain (CI runs Xcode 26). Once
/// per process, off the main thread; the OS caches the compile across
/// launches. Until it has finished, the bar keeps its flat pill.
@MainActor
final class LiquidLensRenderer {
    static let shared = LiquidLensRenderer()

    /// One frame's inputs. ⚠️ ALL `Float`, in the exact order of the Metal
    /// struct: a struct of scalars has no padding in either language, which a
    /// mix of `SIMD2` and scalars cannot promise.
    struct Uniforms {
        /// The drawable, in pixels.
        var viewWidth: Float = 0
        var viewHeight: Float = 0
        var scale: Float = 1
        /// The lens capsule: centre and half extents, in drawable pixels.
        var centreX: Float = 0
        var centreY: Float = 0
        var halfWidth: Float = 0
        var halfHeight: Float = 0
        /// The resting fill, straight (not premultiplied) RGB plus its alpha.
        var tintR: Float = 0
        var tintG: Float = 0
        var tintB: Float = 0
        var tintA: Float = 0
        /// 0…1: how much of the measured rim is drawn.
        var outline: Float = 0
        /// The titles' texture, and where this view's origin sits in it (px).
        var overlayEnabled: Float = 0
        var overlayWidth: Float = 1
        var overlayHeight: Float = 1
        var overlayOriginX: Float = 0
        var overlayOriginY: Float = 0
        /// The portal's push near the rim (px) and how far in it reaches (px).
        var overlayAmount: Float = 0
        var overlayReach: Float = 1
        /// The titles' magnification about the lens's centre (1 = none).
        var magnification: Float = 1
        /// Titles points per glass point: the host's live scale (see
        /// `SelectorLiquidLens.drawGlass`).
        var overlayScale: Float = 1
        /// The iridescent rim — a thin-film sheen along the edge whose hue
        /// turns around the lens, soft and translucent: strength (0…1) and
        /// the band's width (px).
        var iridescence: Float = 0
        var iridescenceWidth: Float = 1
        /// The brightness the titles are assumed to sit on (the bar's glass:
        /// ~1 light, ~0.1 dark), so a fringe can be COLOURED with no backdrop
        /// — black text split per channel has no colour of its own.
        var backdropLuma: Float = 1
        /// The bevel's lighting — what makes the lens read as a piece of
        /// glass with volume rather than a flat ring: strength (0…1) and the
        /// bevel's width (px). The prototype's two lobes, fresnel and edge line.
        var bevel: Float = 0
        var bevelWidth: Float = 1
        /// How dark the bevel's side away from the light gets.
        var bevelShade: Float = 0.12
        /// The light crescent inside the top of the lens (the native lens's
        /// inner reflection): strength (0…1) and depth (px).
        var topBand: Float = 0
        var topBandDepth: Float = 1
        /// The host capsule as shown (px), and how fully the lens frosts the
        /// ring between its own rim and that capsule's edge (0…1): through a
        /// clear lens the capsule's edge read as a second bubble.
        var capsuleCentreX: Float = 0
        var capsuleCentreY: Float = 0
        var capsuleHalfWidth: Float = 0
        var capsuleHalfHeight: Float = 0
        var capsuleCover: Float = 0
        /// The native lens's key/fill highlight (`CASDFKeyFillHighlightEffect`,
        /// read off the live tab bar lens): a key light on the rim facing UP
        /// and a fill light facing DOWN, each over `keySpread` radians, a thin
        /// line `keyHeight` px deep, plus a diffuse glow `diffuseHeight` px
        /// deep at `diffuseAmount`, over a narrower `diffuseSpread`.
        var keyAmount: Float = 0
        var fillAmount: Float = 0
        var keySpread: Float = 1
        var keyHeight: Float = 1
        var diffuseHeight: Float = 1
        var diffuseAmount: Float = 0
        var diffuseSpread: Float = 1
        /// The page refracted in over the bar near the rim (the native lens's
        /// backdrop displacement, which we cannot sample): the page's colour,
        /// strength (0…1), the pull at the rim and its reach (px), and the
        /// per-channel split at the page/bar boundary (px).
        var pageR: Float = 1
        var pageG: Float = 1
        var pageB: Float = 1
        var pageRefraction: Float = 0
        var refractAmount: Float = 0
        var refractHeight: Float = 1
        var refractSplit: Float = 0
        /// The spectral fringe: amplitude (px), direction, band (px).
        var aberrationAmount: Float = 0
        var aberrationDirX: Float = 1
        var aberrationDirY: Float = 0
        var aberrationWidth: Float = 1
        /// The drop shadow outside the lens.
        var shadowOpacity: Float = 0
        var shadowRadius: Float = 1
        var shadowOffsetY: Float = 0
        /// The rasterised quad (px): the lens plus its shadow.
        var quadMinX: Float = 0
        var quadMinY: Float = 0
        var quadMaxX: Float = 0
        var quadMaxY: Float = 0
    }

    /// Metal's objects are not `Sendable` to the compiler; they are immutable
    /// once built, and built once, on one background thread.
    private struct Compiled: @unchecked Sendable { let pipeline: MTLRenderPipelineState }
    private struct DeviceBox: @unchecked Sendable { let device: MTLDevice }

    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var compile: Task<Void, Never>?
    /// A 1×1 transparent texture, so the shader never samples nil.
    private lazy var emptyTexture: MTLTexture? = makeTexture(width: 1, height: 1)

    /// Whether a frame can be rendered now.
    var isReady: Bool { pipeline != nil }

    private init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
    }

    /// Compiles the shader, once, off the main thread. Safe to call at every
    /// bar's birth; the first lift renders glass as soon as it has finished.
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
            descriptor.label = "LiquidLens"
            descriptor.vertexFunction = library.makeFunction(name: "liquid_lens_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "liquid_lens_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return Compiled(pipeline: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            #if DEBUG
            print("[LiquidLens] shader failed to compile: \(error)")
            #endif
            return nil
        }
    }

    // MARK: Textures

    /// A BGRA texture filled with `replace(region:)`.
    func makeTexture(width: Int, height: Int) -> MTLTexture? {
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
    /// once the command buffer is scheduled, so the lens lands in the same
    /// Core Animation commit as the mask that cuts the real titles out under
    /// it — otherwise the two swim a frame apart (spike #182).
    @discardableResult
    func render(into layer: CAMetalLayer, uniforms: Uniforms, overlay: MTLTexture?) -> Bool {
        guard let pipeline, let queue,
              layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return false }
        guard encode(into: drawable.texture, uniforms: uniforms, overlay: overlay,
                     pipeline: pipeline, buffer: buffer) else { return false }
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
    func render(into target: MTLTexture, uniforms: Uniforms, overlay: MTLTexture?) -> Bool {
        guard let pipeline, let queue, let buffer = queue.makeCommandBuffer() else { return false }
        guard encode(into: target, uniforms: uniforms, overlay: overlay, pipeline: pipeline, buffer: buffer) else { return false }
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.error == nil
    }

    /// A BGRA render target a test can read back.
    func makeTarget(width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
    #endif

    private func encode(into target: MTLTexture, uniforms: Uniforms, overlay: MTLTexture?,
                        pipeline: MTLRenderPipelineState, buffer: MTLCommandBuffer) -> Bool {
        guard let fallback = emptyTexture else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(overlay ?? fallback, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    // MARK: The shader

    /// The prototype's `lg_fragment`, cut down to what the selector's lens
    /// uses: one capsule, no backdrop, no content transition. The rim and the
    /// portal follow its measured profile line for line; "darken by x" and
    /// "lighten by x" become black and white composited OVER at alpha x,
    /// because with no backdrop there is nothing underneath to multiply.
    nonisolated static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float viewWidth, viewHeight, scale;
        float centreX, centreY, halfWidth, halfHeight;
        float tintR, tintG, tintB, tintA;
        float outline;
        float overlayEnabled, overlayWidth, overlayHeight, overlayOriginX, overlayOriginY;
        float overlayAmount, overlayReach, magnification, overlayScale;
        float iridescence, iridescenceWidth, backdropLuma;
        float bevel, bevelWidth, bevelShade, topBand, topBandDepth;
        float capsuleCentreX, capsuleCentreY, capsuleHalfWidth, capsuleHalfHeight, capsuleCover;
        float keyAmount, fillAmount, keySpread, keyHeight, diffuseHeight, diffuseAmount, diffuseSpread;
        float pageR, pageG, pageB, pageRefraction, refractAmount, refractHeight, refractSplit;
        float aberrationAmount, aberrationDirX, aberrationDirY, aberrationWidth;
        float shadowOpacity, shadowRadius, shadowOffsetY;
        float quadMinX, quadMinY, quadMaxX, quadMaxY;
    };

    struct Varyings { float4 position [[position]]; };

    vertex Varyings liquid_lens_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corner = float2(vid & 1, (vid >> 1) & 1);
        float2 px = mix(float2(u.quadMinX, u.quadMinY), float2(u.quadMaxX, u.quadMaxY), corner);
        float2 ndc = px / float2(u.viewWidth, u.viewHeight) * 2.0 - 1.0;
        ndc.y = -ndc.y;
        Varyings o;
        o.position = float4(ndc, 0.0, 1.0);
        return o;
    }

    static inline float lensSDF(float2 p, constant Uniforms &u) {
        float2 b = float2(u.halfWidth, u.halfHeight);
        float r = min(b.x, b.y);
        float2 q = abs(p - float2(u.centreX, u.centreY)) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    static inline float capsuleSDF(float2 p, constant Uniforms &u) {
        float2 b = float2(u.capsuleHalfWidth, u.capsuleHalfHeight);
        float r = min(b.x, b.y);
        float2 q = abs(p - float2(u.capsuleCentreX, u.capsuleCentreY)) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    static inline float4 over(float4 c, float3 rgb, float a) {
        return float4(c.rgb * (1.0 - a) + rgb * a, c.a + a * (1.0 - c.a));
    }

    fragment float4 liquid_lens_fragment(Varyings in [[stage_in]],
                                         constant Uniforms &u [[buffer(0)]],
                                         texture2d<float> overlay [[texture(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_zero);
        const float2 p = in.position.xy;
        const float d = lensSDF(p, u);

        float shadow = 0.0;
        if (u.shadowOpacity > 0.0 && d > -1.0) {
            float ds = lensSDF(p - float2(0.0, u.shadowOffsetY), u);
            float s = 1.0 - smoothstep(0.0, max(u.shadowRadius, 1.0), ds);
            shadow = u.shadowOpacity * s * s;
        }
        const float aa = 0.75;
        if (d > aa && shadow <= 0.002) { return float4(0.0); }

        // The outward normal: the SDF's gradient.
        float2 g = float2(lensSDF(p + float2(1, 0), u) - lensSDF(p - float2(1, 0), u),
                          lensSDF(p + float2(0, 1), u) - lensSDF(p - float2(0, 1), u));
        float2 n2 = normalize(g + float2(1e-5, 0.0));

        // The resting fill, premultiplied.
        float4 c = float4(float3(u.tintR, u.tintG, u.tintB) * u.tintA, u.tintA);

        // The page, refracted in over the bar near the rim — what the native
        // lens's backdrop `displacementMap` does (amount 9 over an SDF 36pt
        // high, plus `glassBackground`'s inner refraction −10.5 over 7pt),
        // measured on a black page: the page shows ~3pt in past the bar's
        // edge, split into a rainbow at that boundary. We cannot sample the
        // page; we know where the capsule is and the page is the system
        // background, so where the refracted ray leaves the capsule the page
        // colour is painted, one coverage per channel for the fringe. Only
        // OVER the capsule: the ring past it is left clear, so media under it
        // still shows.
        if (u.pageRefraction > 0.0 && u.capsuleHalfWidth > 0.0 && capsuleSDF(p, u) < 0.0) {
            float dd = max(-d, 0.0);
            float pull = 1.0 - smoothstep(0.0, max(u.refractHeight, 1.0), dd);
            float3 cover;
            for (int k = 0; k < 3; ++k) {
                // VERTICAL only, scaled by how much the rim faces up or down:
                // along the full normal the rounded ends pulled the page in
                // diagonally and the bar's edge bent DOWN the sides, following
                // the rim (converging); the native's bends UP to meet the rim
                // at the ends (diverging) — owner, from the lab frames.
                float2 sp = p + float2(0.0, n2.y) * (u.refractAmount + u.refractSplit * float(k - 1)) * pull;
                cover[k] = smoothstep(-0.75 * u.scale, 0.75 * u.scale, capsuleSDF(sp, u));
            }
            cover *= u.pageRefraction;
            float A = max(cover.r, max(cover.g, cover.b));
            float3 rgb = float3(u.pageR, u.pageG, u.pageB) * cover + u.backdropLuma * (A - cover);
            c = float4(c.rgb * (1.0 - A) + rgb, c.a + A * (1.0 - c.a));
        }

        // The measured rim.
        if (u.outline > 0.0) {
            float s1 = u.scale;
            float side = 1.0 - abs(n2.y);
            float darkLine = 1.0 - smoothstep(0.45 * s1, 1.0 * s1, -d);
            // ~19% on a white page, as the native tab bar lens's edge measures
            // (201–207 on 253); the segmented control's 33–38% read too dark.
            c = over(c, float3(0.0), u.outline * darkLine * (0.18 + 0.02 * side));
            float brightLine = smoothstep(0.6 * s1, 1.0 * s1, -d) * (1.0 - smoothstep(1.4 * s1, 2.1 * s1, -d));
            c = over(c, float3(1.0), u.outline * brightLine * (0.10 + 0.12 * abs(n2.y)));
            float top = u.centreY - u.halfHeight;
            float dyTop = (p.y - top) / s1;
            float bump = smoothstep(1.7, 9.0, dyTop) * (1.0 - smoothstep(9.0, 19.0, dyTop));
            // The ring shadow (`glassBackground` ringShadow: opacity 0.1, offset
            // 8, stroke 4, blur 3 — read off the native tab bar lens): a dark
            // band ~7% centred ~9pt under the top edge, gone by 19pt.
            // (Tuned to the tab bar lens's measured band: 235 on a 251 page.)
            c = over(c, float3(0.0), 0.045 * u.outline * bump);
            // And the native lens's interior darkens near its rim all round
            // (measured on a white page: ~5% for the first 8pt, fading by
            // 15pt) — the backdrop refracted inwards; it is what reads as
            // volume, with no light from any side.
            float rimShade = 1.0 - smoothstep(6.0 * s1, 15.0 * s1, -d);
            c = over(c, float3(0.0), 0.05 * u.outline * rimShade * smoothstep(0.8 * s1, 1.6 * s1, -d));
            float bottom = u.centreY + u.halfHeight;
            float dyBot = (bottom - p.y) / s1;
            float fill = pow(saturate(1.0 - dyBot / 6.0), 1.5) * smoothstep(0.6 * s1, 1.2 * s1, -d);
            c = over(c, float3(1.0), 0.10 * u.outline * fill);
        }

        // The titles, redrawn through the portal: pushed outward near the rim,
        // clamped to the lens's box (a glyph crossing the rim trails, as the
        // native portal's does), fringed along a fixed direction.
        if (u.overlayEnabled > 0.5) {
            float t2 = saturate(-d / max(u.overlayReach, 1.0));
            float2 disp = n2 * (u.overlayAmount * (1.0 - t2));
            float2 lo = float2(u.centreX - u.halfWidth, u.centreY - u.halfHeight);
            float2 hi = float2(u.centreX + u.halfWidth, u.centreY + u.halfHeight);
            float2 c0 = float2(u.centreX, u.centreY);
            float2 sp = clamp(c0 + (p - c0) / max(u.magnification, 0.01) + disp, lo, hi);
            float2 origin = float2(u.overlayOriginX, u.overlayOriginY);
            float2 size = float2(u.overlayWidth, u.overlayHeight);
            float4 oc;
            float band = 1.0 - smoothstep(0.0, max(u.aberrationWidth, 1.0), -d);
            if (u.aberrationAmount > 0.0 && band > 0.01) {
                // Along the rim's normal when no direction is given: what
                // crosses the rim splits into a rainbow across it (native).
                float2 dir = (u.aberrationDirX == 0.0 && u.aberrationDirY == 0.0) ? n2 : float2(u.aberrationDirX, u.aberrationDirY);
                float2 cd = dir * (u.aberrationAmount * band);
                float3 acc = float3(0.0), cover = float3(0.0), wsum = float3(0.0);
                for (int i = 0; i < 6; ++i) {
                    float t = (float(i) + 0.5) / 6.0;
                    float3 w = saturate(1.0 - abs(float3(t) - float3(0.0, 0.5, 1.0)) * 2.0);
                    float4 s = overlay.sample(smp, ((sp + cd * (t * 2.0 - 1.0)) * u.overlayScale + origin) / size);
                    acc += w * s.rgb;
                    cover += w * s.a;
                    wsum += w;
                }
                acc /= max(wsum, float3(1e-4));
                cover /= max(wsum, float3(1e-4));
                // Each channel has its own coverage; one output alpha cannot
                // carry three, so the channels are resolved against the
                // brightness the titles sit on: over it, channel k must read
                // text·cover_k + B·(1 − cover_k), which premultiplied at the
                // largest coverage A is text·cover_k + B·(A − cover_k).
                float A = max(cover.r, max(cover.g, cover.b));
                oc = float4(acc + u.backdropLuma * (A - cover), A);
            } else {
                oc = overlay.sample(smp, (sp * u.overlayScale + origin) / size);
            }
            c = float4(c.rgb * (1.0 - oc.a) + oc.rgb, c.a + oc.a * (1.0 - c.a));
        }

        // The bevel's light (the prototype's `lg_fragment`): a quarter-round
        // profile over `bevelWidth`, lit from the top left — a strong lobe
        // facing the light, a weak one opposite, a fresnel rise towards the
        // rim and a fine bright edge line — and a little shade on the side
        // away from the light. White and black composited over, since there
        // is no backdrop to add to.
        if (u.bevel > 0.0) {
            float t = saturate(-d / max(u.bevelWidth, 1.0));
            float ct = 1.0 - t;
            float st = sqrt(max(0.0, 1.0 - ct * ct));
            float rimBand = ct * ct * ct * ct;
            float2 L = normalize(float2(-0.6, -0.8));
            float nl = dot(n2, L);
            float lobes = 0.6 * pow(saturate(nl), 2.0) + 0.3 * pow(saturate(-nl), 3.0) + 0.08;
            float fresnel = pow(1.0 - st, 4.0);
            float edgeLine = 1.0 - smoothstep(0.0, 1.5 * u.scale, -d);
            float light = u.bevel * (rimBand * lobes * 0.8 + fresnel * 0.10 + edgeLine * 0.30);
            c = over(c, float3(1.0), saturate(light));
            float shade = u.bevelShade * u.bevel * rimBand * pow(saturate(-nl), 2.0);
            c = over(c, float3(0.0), saturate(shade));
        }

        // The ring beyond the host's capsule, frosted over with the glass's
        // own tone: the capsule's edge (and the page past it) must not show
        // through the lens as a second outline — the native lens bends it
        // away, leaving that ring a white frost.
        if (u.capsuleCover > 0.0 && u.capsuleHalfWidth > 0.0) {
            float2 cb = float2(u.capsuleHalfWidth, u.capsuleHalfHeight);
            float cr = min(cb.x, cb.y);
            float2 cq = abs(p - float2(u.capsuleCentreX, u.capsuleCentreY)) - cb + cr;
            float dc = min(max(cq.x, cq.y), 0.0) + length(max(cq, 0.0)) - cr;
            float inside = smoothstep(0.0, 1.0 * u.scale, -d);
            float beyond = smoothstep(-3.0 * u.scale, 1.5 * u.scale, dc);
            c = over(c, float3(u.backdropLuma), saturate(u.capsuleCover * inside * beyond));
        }

        // The native lens's light, as its `CASDFKeyFillHighlightEffect` is
        // configured (read on the simulator, 2026-10-26): white, a key light
        // on the part of the rim facing up and a fill light on the part facing
        // down, 80° wide each, as a thin line at the rim plus a diffuse glow
        // eight times deeper at 15% over 65% of the angle. Nothing on the
        // sides: that is the "play of light" the owner saw, not a ring.
        if (u.keyAmount > 0.0 || u.fillAmount > 0.0) {
            float dd = -d;
            float angle = atan2(n2.x, -n2.y);                 // 0 = facing up
            float halfKey = max(u.keySpread * 0.5, 0.01);
            float towardsUp = 1.0 - smoothstep(0.0, halfKey, abs(angle));
            float towardsDown = 1.0 - smoothstep(0.0, halfKey, 3.14159265 - abs(angle));
            float halfDiffuse = halfKey * u.diffuseSpread;
            float diffuseUp = 1.0 - smoothstep(0.0, halfDiffuse, abs(angle));
            float diffuseDown = 1.0 - smoothstep(0.0, halfDiffuse, 3.14159265 - abs(angle));
            float lineBand = smoothstep(-0.5, 0.5 * u.scale, dd) * (1.0 - smoothstep(0.0, max(u.keyHeight, 1.0), dd));
            float glow = smoothstep(-0.5, 0.5 * u.scale, dd) * (1.0 - smoothstep(0.0, max(u.diffuseHeight, 1.0), dd));
            float light = lineBand * (u.keyAmount * towardsUp + u.fillAmount * towardsDown)
                        + glow * u.diffuseAmount * (u.keyAmount * diffuseUp + u.fillAmount * diffuseDown);
            c = over(c, float3(1.0), saturate(light));
        }

        // The rim's LIGHT, crisp — the native tab bar lens zoomed on the
        // owner's device recording: right inside the grey outline a bright
        // white band 2–3pt wide (the specular reflection of the rim), then a
        // faint grey falloff under it that gives the glass its depth; no fog
        // anywhere, the interior stays sharp. (A soft white frost over 10pt
        // read as a BLUR, not light — owner, 2026-10-26.)
        if (u.topBand > 0.0) {
            float s1 = u.scale;
            float dd = -d;
            float highlight = smoothstep(0.7 * s1, 1.2 * s1, dd) * (1.0 - smoothstep(2.4 * s1, 3.4 * s1, dd));
            c = over(c, float3(1.0), saturate(u.topBand * highlight * 0.8));
            float falloff = smoothstep(2.6 * s1, 4.0 * s1, dd) * (1.0 - smoothstep(4.0 * s1, max(u.topBandDepth, 5.0 * s1), dd));
            c = over(c, float3(0.0), saturate(u.topBand * falloff * 0.05));
        }

        // The iridescent rim: a HAIRLINE thin-film sheen right at the edge
        // (the native tab bar lens's soap-bubble edge), its hue turning round
        // the lens, pale, composited over at low alpha.
        if (u.iridescence > 0.0) {
            float band = (1.0 - smoothstep(0.0, max(u.iridescenceWidth, 1.0), -d)) * smoothstep(-0.5, 0.5 * u.scale, -d);
            // Only on the rounded ends, where the native lens shows it.
            band *= smoothstep(0.55, 0.9, abs(n2.x));
            float2 q = p - float2(u.centreX, u.centreY);
            float aspect = max(u.halfWidth / max(u.halfHeight, 1.0), 1.0);
            float angle = atan2(q.y, q.x / aspect);
            float hue = fract(angle / 6.2831853 * 2.0 + (p.x - p.y) / (90.0 * u.scale));
            float3 rgb = saturate(abs(fract(hue + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0);
            rgb = mix(float3(1.0), rgb, 0.5);
            c = over(c, rgb, u.iridescence * band);
        }

        c = saturate(c);
        float coverage = 1.0 - smoothstep(-aa, aa, d);
        float4 o = c * coverage;
        o.a = o.a + shadow * (1.0 - o.a);
        return o;
    }
    """
}
