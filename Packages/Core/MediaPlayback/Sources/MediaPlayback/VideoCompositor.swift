import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo

/// What one stretch of an arrangement draws.
///
/// ⚠️ **A VALUE, SO IT CAN BE TESTED WITHOUT A COMPOSITOR.** Everything the
/// compositor decides is in here and in `VideoCompositor.draw`, which takes
/// `CIImage`s and a time: the pixels a test reads come from the same function
/// the export and the preview call.
///
/// ⚠️ **ONE STRETCH NEVER SPANS TWO PIECES** — each piece may wear its own
/// look, and a stretch has one per lane (`VideoExporter.composed` splits at
/// every piece boundary).
struct VideoCompositionScene: Sendable, Equatable {
    /// Turns a source frame upright and puts it at the origin — in Core Image's
    /// y-up space, already converted from the track's y-down transform, and
    /// already shrunk to `uprightSize`.
    var orientation: CGAffineTransform
    /// The upright picture the lanes are drawn and blended on, before the crop.
    var uprightSize: CGSize
    /// What is rendered: the kept part of the upright picture, which is
    /// `uprightSize` itself when nothing is cropped.
    var renderSize: CGSize
    /// The transition this stretch belongs to, if any.
    var transition: Transition?
    /// The look each lane's piece wears, before any transition blends them.
    var looks = Looks()
    /// What is drawn over the finished film: the crop, the whole look and the
    /// overlays.
    var finish = FrameFinish.none

    /// Which piece's look each lane wears.
    ///
    /// ⚠️ **THE LANES SWAP PIECES AT THE CUT, SO THEIR LOOKS SWAP TOO.** Before
    /// the cut lane A plays the outgoing piece and lane B the incoming one's
    /// lead-in; after it A plays the incoming piece and B the outgoing one's
    /// run-on. A look follows its piece's film, whichever lane carries it.
    struct Looks: Sendable, Equatable {
        var a: LookPreset?
        var b: LookPreset?
    }

    struct Transition: Sendable, Equatable {
        var kind: VideoTransitionKind
        /// The window on the composition's clock, in seconds: it opens `half`
        /// before the cut and closes `half` after it.
        var opens: Double
        var cut: Double
        var closes: Double

        /// How far through the whole window `seconds` is, 0 at its opening and
        /// 1 at its close.
        func progress(at seconds: Double) -> Double {
            guard closes > opens else { return seconds < cut ? 0 : 1 }
            return min(max((seconds - opens) / (closes - opens), 0), 1)
        }
    }
}

/// A stretch of the composition and what to draw over it.
///
/// ⚠️ **LANE A IS THE ARRANGEMENT; LANE B IS ONLY EVER THE OTHER SIDE OF A
/// CUT.** Before a cut, A plays the outgoing piece and B the incoming one's
/// lead-in; after it, A plays the incoming piece and B the outgoing one's
/// run-on. Which is which follows from the time, so the instruction only names
/// the tracks.
final class VideoCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol,
    @unchecked Sendable {
    // ⚠️ `@unchecked` BECAUSE EVERY STORED PROPERTY IS A `let` OF A SENDABLE
    // TYPE; NSObject is what keeps the compiler from seeing that.
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let laneA: CMPersistentTrackID
    let laneB: CMPersistentTrackID?
    let scene: VideoCompositionScene
    /// Where sticker pictures come from; nil draws every overlay but those.
    let artwork: (any OverlayArtwork)?
    /// The preview's whole look, read on every frame in place of
    /// `scene.finish.look`. Nil for an export, which draws what its plan says.
    let live: VideoLiveLook?

    init(
        timeRange: CMTimeRange, laneA: CMPersistentTrackID, laneB: CMPersistentTrackID?,
        scene: VideoCompositionScene, artwork: (any OverlayArtwork)? = nil, live: VideoLiveLook? = nil
    ) {
        self.timeRange = timeRange
        self.laneA = laneA
        self.laneB = laneB
        self.scene = scene
        self.artwork = artwork
        self.live = live
        // ⚠️ A STRETCH WHOSE PICTURE CAN CHANGE WHILE ITS SOURCE STANDS STILL
        // SAYS SO — a transition, a look that moves with time or may be changed
        // live, overlays that animate. Otherwise AVFoundation is free to draw
        // one frame and repeat it.
        self.containsTweening = scene.transition != nil || live != nil
            || !scene.finish.look.isNeutral || !scene.finish.overlays.isEmpty
        self.requiredSourceTrackIDs = ([laneA] + (laneB.map { [$0] } ?? []))
            .map { NSNumber(value: $0) }
    }
}

/// Draws every arrangement this app plays or exports: the picture upright, each
/// piece in its own look, every transition at its cut, and the finish — crop,
/// whole look, overlays — over the result.
///
/// ⚠️ **ONE COMPOSITOR FOR THE PREVIEW AND THE EXPORT.** The editor's canvas
/// reads its frames through an `AVAssetReaderVideoCompositionOutput` driven by
/// this class (`ComposedFrameReader`), and the export session runs it too — so
/// the author watches exactly the pixels that get published.
///
/// ⚠️ **AND IT IS CUSTOM BECAUSE THE BUILT-IN ONE CANNOT CROSS-FADE.** Layer
/// instructions ramp an opacity, a transform or a crop, linearly, one track at
/// a time. A dissolve, a page curl or a ripple needs both pictures in one
/// filter, which only a compositor of our own can hand it.
final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    // ⚠️ `@unchecked`: the only state is the shared context, which Core Image
    // documents as safe to use from any thread.

    /// ⚠️ **ONE CONTEXT FOR THE PROCESS.** Making one compiles Metal pipelines;
    /// measured, the first composed frame of a fresh context took a second on
    /// the simulator. AVFoundation makes a new compositor per item and per
    /// reader, so a per-instance context would pay that on every load.
    ///
    /// ⚠️ **AND NO COLOUR MANAGEMENT, WHICH IS WHAT THE BUILT-IN COMPOSITOR
    /// DID.** Managed, a dip blended in linear light: measured, the frame half
    /// way down a fade to black kept 181 of 229 red where the ramp says 115, and
    /// every plain frame came back with its green lifted by 17. Unmanaged, the
    /// picture's values pass through and a blend is a blend of what is encoded
    /// — and the output buffers are tagged Rec. 709, which is what they hold.
    static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .name: "VideoCompositor"
    ])

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_32BGRA
            ]
        ]
    }

    /// ⚠️ **IOSURFACE-BACKED, OR THE SAMPLE-BUFFER LAYER FREEZES ON THEM** —
    /// `VideoFrameSource` records the measurement.
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? VideoCompositorInstruction,
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: VideoExportError.exportFailed as NSError)
            return
        }
        let a = request.sourceFrame(byTrackID: instruction.laneA).map(Self.picture)
        let b = instruction.laneB
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map(Self.picture)
        // ⚠️ THE BOARD IS READ HERE, ONCE PER FRAME, so a look the author
        // changes reaches the next frame composed — with no new item and no new
        // reader.
        let picture = Self.draw(
            instruction.scene, laneA: a, laneB: b, at: request.compositionTime.seconds,
            look: instruction.live?.look, artwork: instruction.artwork
        )
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        Self.context.render(
            picture, to: output,
            bounds: CGRect(origin: .zero, size: instruction.scene.renderSize),
            colorSpace: nil
        )
        request.finish(withComposedVideoFrame: output)
    }

    /// A source frame as Core Image should read it.
    ///
    /// ⚠️ **A FRAME THAT DOES NOT SAY HOW IT IS ENCODED IS READ AS REC. 709** —
    /// what the encoders this app meets write, and what `VideoFrameSource`
    /// assumes for the same untagged buffers. Left alone, Core Image converts
    /// with another matrix and the colours shift.
    private static func picture(_ buffer: CVPixelBuffer) -> CIImage {
        if CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    // MARK: - Drawing

    /// The picture at `seconds`, from the two lanes' raw frames.
    ///
    /// ⚠️ **IN THIS ORDER, PER FRAME:** each lane upright and in its piece's
    /// look → the transition → the crop → the whole look → the overlays. A
    /// dissolve therefore blends two pieces that already wear their looks
    /// instead of snapping at the cut, and the whole look grades the finished
    /// film the way an adjustment layer does.
    ///
    /// `look` replaces `scene.finish.look` — the preview's live board — and
    /// `artwork` supplies the stickers.
    ///
    /// ⚠️ **ALWAYS OVER AN OPAQUE BACKGROUND, CROPPED TO THE CANVAS.** A filter
    /// that reaches past the frame (a page curl, a zoom) would otherwise leave
    /// whatever the buffer held last in the margins.
    static func draw(
        _ scene: VideoCompositionScene, laneA: CIImage?, laneB: CIImage?, at seconds: Double,
        look: FrameLook? = nil, artwork: (any OverlayArtwork)? = nil
    ) -> CIImage {
        finished(
            joined(scene, laneA: laneA, laneB: laneB, at: seconds), scene: scene,
            look: look ?? scene.finish.look, at: seconds, artwork: artwork
        )
    }

    /// The film at `seconds` on the upright canvas: the lanes in their pieces'
    /// looks, and the transition between them.
    private static func joined(
        _ scene: VideoCompositionScene, laneA: CIImage?, laneB: CIImage?, at seconds: Double
    ) -> CIImage {
        let canvas = CGRect(origin: .zero, size: scene.uprightSize)
        func upright(_ image: CIImage?, wearing preset: LookPreset?) -> CIImage? {
            guard let turned = image?.transformed(by: scene.orientation).cropped(to: canvas) else {
                return nil
            }
            guard let preset else { return turned }
            return FrameLookRenderer.apply(FrameLook(preset: preset), to: turned, time: seconds)
        }
        let a = upright(laneA, wearing: scene.looks.a)
        let background = CIImage(color: .black).cropped(to: canvas)
        guard let transition = scene.transition else {
            return (a ?? background).composited(over: background).cropped(to: canvas)
        }
        let beforeCut = seconds < transition.cut
        let drawn: CIImage
        switch transition.kind {
        case .dipToBlack, .dipToWhite:
            let colour = transition.kind == .dipToBlack
                ? CIImage(color: .black) : CIImage(color: .white)
            let half = beforeCut ? transition.cut - transition.opens : transition.closes - transition.cut
            let into = half > 0
                ? (beforeCut ? (seconds - transition.opens) : (transition.closes - seconds)) / half
                : 0
            let alpha = CGFloat(1 - min(max(into, 0), 1))
            let faded = (a ?? background).applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            drawn = faded.composited(over: colour.cropped(to: canvas))
        case .zoom:
            let half = beforeCut ? transition.cut - transition.opens : transition.closes - transition.cut
            let into = half > 0
                ? (beforeCut ? (seconds - transition.opens) : (transition.closes - seconds)) / half
                : 0
            let scale = 1 + (VideoExporter.zoomThroughScale - 1) * CGFloat(min(max(into, 0), 1))
            let centre = CGPoint(x: canvas.midX, y: canvas.midY)
            drawn = (a ?? background).transformed(by: VideoExporter.zoom(about: centre, by: scale))
        default:
            let other = upright(laneB, wearing: scene.looks.b) ?? a ?? background
            let from = beforeCut ? (a ?? background) : other
            let to = beforeCut ? other : (a ?? background)
            drawn = cross(
                transition.kind, from: from, to: to,
                progress: transition.progress(at: seconds), canvas: canvas
            )
        }
        return drawn.composited(over: background).cropped(to: canvas)
    }

    /// The joined film, cut, graded and dressed: what the frame shows.
    ///
    /// ⚠️ **THE CROP IS A FRACTION OF THE UPRIGHT PICTURE, SO IT COMES AFTER THE
    /// TURN — AND AFTER THE BLEND,** which is drawn on the whole canvas: a page
    /// curl crossing a cropped frame is the same curl, cut.
    ///
    /// ⚠️ **AND ITS EDGE IS STRETCHED OVER THE LAST PIXEL OF THE RENDER.** The
    /// render size is the kept fraction rounded to even pixels, and the graph
    /// keeps the exact fraction, moved to the origin by whole pixels: the two
    /// can differ by up to a pixel on either side. Left alone, that pixel is a
    /// black line down the edge of every frame.
    private static func finished(
        _ film: CIImage, scene: VideoCompositionScene, look: FrameLook, at seconds: Double,
        artwork: (any OverlayArtwork)?
    ) -> CIImage {
        let frame = CGRect(origin: .zero, size: scene.renderSize)
        var picture = film
        if !scene.finish.crop.isUntouched, let kept = scene.finish.crop.applied(to: film) {
            picture = kept.clampedToExtent().cropped(to: frame)
        }
        picture = FrameLookRenderer.apply(look, to: picture, time: seconds)
        picture = OverlayRasterizer.composite(
            scene.finish.overlays, over: picture, time: seconds, artwork: artwork
        )
        return picture.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
    }

    /// A two-picture transition, `progress` of the way from `from` to `to`.
    static func cross(
        _ kind: VideoTransitionKind, from: CIImage, to: CIImage, progress: Double, canvas: CGRect
    ) -> CIImage {
        // ⚠️ A SCAN AND A FLASH FINISH A LITTLE EARLY. Their light is still
        // strong at 0.93 — the last frame of a half-second window at 30fps —
        // and the picture then snapped to the plain one on the next frame.
        let pace = kind == .copyMachine || kind == .flash ? 0.9 : 1
        let time = Float(min(max(progress / pace, 0), 1))
        let side = Float(min(canvas.width, canvas.height))
        let output: CIImage?
        switch kind {
        case .dipToBlack, .dipToWhite, .zoom:
            output = time < 0.5 ? from : to
        case .dissolve:
            let filter = CIFilter.dissolveTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.time = time
            output = filter.outputImage
        case .swipe:
            let filter = CIFilter.swipeTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.extent = canvas
            filter.color = CIColor(red: 1, green: 1, blue: 1)
            filter.time = time
            filter.angle = .pi
            filter.width = side * 0.4
            filter.opacity = 0
            output = filter.outputImage
        case .bars:
            let filter = CIFilter.barsSwipeTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.time = time
            filter.angle = .pi / 2
            filter.width = side / 8
            filter.barOffset = 10
            output = filter.outputImage
        case .copyMachine:
            let filter = CIFilter.copyMachineTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.extent = canvas
            filter.color = CIColor(red: 0.6, green: 1, blue: 0.8)
            filter.time = time
            filter.angle = 0
            filter.width = side / 5
            filter.opacity = 1.3
            output = filter.outputImage
        case .flash:
            let filter = CIFilter.flashTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.center = CGPoint(x: canvas.midX, y: canvas.midY)
            filter.extent = canvas
            filter.color = CIColor(red: 1, green: 0.8, blue: 0.6)
            filter.time = time
            filter.maxStriationRadius = 2.58
            filter.striationStrength = 0.5
            filter.striationContrast = 1.375
            filter.fadeThreshold = 0.85
            output = filter.outputImage
        case .mod:
            let filter = CIFilter.modTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.center = CGPoint(x: canvas.midX, y: canvas.midY)
            filter.time = time
            filter.angle = 2
            filter.radius = side / 2
            filter.compression = 300
            output = filter.outputImage
        case .pageCurl:
            let filter = CIFilter.pageCurlTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.backsideImage = from
            filter.shadingImage = shading(canvas)
            filter.extent = canvas
            filter.time = time
            filter.angle = .pi * 0.8
            filter.radius = side / 5
            output = filter.outputImage
        case .pageCurlShadow:
            let filter = CIFilter.pageCurlWithShadowTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.backsideImage = from.applyingFilter("CIPhotoEffectMono")
            filter.extent = canvas
            filter.time = time
            filter.angle = 0
            filter.radius = side / 5
            filter.shadowSize = 0.5
            filter.shadowAmount = 0.7
            filter.shadowExtent = .zero
            output = filter.outputImage
        case .ripple:
            let filter = CIFilter.rippleTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.shadingImage = shine(canvas)
            filter.center = CGPoint(x: canvas.midX, y: canvas.midY)
            filter.extent = canvas
            filter.time = time
            filter.width = side / 6
            filter.scale = 50
            output = filter.outputImage
        case .accordion:
            let filter = CIFilter.accordionFoldTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.bottomHeight = 0
            filter.numberOfFolds = 5
            filter.foldShadowAmount = 0.2
            filter.time = time
            output = filter.outputImage
        case .disintegrate:
            let filter = CIFilter.disintegrateWithMaskTransition()
            filter.inputImage = from
            filter.targetImage = to
            filter.maskImage = mask(canvas)
            filter.time = time
            filter.shadowRadius = 8
            filter.shadowDensity = 0.65
            filter.shadowOffset = CGPoint(x: 0, y: -10)
            output = filter.outputImage
        }
        return output ?? (time < 0.5 ? from : to)
    }

    /// A soft light falling off from the middle — what a page curl shades its
    /// fold with. (Not a ripple: see `shine`.)
    private static func shading(_ canvas: CGRect) -> CIImage {
        let radial = CIFilter.radialGradient()
        radial.center = CGPoint(x: canvas.midX, y: canvas.midY)
        radial.radius0 = 0
        radial.radius1 = Float(max(canvas.width, canvas.height))
        radial.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        radial.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        return (radial.outputImage ?? CIImage(color: .clear)).cropped(to: canvas)
    }

    /// The light a ripple's crest catches: none in the middle, more towards
    /// the rim.
    ///
    /// ⚠️ **CLEAR IN THE MIDDLE, OR THE WHOLE PICTURE TURNS PALE.** A ripple
    /// ADDS its shading, read where the picture's slope points — and where the
    /// picture is flat (outside the ring, and all of it at either end of the
    /// window) that is the shading's centre. Handed `shading`, bright in the
    /// middle, it lifted every pixel by 228 of 255: measured, red drawn as
    /// (255,228,228) from the first frame of the window to the last, and a jump
    /// of 231 where the window opened.
    private static func shine(_ canvas: CGRect) -> CIImage {
        let side = Float(min(canvas.width, canvas.height))
        let radial = CIFilter.radialGradient()
        radial.center = CGPoint(x: canvas.midX, y: canvas.midY)
        radial.radius0 = side / 20
        radial.radius1 = side / 2
        radial.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        radial.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.6)
        return (radial.outputImage ?? CIImage(color: .clear)).cropped(to: canvas)
    }

    /// The grain a disintegration breaks the picture along: noise, stretched
    /// so it reads as flakes rather than pixels.
    private static func mask(_ canvas: CGRect) -> CIImage {
        let noise = CIFilter.randomGenerator().outputImage ?? CIImage(color: .gray)
        return noise
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .cropped(to: canvas)
    }
}
