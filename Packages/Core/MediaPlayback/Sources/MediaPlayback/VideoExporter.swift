import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import UIKit

/// An exported, upload-ready video plus the metadata the media.v1 upload-ticket
/// flow needs (declared mime/size + a content SHA-256), mirroring
/// `MediaCore.EncodedImage` for video. The file lives in the temp directory;
/// the caller uploads it and may delete it after.
public struct ExportedVideo: Sendable, Equatable {
    public let fileURL: URL
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let durationSeconds: Double
    public let byteSize: UInt64
    public let sha256Hex: String
    /// Where the file's transitions draw, in seconds of the file.
    public let transitionWindows: [ClosedRange<Double>]

    /// The moment the poster is taken from — never inside a transition.
    public var posterSeconds: Double {
        VideoExporter.posterSeconds(duration: durationSeconds, avoiding: transitionWindows)
    }
}

/// What to make of a picked clip on its way to the upload.
///
/// ⚠️ **A VALUE RATHER THAN MORE PARAMETERS, BECAUSE THIS LIST IS GOING TO
/// GROW.** Trim needs a time range; crop and filters will need a composition,
/// which cannot simply be passed in — `AVComposition` is not `Sendable` and a
/// composition has to be built where its asset lives, so that slot will be a
/// BUILDER. Adding it to a struct changes no call site; adding it to a
/// parameter list changes every one.
///
/// It is not here yet, on purpose: an unused slot is dead code, and this repo
/// has just removed one for exactly that reason.
public struct VideoExportPlan: Sendable {
    public let sourceURL: URL

    /// The pieces of the clip to keep, in order, each with the rate it plays at.
    ///
    /// ⚠️ **EMPTY IS NOT THE SAME AS "ONE PIECE COVERING EVERYTHING".** Empty
    /// leaves `AVAssetExportSession.timeRange` alone and builds no composition,
    /// which is the path every untouched clip has always taken; one piece
    /// spanning the whole clip still makes the session re-encode it.
    /// `MediaTimelining.cuts(_:withinSource:)` is what the caller asks to tell
    /// the two apart.
    ///
    /// ⚠️ **AND THE EXPORTER PICKS ITS OWN ROUTE FROM THIS, RATHER THAN BEING
    /// TOLD.** One piece at 1x is a `timeRange` and no composition at all; more
    /// than one, or any rate other than 1x, needs an `AVMutableComposition`.
    /// Leaving that choice to the caller is how a second caller gets it wrong.
    public let segments: [VideoExportSegment]

    /// Nil takes the exporter's own preset.
    public let preset: String?

    public init(
        sourceURL: URL, segments: [VideoExportSegment] = [], preset: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.segments = segments
        self.preset = preset
    }

    /// One piece, at the rate it was shot — the shape a trim has.
    public init(sourceURL: URL, timeRange: ClosedRange<Double>?, preset: String? = nil) {
        self.init(
            sourceURL: sourceURL,
            segments: timeRange.map {
                [VideoExportSegment(start: $0.lowerBound, end: $0.upperBound)]
            } ?? [],
            preset: preset
        )
    }
}

/// A transition drawn at a cut.
///
/// ⚠️ **ONLY WHAT THE COMPOSITOR DRAWS.** Every case here has a drawing in
/// `VideoCompositor`, whose two-picture switch has no `default` — so a case
/// cannot be added without one, and no chip can offer a transition that
/// publishes as a plain cut. "No transition" is `nil`, never a case: two
/// spellings of nothing would break every equality that compares timelines.
public enum VideoTransitionKind: String, CaseIterable, Sendable {
    /// The picture fades to black up to the cut and back from it.
    case dipToBlack
    /// The same, through white.
    case dipToWhite
    /// The outgoing picture zooms in to the cut, the incoming one out of it.
    case zoom
    /// The two pictures cross-fade.
    case dissolve
    /// A soft edge sweeps the incoming picture across.
    case swipe
    /// Bars slide the outgoing picture away.
    case bars
    /// A scanner's light bar copies the incoming picture over.
    case copyMachine
    /// A burst of light flashes from one picture to the other.
    case flash
    /// Swirling bands reveal the incoming picture.
    case mod
    /// The outgoing picture curls away like a page.
    case pageCurl
    /// The same curl, with a shadow and a grey back.
    case pageCurlShadow
    /// A ripple spreads the incoming picture from the middle.
    case ripple
    /// The outgoing picture folds up like an accordion.
    case accordion
    /// The outgoing picture breaks up into flakes.
    case disintegrate

    /// How long every transition runs, in PLAYED seconds, centred on its cut.
    /// ⚠️ **NOT STORED PER CUT** — a length no screen can change would be a
    /// field nothing sets; it becomes one when a duration control exists.
    public static let standardSeconds: Double = 0.5

    /// Whether the transition shows both pieces at once — and so needs the
    /// other side of its cut on a second lane. The dips and the zoom draw each
    /// piece on its own side of the cut.
    public var needsBothPictures: Bool {
        switch self {
        case .dipToBlack, .dipToWhite, .zoom: false
        default: true
        }
    }
}

/// One piece of the source, and how fast it plays.
public struct VideoExportSegment: Sendable, Equatable {
    /// Seconds from the start of the SOURCE file.
    public let start: Double
    public let end: Double
    /// 1 is as shot. 2 plays it twice as fast, so it lasts half as long.
    public let speed: Double
    /// The transition at the cut AFTER this piece. ⚠️ Ignored on the last
    /// piece, which has no cut after it.
    public let transitionOut: VideoTransitionKind?

    public init(
        start: Double, end: Double, speed: Double = 1,
        transitionOut: VideoTransitionKind? = nil
    ) {
        self.start = start
        self.end = end
        self.speed = speed
        self.transitionOut = transitionOut
    }

    var sourceSeconds: Double { max(end - start, 0) }
    var isAsShot: Bool { abs(speed - 1) < 0.001 }
}

public enum VideoExportError: Error, Equatable {
    case unreadable
    case exportFailed
    case noVideoTrack
}

/// Normalizes a picked video for upload: transcodes to a capped-resolution MP4
/// (H.264 + AAC) via `AVAssetExportSession`, then records dimensions, duration,
/// byte size, and a content hash. The backend transcodes again to an ABR ladder
/// (Phase 3); this pass just bounds the upload size and normalizes the codec.
public struct VideoExporter: Sendable {
    private let preset: String

    /// `AVAssetExportPreset1280x720` by default — a sensible upload cap.
    public init(preset: String = AVAssetExportPreset1280x720) {
        self.preset = preset
    }

    /// Whether a plan can be served by a `timeRange` alone.
    ///
    /// ⚠️ **NAMED, BECAUSE IT CANNOT BE SEEN FROM OUTSIDE.** Whether a
    /// composition was built is invisible in the exported file: one piece at 1x
    /// through a composition produces the same pictures and the same duration as
    /// one piece through a `timeRange`. A test comparing the two outputs
    /// therefore proves nothing — and one did, comparing a plan with ITSELF,
    /// since `init(sourceURL:timeRange:)` is sugar over exactly this segment.
    static func needsComposition(for segments: [VideoExportSegment]) -> Bool {
        segments.count > 1 || segments.contains { !$0.isAsShot }
    }

    /// How far a transition reaches on EACH side of its cut, in played seconds.
    ///
    /// ⚠️ **ONE FUNCTION FOR THE TRACK, THE HIGHLIGHT, THE PREVIEW'S EQUALITY AND
    /// THE BUILDER.** Written twice, the lit window and the drawn fade would
    /// disagree the first time either changed.
    ///
    /// ⚠️ **NEVER MORE THAN HALF OF EITHER NEIGHBOUR.** A piece with a
    /// transition at both ends gives each at most half of itself, so the two can
    /// touch and never cross — crossing instructions fail the export. Floored to
    /// the composition's 1/600 grid, and nothing at all below a frame at 30fps,
    /// where a transition would be a flicker nobody chose.
    public static func transitionHalf(
        _ kind: VideoTransitionKind?, outgoingPlayedSeconds outgoing: Double,
        incomingPlayedSeconds incoming: Double
    ) -> Double {
        guard kind != nil, outgoing.isFinite, incoming.isFinite, outgoing > 0, incoming > 0
        else { return 0 }
        let half = min(VideoTransitionKind.standardSeconds / 2, outgoing / 2, incoming / 2)
        let floored = (half * 600).rounded(.down) / 600
        return floored < 1.0 / 30 ? 0 : floored
    }

    /// The kept pieces, laid end to end, each scaled to the rate it plays at.
    ///
    /// ⚠️ **BUILT HERE AND USED ONCE, WHICH IS THE ONLY WAY IT CAN EXIST.**
    /// `AVMutableComposition` and `AVMutableCompositionTrack` are explicitly
    /// `@_nonSendable` — the conformance is *unavailable*, measured with
    /// `-emit-sil` — so one can never be stored in a `Sendable` value or handed
    /// across an isolation boundary. Region isolation does allow what happens
    /// here: a composition made inside one function, never escaping except as the
    /// `AVAsset` an export session reads. That is why `VideoExportPlan` carries
    /// segment VALUES and not a composition.
    ///
    /// ⚠️ **`scaleTimeRange` ON THE COMPOSITION, NEVER ON A TRACK.** The
    /// track-level call scales that track alone, so a sped-up piece keeps its
    /// audio at the original rate and the two drift apart for the rest of the
    /// film. The composition-level one moves every track together. Neither is
    /// deprecated; the asset-level `insertTimeRange` IS, which is why the inserts
    /// below are per-track.
    ///
    /// ⚠️ **AND THE CURSOR IS READ BACK FROM THE COMPOSITION, NOT ACCUMULATED.**
    /// Scaling a piece changes how long it occupies the timeline, so the place
    /// the next piece starts is wherever the composition now ends. Adding up
    /// source durations would lay every later piece over the one before it.
    ///
    /// ⚠️ **SHARED WITH THE PREVIEW, AND EACH CALLER BUILDS ITS OWN.** The
    /// editor's canvas plays exactly this arrangement (`VideoPlaybackController
    /// .load`), so what the author watches is what the export produces — and a
    /// piece boundary is an edit inside one item rather than a seek in the file.
    /// A composition is never handed from one caller to the other; nothing that
    /// only one of them needs (a render size, a video composition) belongs here.
    private struct Inserted {
        let composition: AVMutableComposition
        /// Where each piece starts on the composition's own clock; the end of
        /// the last is `composition.duration`.
        let starts: [CMTime]
        let video: AVMutableCompositionTrack
        let audio: AVMutableCompositionTrack?
    }

    private static func insertPieces(
        of source: AVAssetTrack, audio sourceAudio: AVAssetTrack?,
        cut segments: [VideoExportSegment]
    ) throws -> Inserted {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportError.exportFailed
        }
        // A clip with no sound is ordinary — a screen recording, a muted export —
        // and asking for an audio track it cannot fill would leave an empty one.
        let audioTrack = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var starts: [CMTime] = []
        for segment in segments where segment.sourceSeconds > 0 {
            let cursor = composition.duration
            starts.append(cursor)
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            do {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
                if let audioTrack, let sourceAudio {
                    try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
            } catch {
                throw VideoExportError.exportFailed
            }
            guard !segment.isAsShot, segment.speed > 0 else { continue }
            composition.scaleTimeRange(
                CMTimeRange(start: cursor, duration: range.duration),
                toDuration: CMTime(
                    seconds: segment.sourceSeconds / segment.speed, preferredTimescale: 600
                )
            )
        }
        return Inserted(composition: composition, starts: starts, video: videoTrack, audio: audioTrack)
    }

    /// When the preview or the export needs a video composition for the
    /// picture's orientation alone.
    enum OrientationRule: Sendable {
        /// Only where something must be drawn — the export, where an untouched
        /// clip keeps its metadata transform and is re-encoded as it is.
        case whenComposited
        /// Whenever the source is not stored upright — the editor's canvas,
        /// whose sample-buffer path ignores a track's transform: a clip that
        /// turned upright only while it carried a transition would rotate under
        /// the author as they edited.
        case always
    }

    /// Everything one plan becomes: the asset to play or export, and what is
    /// drawn over it.
    ///
    /// ⚠️ **NOT SENDABLE, AND IT IS NOT MEANT TO BE.** `AVMutableComposition` and
    /// `AVMutableAudioMix` are `@_nonSendable`; the caller builds this in the
    /// task that uses it and hands its pieces straight to one item or one export
    /// session.
    struct Arrangement {
        let asset: AVAsset
        let videoComposition: AVVideoComposition?
        let audioMix: AVAudioMix?
        /// Where the transitions draw, in played seconds.
        let windows: [ClosedRange<Double>]
        /// The video tracks the composition reads.
        var videoTracks: [AVAssetTrack] = []

        /// What a preview reads its composed pictures from — nil when nothing
        /// is drawn.
        var composed: ComposedVideo? {
            videoComposition.map { ComposedVideo(asset: asset, tracks: videoTracks, composition: $0) }
        }
    }

    /// The kept pieces, laid end to end, each scaled to the rate it plays at,
    /// with every transition drawn at its cut.
    ///
    /// ⚠️ **ONE BUILDER FOR THE PREVIEW AND THE EXPORT** — the editor's canvas
    /// plays exactly what the post will be, transitions and sound included.
    ///
    /// ⚠️ **`scaleTimeRange` ON THE COMPOSITION, NEVER ON A TRACK.** The
    /// track-level call scales that track alone, so a sped-up piece keeps its
    /// audio at the original rate and the two drift apart for the rest of the
    /// film. And the cursor is read back from the composition, not accumulated:
    /// scaling a piece changes where the next one starts.
    ///
    /// ⚠️ **THE INSTRUCTIONS TILE THE WHOLE DURATION ON THE COMPOSITION'S OWN
    /// CLOCK.** Cut times come from the cursors, never from a sum of source
    /// seconds; a set that ends one tick short renders in an image generator and
    /// FAILS THE EXPORT (-11841), and a gap renders black with no error at all.
    ///
    /// ⚠️ **A TRANSITION DRAWS INSIDE ITS OWN TWO PIECES.** The dips and the zoom
    /// play on the single lane: the outgoing piece fades or zooms up to the cut,
    /// the incoming one from it. A two-picture kind reads the other side of the
    /// cut from a second lane (`otherSides`) instead of overlapping the pieces,
    /// so the played length is exactly what the track shows either way.
    ///
    /// ⚠️ **EVERYTHING IS DRAWN BY `VideoCompositor`.** A custom compositor
    /// takes over the whole composition, so the dips and the zoom are its too —
    /// one drawing for every kind, in the preview and in the export.
    ///
    /// ⚠️ **NO VIDEO COMPOSITION UNLESS SOMETHING IS DRAWN.** An arrangement with
    /// no transition, from an upright source, is the composition it always was —
    /// no compositor in the way of the seams charter T12 measured.
    ///
    /// `longestSide` caps the composed picture — the preview's, which a phone
    /// screen shows at a fraction of a 4K frame's pixels. Nil composes at the
    /// source's own size, which is what an export must do.
    static func arrangement(
        of asset: AVURLAsset, cut segments: [VideoExportSegment], orientation: OrientationRule,
        longestSide: CGFloat? = nil
    ) async throws -> Arrangement {
        guard let source = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }
        let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
        let preferred = (try? await source.load(.preferredTransform)) ?? .identity
        let natural = (try? await source.load(.naturalSize)) ?? .zero
        let shortestFrame = (try? await source.load(.minFrameDuration)) ?? .invalid
        let sourceRange = (try? await source.load(.timeRange)) ?? .invalid
        let turned = !preferred.isIdentity
        let canvas = Canvas(
            preferred: preferred, natural: natural, shortestFrame: shortestFrame, longestSide: longestSide
        )

        if segments.isEmpty {
            guard orientation == .always, turned else {
                return Arrangement(asset: asset, videoComposition: nil, audioMix: nil, windows: [])
            }
            let duration = try await asset.load(.duration)
            let composition = try composed(
                laneA: source.trackID, laneB: nil, canvas: canvas, windows: [], duration: duration
            )
            return Arrangement(
                asset: asset, videoComposition: composition, audioMix: nil, windows: [],
                videoTracks: [source]
            )
        }

        let kept = segments.filter { $0.sourceSeconds > 0 }
        let inserted = try insertPieces(of: source, audio: sourceAudio, cut: kept)
        // ⚠️ THE TRANSFORM TRAVELS WITH THE PICTURES. Without it a clip a phone
        // recorded upright exports on its side — the composition track starts
        // with an identity transform whatever the source carried. (The
        // compositor turns the frames itself; this keeps a composition that
        // draws nothing upright for whoever plays it without one.)
        inserted.video.preferredTransform = preferred
        let composition = inserted.composition
        let duration = composition.duration
        let windows = cuts(of: kept, starts: inserted.starts, duration: duration)

        guard !windows.isEmpty || (orientation == .always && turned) else {
            return Arrangement(asset: composition, videoComposition: nil, audioMix: nil, windows: [])
        }
        let laneB = try otherSides(
            of: windows, pieces: kept, starts: inserted.starts, from: source,
            sourceRange: sourceRange, frame: canvas.frame, in: composition
        )
        let video = try composed(
            laneA: inserted.video.trackID, laneB: laneB, canvas: canvas,
            windows: windows, duration: duration
        )
        return Arrangement(
            asset: composition, videoComposition: video,
            audioMix: inserted.audio.flatMap { soundDips(on: $0, windows: windows) },
            windows: windows.map { $0.opens.seconds...$0.closes.seconds },
            videoTracks: composition.tracks(withMediaType: .video)
        )
    }

    /// One transition, on the composition's own clock.
    private struct Cut {
        let kind: VideoTransitionKind
        let at: CMTime
        let half: CMTime
        /// Whether both pieces play as shot — the only place the sound may ramp.
        let asShotBothSides: Bool
        /// Which pieces meet here.
        let outgoing: Int

        var opens: CMTime { at - half }
        var closes: CMTime { at + half }
    }

    /// Where every transition draws.
    ///
    /// ⚠️ **MEASURED ON THE COMPOSITION'S OWN LENGTHS, NOT ON THE PLAN'S.** The
    /// plan's seconds and the composition's can differ by a tick
    /// (`CMTime(seconds:)` truncates — 0.6 is 359/600), and two windows around
    /// one piece must never cross. Asked of the composition, a half is
    /// `floor(length·600 / 2)` ticks, which is never more than half of the
    /// length's whole ticks — `floor(y/2) == floor(floor(y)/2)` — so the two
    /// halves around a piece fit inside it without a second clamp.
    private static func cuts(
        of pieces: [VideoExportSegment], starts: [CMTime], duration: CMTime
    ) -> [Cut] {
        guard pieces.count > 1, starts.count == pieces.count else { return [] }
        var made: [Cut] = []
        for index in 0..<(pieces.count - 1) {
            guard let kind = pieces[index].transitionOut else { continue }
            let opens = starts[index]
            let at = starts[index + 1]
            let closes = index + 2 < starts.count ? starts[index + 2] : duration
            let outgoing = at - opens
            let incoming = closes - at
            let half = transitionHalf(
                kind, outgoingPlayedSeconds: outgoing.seconds, incomingPlayedSeconds: incoming.seconds
            )
            // ⚠️ NO RE-CLAMP ON THE TICKS: `transitionHalf` already floors to
            // the 1/600 grid, and flooring again here once made a window a tick
            // shorter than the one the track lights.
            let ticks = Int64((half * 600).rounded(.down))
            guard ticks >= 20 else { continue }
            made.append(Cut(
                kind: kind, at: at, half: CMTime(value: ticks, timescale: 600),
                asShotBothSides: pieces[index].isAsShot && pieces[index + 1].isAsShot,
                outgoing: index
            ))
        }
        return made
    }

    /// How far the zoom goes at the cut.
    static let zoomThroughScale: CGFloat = 2

    /// The picture's geometry, worked out once per source.
    private struct Canvas {
        let size: CGSize
        /// Upright, at the origin, in Core Image's y-up space.
        let orientation: CGAffineTransform
        let frame: CMTime

        init(
            preferred: CGAffineTransform, natural: CGSize, shortestFrame: CMTime, longestSide: CGFloat?
        ) {
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            let full = CGSize(width: abs(bounds.width).rounded(), height: abs(bounds.height).rounded())
            // ⚠️ SCALED DOWN, NEVER UP, AND TO EVEN PIXELS — a 4:2:0 encoder and
            // the sample-buffer layer both want whole chroma samples.
            let longest = max(full.width, full.height)
            let factor = longestSide.map { longest > $0 && longest > 0 ? $0 / longest : 1 } ?? 1
            let size = factor < 1
                ? CGSize(
                    width: max(2, (full.width * factor / 2).rounded() * 2),
                    height: max(2, (full.height * factor / 2).rounded() * 2)
                )
                : full
            self.size = size
            // ⚠️ UPRIGHT, THEN PUT BACK AT THE ORIGIN — a rotation alone leaves
            // the picture in negative coordinates and renders nothing.
            let oriented = preferred.concatenating(
                CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            )
            // ⚠️ AND CARRIED INTO CORE IMAGE'S SPACE. The track's transform is
            // written with y pointing down, a `CIImage`'s with y pointing up:
            // flip into the source's rows, turn, flip back out of the canvas's.
            let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
            let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: full.height)
            let shrink = CGAffineTransform(
                scaleX: full.width > 0 ? size.width / full.width : 1,
                y: full.height > 0 ? size.height / full.height : 1
            )
            self.orientation = flipIn.concatenating(oriented).concatenating(flipOut).concatenating(shrink)
            let sixty = CMTime(value: 1, timescale: 60)
            self.frame = shortestFrame.isValid && shortestFrame > .zero
                ? max(shortestFrame, sixty) : CMTime(value: 1, timescale: 30)
        }
    }

    /// Lays the other side of every two-picture cut on a second video lane.
    ///
    /// ⚠️ **THE FILM EITHER SIDE OF A CUT, NOT AN OVERLAP.** Cross-fading by
    /// overlapping the pieces would shorten the result and break every played
    /// second the track draws. Instead, before the cut this lane plays the film
    /// that LEADS INTO the incoming piece, and after it the film that FOLLOWS
    /// the outgoing one — so each picture runs on without a jump when the lanes
    /// swap at the cut, and the result is exactly as long as the track says.
    ///
    /// ⚠️ **AND WHERE THE FILE HAS NO SUCH FILM, ONE FRAME HELD.** A piece that
    /// starts at the file's first frame has nothing before it; one that ends on
    /// its last has nothing after. That side of the transition holds the edge
    /// frame instead of reading past the file, which would fail the build.
    ///
    /// ⚠️ **SCALED ON THIS TRACK ONLY, AND AFTER THE ARRANGEMENT IS BUILT.**
    /// The lane has no sound, so a track-level scale cannot drift anything, and
    /// the composition-level scales that set the pieces' rates have all been
    /// applied already — one issued now would stretch these inserts too.
    private static func otherSides(
        of windows: [Cut], pieces: [VideoExportSegment], starts: [CMTime],
        from source: AVAssetTrack, sourceRange: CMTimeRange, frame: CMTime,
        in composition: AVMutableComposition
    ) throws -> CMPersistentTrackID? {
        let crossings = windows.filter(\.kind.needsBothPictures)
        guard !crossings.isEmpty else { return nil }
        guard let lane = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportError.exportFailed
        }
        let fileStart = sourceRange.isValid ? sourceRange.start : .zero
        let fileEnd = sourceRange.isValid ? sourceRange.end : .positiveInfinity
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        func place(_ film: CMTimeRange, at target: CMTimeRange) throws {
            if lane.timeRange.end < target.start {
                lane.insertEmptyTimeRange(CMTimeRange(start: lane.timeRange.end, end: target.start))
            }
            try lane.insertTimeRange(film, of: source, at: target.start)
            if film.duration != target.duration {
                lane.scaleTimeRange(
                    CMTimeRange(start: target.start, duration: film.duration),
                    toDuration: target.duration
                )
            }
        }
        do {
            for cut in crossings {
                let outgoing = pieces[cut.outgoing]
                let incoming = pieces[cut.outgoing + 1]
                let half = cut.half.seconds
                // Before the cut: what leads into the incoming piece.
                let leadIn = time(incoming.start) - time(half * incoming.speed)
                let before = leadIn >= fileStart
                    ? CMTimeRange(start: leadIn, end: time(incoming.start))
                    : CMTimeRange(start: time(incoming.start), duration: frame)
                try place(before, at: CMTimeRange(start: cut.opens, end: cut.at))
                // After the cut: what follows the outgoing piece.
                let runOn = time(outgoing.end) + time(half * outgoing.speed)
                let after = runOn <= fileEnd
                    ? CMTimeRange(start: time(outgoing.end), end: runOn)
                    : CMTimeRange(start: time(outgoing.end) - frame, duration: frame)
                try place(after, at: CMTimeRange(start: cut.at, end: cut.closes))
            }
        } catch {
            throw VideoExportError.exportFailed
        }
        return lane.trackID
    }

    /// The video composition: the picture upright, and every transition drawn,
    /// by `VideoCompositor`.
    private static func composed(
        laneA: CMPersistentTrackID, laneB: CMPersistentTrackID?, canvas: Canvas,
        windows: [Cut], duration: CMTime
    ) throws -> AVVideoComposition {
        // ⚠️ POSITIVE OR NOTHING: an item handed a zero render size or frame
        // duration raises an Objective-C exception rather than an error.
        guard canvas.size.width > 0, canvas.size.height > 0, duration > .zero else {
            throw VideoExportError.exportFailed
        }
        func scene(_ cut: Cut?) -> VideoCompositionScene {
            VideoCompositionScene(
                orientation: canvas.orientation, renderSize: canvas.size,
                transition: cut.map {
                    .init(kind: $0.kind, opens: $0.opens.seconds, cut: $0.at.seconds, closes: $0.closes.seconds)
                }
            )
        }
        var instructions: [VideoCompositorInstruction] = []
        var cursor = CMTime.zero
        func plain(until end: CMTime) {
            guard end > cursor else { return }
            instructions.append(VideoCompositorInstruction(
                timeRange: CMTimeRange(start: cursor, end: end), laneA: laneA, laneB: nil, scene: scene(nil)
            ))
            cursor = end
        }
        for cut in windows {
            plain(until: cut.opens)
            let other = cut.kind.needsBothPictures ? laneB : nil
            // ⚠️ TWO INSTRUCTIONS PER CUT, SPLIT AT IT: the lanes swap roles
            // there, and an instruction boundary is where AVFoundation is sure
            // to hand over the frames of the pieces either side.
            instructions.append(VideoCompositorInstruction(
                timeRange: CMTimeRange(start: cut.opens, end: cut.at),
                laneA: laneA, laneB: other, scene: scene(cut)
            ))
            instructions.append(VideoCompositorInstruction(
                timeRange: CMTimeRange(start: cut.at, end: cut.closes),
                laneA: laneA, laneB: other, scene: scene(cut)
            ))
            cursor = cut.closes
        }
        plain(until: duration)

        var configuration = AVVideoComposition.Configuration()
        configuration.customVideoCompositorClass = VideoCompositor.self
        configuration.renderSize = canvas.size
        configuration.frameDuration = canvas.frame
        configuration.instructions = instructions
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return AVVideoComposition(configuration: configuration)
    }

    /// A scale about a point, in the upright picture's space.
    static func zoom(about centre: CGPoint, by scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }

    /// The sound follows a dip down and back up; a zoom leaves it alone.
    ///
    /// ⚠️ **NEVER ACROSS A PIECE THAT IS NOT AS SHOT — A RAMP THERE CAN FREEZE THE
    /// EXPORT FOR GOOD.** Measured on the iOS 26.5 simulator: a volume ramp at
    /// the start of a piece played at 3x or 4x left `AVAssetExportSession` with
    /// every remaker thread waiting and no error, once in twelve exports (the
    /// offline mixer logs "AppendRateChange … previously did a conversion" as it
    /// goes); ninety exports of the same ramps between pieces at 1x all finished.
    /// A publish that never ends is worse than a dip heard as a plain cut, so a
    /// cut touching a rated piece dips its picture only.
    private static func soundDips(
        on track: AVMutableCompositionTrack, windows: [Cut]
    ) -> AVAudioMix? {
        let dips = windows.filter {
            ($0.kind == .dipToBlack || $0.kind == .dipToWhite) && $0.asShotBothSides
        }
        guard !dips.isEmpty else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        for dip in dips {
            parameters.setVolumeRamp(
                fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: dip.opens, end: dip.at)
            )
            parameters.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: dip.at, end: dip.closes)
            )
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// The whole clip, unchanged — what every caller asked for before a trim
    /// existed, kept so widening the requirement churned nothing.
    public func export(_ sourceURL: URL) async throws -> ExportedVideo {
        try await export(VideoExportPlan(sourceURL: sourceURL))
    }

    public func export(_ plan: VideoExportPlan) async throws -> ExportedVideo {
        let asset = AVURLAsset(url: plan.sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).mp4")

        // ⚠️ **ONE PIECE AT 1x NEVER BUILDS A COMPOSITION.** A `timeRange` on
        // the session is what a trim has always been, and a composition would be
        // a second reader, a second set of tracks and a second thing to get
        // wrong for a result that is identical. The composition exists for what
        // a `timeRange` CANNOT say: several pieces, or a rate other than as-shot.
        let needsComposition = Self.needsComposition(for: plan.segments)
        let arranged = needsComposition
            ? try await Self.arrangement(of: asset, cut: plan.segments, orientation: .whenComposited)
            : nil
        let subject: AVAsset = arranged?.asset ?? asset
        // ⚠️ **PASSTHROUGH DRAWS NOTHING, AND SAYS NOTHING.** It ignores a video
        // composition and an audio mix and still reports success — measured with
        // two tracks and no blend. A plan that asked for it gets this exporter's
        // own preset the moment something has to be drawn.
        var presetName = plan.preset ?? preset
        if arranged?.videoComposition != nil, presetName == AVAssetExportPresetPassthrough {
            presetName = preset
        }

        guard let session = AVAssetExportSession(asset: subject, presetName: presetName) else {
            throw VideoExportError.exportFailed
        }
        session.videoComposition = arranged?.videoComposition
        session.audioMix = arranged?.audioMix
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        // ⚠️ **PITCH IS SPECTRAL BY DEFAULT, WHICH IS WHAT A SPEED CHANGE WANTS**
        // — a voice sped up keeps its pitch instead of turning into a chipmunk.
        // Stated rather than left implicit because it is one algorithm for the
        // WHOLE export: a timeline mixing 0.5x and 2x gets one treatment, not one
        // per piece.
        session.audioTimePitchAlgorithm = .spectral
        // ⚠️ **ASSIGNED ONLY WHEN THERE IS ONE, AND NEVER OVER A COMPOSITION.**
        // The composition already holds only the film that is kept; a range on
        // top of it would cut the cut. Setting a range that happens to cover the
        // whole clip is also not the same as setting none — the session re-encodes
        // either way, and every untouched video would pay for a feature it is not
        // using.
        if !needsComposition, let only = plan.segments.first {
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: only.start, preferredTimescale: 600),
                end: CMTime(seconds: only.end, preferredTimescale: 600)
            )
        }

        await session.export()
        guard session.status == .completed else {
            throw VideoExportError.exportFailed
        }

        // Natural size, transform-corrected so portrait clips report portrait.
        // Read from the SOURCE track: a trim changes how long the clip runs, not
        // how big its pictures are. The duration below is read from the OUTPUT
        // for the opposite reason.
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let corrected = naturalSize.applying(transform)
        let width = Int(abs(corrected.width).rounded())
        let height = Int(abs(corrected.height).rounded())

        let duration = try await AVURLAsset(url: outputURL).load(.duration)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteSize = (attrs[.size] as? UInt64) ?? 0

        return ExportedVideo(
            fileURL: outputURL,
            mimeType: "video/mp4",
            pixelWidth: width,
            pixelHeight: height,
            durationSeconds: duration.seconds.isFinite ? duration.seconds : 0,
            byteSize: byteSize,
            sha256Hex: try Self.sha256Hex(of: outputURL),
            transitionWindows: arranged?.windows ?? []
        )
    }

    /// A poster frame for the compose preview and the feed thumbnail.
    /// Best-effort; returns nil if generation fails.
    ///
    /// ⚠️ **NOT AT t=0, BECAUSE REAL FILM OPENS ON BLACK.** This asked for
    /// exactly zero, and the doc called it "the first ~clean frame" as though it
    /// were. It is not: a great deal of real content fades in, and the very
    /// first frame is then a black rectangle — which becomes the post's
    /// `thumbnail_url`, and a black thumbnail is indistinguishable from the
    /// no-thumbnail bug this poster exists to prevent.
    ///
    /// Found the moment real encodes were put behind the device-media mock: Big
    /// Buck Bunny's tile drew its forest, and the Sintel trailer's drew pure
    /// black, because Sintel opens on a fade. Both files are perfectly fine.
    ///
    /// A tenth of the way in, capped at one second — far enough past an opening
    /// fade for ordinary content, near enough that the poster is still
    /// recognisably the start of the clip. Zero remains the fallback, so a clip
    /// too short or too stubborn for the offset still gets a picture rather than
    /// nothing.
    public func posterImage(for url: URL) async -> UIImage? {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return await posterImage(
            for: url, atSeconds: Self.posterSeconds(duration: seconds, avoiding: []),
            before: .infinity
        )
    }

    /// The poster of a file this exporter has just written: never taken from
    /// inside one of its transitions.
    ///
    /// ⚠️ **A DIP AT THE POSTER'S MOMENT WOULD PUBLISH A BLACK THUMBNAIL** — which
    /// looks exactly like the no-thumbnail bug, and mock mode hides it. The
    /// moment moves past the window, and the generator may not wander on into
    /// the next one.
    public func posterImage(for exported: ExportedVideo) async -> UIImage? {
        let at = exported.posterSeconds
        let next = exported.transitionWindows.map(\.lowerBound).filter { $0 >= at }.min()
        return await posterImage(for: exported.fileURL, atSeconds: at, before: next ?? .infinity)
    }

    /// A tenth of the way in, capped at a second, and moved past any transition
    /// it lands in; the start of the file when nothing else is left.
    public static func posterSeconds(
        duration: Double, avoiding windows: [ClosedRange<Double>]
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        var moment = min(1, duration / 10)
        for window in windows.sorted(by: { $0.lowerBound < $1.lowerBound })
        where window.lowerBound < moment && moment < window.upperBound {
            moment = window.upperBound
        }
        return moment < duration ? moment : 0
    }

    private func posterImage(
        for url: URL, atSeconds offset: Double, before limit: Double
    ) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // ⚠️ **AT OR AFTER, NEVER BEFORE — OR THE OFFSET BUYS NOTHING.** The
        // default tolerance is infinite in BOTH directions, so the generator is
        // free to answer with the nearest keyframe, and on a short clip the
        // nearest keyframe to "a tenth of the way in" is frame zero. The whole
        // point is to be past the opening, so earlier is not an acceptable
        // answer; later is — up to the next transition.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = limit.isFinite
            ? CMTime(seconds: max(limit - offset, 0), preferredTimescale: 600)
            : .positiveInfinity
        if offset > 0,
           let frame = await Self.frame(from: generator, atSeconds: offset) {
            return frame
        }
        return await Self.frame(from: generator, atSeconds: 0)
    }

    private static func frame(
        from generator: AVAssetImageGenerator, atSeconds seconds: Double
    ) async -> UIImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(throwing: error ?? VideoExportError.unreadable)
                }
            }
        }
    }

    /// Streams the file through SHA-256 so large clips aren't buffered whole.
    private static func sha256Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw VideoExportError.unreadable
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
