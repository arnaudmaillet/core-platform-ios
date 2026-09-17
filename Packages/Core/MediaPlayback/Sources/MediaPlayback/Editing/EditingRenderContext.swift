import CoreImage

/// The one Core Image context the PHOTO path renders through.
///
/// ⚠️ **ONE CONTEXT, CREATED ONCE.** A `CIContext` allocates its own GPU
/// resources, and building one per call is the documented way to make a cheap
/// render expensive. It is thread-safe by contract, so one static serves every
/// caller.
///
/// ⚠️ **NOT THE COMPOSITOR'S.** This one is colour-managed (sRGB), which is what
/// a photograph wants; `VideoCompositor.context` is deliberately unmanaged
/// because managed blending brightened its dips — measured. Unifying the two
/// would move one of them.
///
/// ⚠️ **`cacheIntermediates: false`** — a live slider renders a different graph
/// every frame, and cached intermediates would be memory spent on pictures that
/// are never asked for again.
public enum EditingRenderContext {
    public static let shared = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
}
