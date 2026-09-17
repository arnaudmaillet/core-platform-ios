import CoreImage
import CoreImage.CIFilterBuiltins

/// Puts a `FrameLook` through a picture, as a Core Image graph.
///
/// ⚠️ **IT BUILDS A GRAPH AND RENDERS NOTHING.** The photo path renders once at
/// the end of crop → look → overlays, and the compositor renders once into its
/// output buffer; a renderer that drew its own result would cost a round trip
/// per stage.
///
/// ⚠️ **A NEW `CIFilter` ON EVERY CALL.** `CIFilter` is not `Sendable` (`CIImage`
/// and `CIContext` are), and this runs on the main actor's detached renders and
/// on the compositor's queue alike. A filter kept in a static would be shared
/// state with no lock.
///
/// ⚠️ **COLOUR-MANAGED OR NOT IS THE CALLER'S CONTEXT'S BUSINESS.** The photo
/// path renders through a managed sRGB context and the compositor through an
/// unmanaged BT.709 one (see `VideoCompositor.context`); a graph is only
/// `CIImage -> CIImage` and runs under both, which is why parity between the two
/// is measured with a tolerance.
public enum FrameLookRenderer {
    /// `image` wearing `look`, at `time` seconds (time-based stages such as
    /// grain move with it; a photograph passes 0).
    ///
    /// A neutral look returns `image` itself — the same object — and each stage
    /// is skipped while its part of the look is neutral.
    ///
    /// ⚠️ **ONLY THE PRESET IS DRAWN YET.** The adjustments, the effect,
    /// sharpness, vignette and grain are the look pipeline's slice (S1) to fill,
    /// in the order the type comment of `FrameLook` states, each cropped back to
    /// the input's extent. Until then those parts of a look pass through
    /// unchanged — which nothing can notice, because no screen sets them yet.
    public static func apply(_ look: FrameLook, to image: CIImage, time: Double) -> CIImage {
        guard !look.isNeutral else { return image }
        return preset(look.preset, on: image)
    }

    /// The preset stage: one of Apple's `CIPhotoEffect` looks, or the picture
    /// itself for `.original`.
    ///
    /// ⚠️ **THE TYPED SPELLINGS, NOT `CIFilter(name:)`.** The eight names were
    /// read out of this SDK's `CIFilterBuiltins.h`; a string turns a typo into a
    /// crash at run time.
    private static func preset(_ preset: LookPreset, on image: CIImage) -> CIImage {
        let filter: (CIFilter & CIPhotoEffect)?
        switch preset {
        case .original: filter = nil
        case .chrome: filter = CIFilter.photoEffectChrome()
        case .fade: filter = CIFilter.photoEffectFade()
        case .instant: filter = CIFilter.photoEffectInstant()
        case .mono: filter = CIFilter.photoEffectMono()
        case .noir: filter = CIFilter.photoEffectNoir()
        case .process: filter = CIFilter.photoEffectProcess()
        case .tonal: filter = CIFilter.photoEffectTonal()
        case .transfer: filter = CIFilter.photoEffectTransfer()
        }
        guard let filter else { return image }
        filter.inputImage = image
        return filter.outputImage ?? image
    }
}
