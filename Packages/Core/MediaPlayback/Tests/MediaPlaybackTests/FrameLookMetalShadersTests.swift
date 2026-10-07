import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MetalPerformanceShaders
import ObjectiveC
import Testing
@testable import MediaPlayback

/// **NO LOOK IS EVER DRAWN THROUGH METAL PERFORMANCE SHADERS (#623).**
///
/// Core Image hands a few filters to MPS — a `CIGaussianBlur` of about 0.4
/// to 1.1 pixels becomes an `MPSImageConvolution` — and MPS asserts, taking
/// the process down, when Core Image hands it a nil input texture under
/// memory pressure. Nothing a look draws may go that way: see
/// `FrameLookRenderer.blurRadiusFloor`.
///
/// ⚠️ **READ FROM MPS ITSELF, NOT FROM THE RADIUS.** Which filters and radii
/// Core Image sends to MPS is its own business and moves between OS
/// versions; the floor is only right while no MPS kernel is made. So the
/// test counts what MPS encodes, through a hook on `MPSUnaryImageKernel`,
/// and proves the hook sees a convolution first.
///
/// ⚠️ **SERIALIZED**: the count is the process's, so the witness drawn for
/// one surface must not land inside the other's measurement.
@Suite(.serialized)
struct FrameLookMetalShadersTests {
    @Test(arguments: LookSurface.allCases)
    func noLookReachesMetalPerformanceShaders(_ surface: LookSurface) {
        #expect(MPSKernelCount.installed, "guard: the hook is in place")
        let before = MPSKernelCount.value
        _ = surface.draw(convolved(TestPicture.detailed()))
        #expect(MPSKernelCount.value > before, "guard: a 3×3 convolution is drawn by MPS, so the hook sees it")

        // Every effect, from a hair above zero to whole, on a picture the
        // size of a test fixture, an effect card, and a preview.
        let pictures = [
            TestPicture.detailed(width: 40, height: 30),
            TestPicture.detailed(width: 120, height: 120),
            TestPicture.detailed(width: 1280, height: 720),
        ]
        var reached: [String] = []
        for picture in pictures {
            for kind in LookEffectKind.allCases {
                for intensity in [LookAdjustments.snap + 0.001, 0.01, 0.03, 0.1, 0.5, 1] {
                    let look = FrameLook(effect: LookEffect(kind: kind, intensity: intensity))
                    let start = MPSKernelCount.value
                    _ = surface.draw(FrameLookRenderer.apply(look, to: picture, time: 0))
                    if MPSKernelCount.value > start {
                        reached.append("\(kind) at \(intensity) on \(Int(picture.extent.width))")
                    }
                }
            }
            var finishing = FrameLook()
            finishing.adjustments.sharpness = 1
            finishing.adjustments.vignette = 1
            finishing.adjustments.grain = 1
            let start = MPSKernelCount.value
            _ = surface.draw(FrameLookRenderer.apply(finishing, to: picture, time: 0))
            if MPSKernelCount.value > start {
                reached.append("the finishing dials on \(Int(picture.extent.width))")
            }
        }
        #expect(reached.isEmpty, "drawn through MPS: \(reached)")
    }

    /// The blur that took the Upload test process down: the effect cards
    /// dressing a 40×30 picture, at full strength, asked for 0.9 pixels.
    @Test func theFixtureSizedBlurIsRaisedToTheFloor() {
        let short = 30.0
        #expect(1 * 0.03 * short < FrameLookRenderer.blurRadiusFloor, "guard: the recipe alone asks for less")
        #expect(FrameLookRenderer.blurRadiusFloor > 1.15, "the floor sits above the measured MPS band")
        #expect(FrameLookRenderer.blurRadiusFloor < FrameLookRenderer.blurDownsamplesAbove)
    }

    /// No source at all: a picture with no extent comes back as it is, and
    /// nothing is drawn from it.
    @Test func aPictureWithNothingInItIsReturnedAsItIs() {
        let look = FrameLook(effect: LookEffect(kind: .blur, intensity: 1))
        let empty = CIImage.empty()
        let infinite = CIImage(color: .red)

        #expect(FrameLookRenderer.apply(look, to: empty, time: 0) === empty)
        #expect(FrameLookRenderer.apply(look, to: infinite, time: 0) === infinite)
    }

    private func convolved(_ picture: CIImage) -> CIImage {
        let filter = CIFilter.convolution3X3()
        filter.inputImage = picture
        filter.weights = CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9)
        return (filter.outputImage ?? picture).cropped(to: picture.extent)
    }
}

/// How many times the process has encoded an MPS image kernel onto a
/// texture, counted by a hook on `-[MPSUnaryImageKernel
/// encodeToCommandEncoder:commandBuffer:sourceTexture:destinationTexture:]`
/// — where every texture encode ends (measured: `CIConvolutionProcessor`
/// calls the command-buffer spelling, which calls this one). Encodes, not
/// initialisations, so a kernel Core Image kept from an earlier render still
/// counts. Installed once, for the process; the original still runs.
private enum MPSKernelCount {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var value: Int {
        _ = installed
        return lock.withLock { count }
    }

    static let installed: Bool = {
        typealias Encode = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void
        let selector = NSSelectorFromString("encodeToCommandEncoder:commandBuffer:sourceTexture:destinationTexture:")
        guard let kernel = NSClassFromString("MPSUnaryImageKernel"),
              let method = class_getInstanceMethod(kernel, selector)
        else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Encode.self)
        let counting: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void = {
            kernel, encoder, buffer, source, destination in
            lock.withLock { count += 1 }
            original(kernel, selector, encoder, buffer, source, destination)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
        return true
    }()
}
