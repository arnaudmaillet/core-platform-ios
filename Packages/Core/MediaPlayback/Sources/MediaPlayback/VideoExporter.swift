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
/// ⚠️ **A VALUE RATHER THAN MORE PARAMETERS, BECAUSE THIS LIST GROWS.** Trim
/// needed a time range, then pieces and rates; crop, looks, overlays and a song
/// followed. Adding a field with a default changes no call site; adding a
/// parameter changes every one.
///
/// ⚠️ **VALUES, NEVER A COMPOSITION.** `AVComposition` is not `Sendable` and has
/// to be built where its asset lives, so the plan says WHAT to draw and
/// `VideoExporter.arrangement` builds it, once per caller.
///
/// ⚠️ **NOT `Equatable`, AND THAT IS WHAT LETS IT CARRY `artwork`.** Sticker art
/// is a reference to baked frames; comparing two plans is a question no caller
/// asks.
public struct VideoExportPlan: Sendable {
    public let sourceURL: URL

    /// The pieces of the clip to keep, in order, each with the rate it plays at.
    ///
    /// ⚠️ **EMPTY IS NOT THE SAME AS "ONE PIECE COVERING EVERYTHING".** Empty
    /// leaves `AVAssetExportSession.timeRange` alone and cuts nothing, which is
    /// the path every untouched clip has always taken; one piece spanning the
    /// whole clip still makes the session re-encode it.
    /// `MediaTimelining.cuts(_:withinSource:)` is what the caller asks to tell
    /// the two apart. (An uncut clip is still composed when `finish` or
    /// `soundtrack` asks for it — see `VideoExporter.needsComposition`.)
    ///
    /// ⚠️ **AND THE EXPORTER PICKS ITS OWN ROUTE FROM THIS, RATHER THAN BEING
    /// TOLD.** One piece at 1x with nothing drawn is a `timeRange` and no
    /// composition at all; more than one, a rate other than 1x or a look needs
    /// an `AVMutableComposition`. Leaving that choice to the caller is how a
    /// second caller gets it wrong.
    public let segments: [VideoExportSegment]

    /// Nil takes the exporter's own preset.
    public let preset: String?

    /// The crop, the look over the whole film and the overlays on top — drawn
    /// after the pieces are joined and their transitions blended.
    public let finish: FrameFinish

    /// A song under the film, or nil for the film's own sound alone.
    public let soundtrack: VideoSoundtrack?

    /// Where sticker pictures come from. Nil draws every overlay but the
    /// stickers — which is what the editor's preview wants, since it shows
    /// overlays as views.
    public let artwork: (any OverlayArtwork)?

    public init(
        sourceURL: URL, segments: [VideoExportSegment] = [], preset: String? = nil,
        finish: FrameFinish = .none, soundtrack: VideoSoundtrack? = nil,
        artwork: (any OverlayArtwork)? = nil
    ) {
        self.sourceURL = sourceURL
        self.segments = segments
        self.preset = preset
        self.finish = finish
        self.soundtrack = soundtrack
        self.artwork = artwork
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

    /// How long a transition runs — how long its two pieces overlap — in
    /// PLAYED seconds, when the author has not said otherwise
    /// (`VideoExportSegment.transitionSeconds`).
    public static let standardSeconds: Double = 0.5

    /// Whether the transition shows both pieces at once. The dips and the zoom
    /// draw the outgoing piece up to the middle of the overlap and the incoming
    /// one from it.
    public var needsBothPictures: Bool {
        switch self {
        case .dipToBlack, .dipToWhite, .zoom: false
        default: true
        }
    }

    /// Whether the film's own sound goes down and up with the picture, as a
    /// dip does, rather than the two sounds crossing over the overlap.
    public var dipsTheSound: Bool {
        self == .dipToBlack || self == .dipToWhite
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
    /// How long that transition runs — how long this piece and the next overlap
    /// — in PLAYED seconds, before `VideoExporter.transitionOverlap` clamps it
    /// to what the two pieces can give.
    ///
    /// ⚠️ **THE STANDARD WHENEVER THERE IS NO TRANSITION — THE INITIALISER SEES
    /// TO IT.** A length on a plain cut is a second spelling of "nothing", and
    /// two identical plain pieces would compare unequal.
    public let transitionSeconds: Double
    /// The look this piece alone wears, drawn before any transition blends it
    /// with its neighbour. Nil is none.
    ///
    /// ⚠️ **`.original` IS NEVER STORED — THE INITIALISER TURNS IT INTO NIL.**
    /// Two spellings of "no look" would make two identical pieces unequal, and
    /// `needsComposition` would build a compositor to draw nothing.
    public let look: LookPreset?

    public init(
        start: Double, end: Double, speed: Double = 1,
        transitionOut: VideoTransitionKind? = nil,
        transitionSeconds: Double = VideoTransitionKind.standardSeconds, look: LookPreset? = nil
    ) {
        self.start = start
        self.end = end
        self.speed = speed
        self.transitionOut = transitionOut
        self.transitionSeconds = transitionOut == nil || !transitionSeconds.isFinite
            ? VideoTransitionKind.standardSeconds : transitionSeconds
        self.look = look == .original ? nil : look
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
        segments.count > 1 || segments.contains { !$0.isAsShot || $0.look != nil }
    }

    /// Whether a plan needs a composition at all: its pieces do, or something
    /// is drawn over the finished film, or a song is laid under it.
    ///
    /// ⚠️ **A FINISH OR A SONG ON AN UNCUT CLIP STILL NEEDS ONE.** Otherwise the
    /// clip leaves by `timeRange` or passthrough, and both draw nothing — a
    /// filtered video would publish as shot, with no error anywhere.
    static func needsComposition(for plan: VideoExportPlan) -> Bool {
        needsComposition(for: plan.segments) || !plan.finish.isNone || plan.soundtrack != nil
    }

    /// How long a transition's two pieces OVERLAP, in played seconds: the
    /// window it draws in, and what it takes off the result.
    ///
    /// ⚠️ **ONE FUNCTION FOR THE TRACK, THE HIGHLIGHT, THE PREVIEW'S EQUALITY AND
    /// THE BUILDER.** Written twice, the lit window and the drawn blend would
    /// disagree the first time either changed.
    ///
    /// ⚠️ **WHAT THE AUTHOR ASKED FOR, AND NEVER MORE THAN HALF OF EITHER
    /// NEIGHBOUR.** A transition of `seconds` plays the last `seconds` of the
    /// piece before its cut over the first `seconds` of the piece after it, so
    /// each piece gives it that much of its own film. A piece gives each of its
    /// two transitions at most half of itself, so the two windows around it can
    /// meet and never cross — crossing windows would ask for three pictures at
    /// once, on two lanes. Floored to the composition's 1/600 grid, and nothing
    /// at all under two frames at 30fps, where a transition would be a flicker
    /// nobody chose.
    public static func transitionOverlap(
        _ kind: VideoTransitionKind?, seconds: Double = VideoTransitionKind.standardSeconds,
        outgoingPlayedSeconds outgoing: Double, incomingPlayedSeconds incoming: Double
    ) -> Double {
        guard kind != nil, seconds.isFinite, seconds > 0, outgoing.isFinite, incoming.isFinite,
              outgoing > 0, incoming > 0
        else { return 0 }
        let ticks = (min(seconds, outgoing / 2, incoming / 2) * 600).rounded(.down)
        return ticks < shortestOverlapTicks ? 0 : ticks / 600
    }

    /// Two frames at 30fps, in 1/600ths of a second: the shortest overlap drawn.
    static let shortestOverlapTicks: Double = 40

    /// One piece as the composition lays it.
    private struct Laid {
        /// The lane — 0 or 1 — its picture is on.
        let lane: Int
        /// The track its sound is on: one of two shared by the pieces as shot,
        /// or one of its own for a rated piece (`insertPieces`).
        let soundLane: Int
        /// Where its film starts on the composition's clock.
        let start: CMTime
        /// How long it plays there.
        let played: CMTime
        let look: LookPreset?

        var end: CMTime { start + played }
    }

    /// One transition, on the composition's own clock.
    private struct Cut {
        let kind: VideoTransitionKind
        /// Where the incoming piece starts: the window opens.
        let opens: CMTime
        /// The middle of the overlap — where a dip or a zoom changes piece, and
        /// where the track draws the cut.
        let at: CMTime
        /// Where the outgoing piece ends: the window closes.
        let closes: CMTime
        /// The piece before the cut; the one after it is `outgoing + 1`.
        let outgoing: Int
        /// Whether the two sounds cross — both pieces as shot, the only place a
        /// volume ramp is safe (`export-volume-ramp-hang`).
        let crossfades: Bool
    }

    /// The kept pieces, each at the rate it plays at, OVERLAPPING wherever a
    /// transition joins two of them.
    ///
    /// ⚠️ **BUILT HERE AND USED ONCE, WHICH IS THE ONLY WAY IT CAN EXIST.**
    /// `AVMutableComposition` and `AVMutableCompositionTrack` are explicitly
    /// `@_nonSendable` — the conformance is *unavailable*, measured with
    /// `-emit-sil` — so one can never be stored in a `Sendable` value or handed
    /// across an isolation boundary. That is why `VideoExportPlan` carries
    /// segment VALUES and not a composition.
    ///
    /// ⚠️ **TWO LANES, AND A PIECE CHANGES LANE ONLY ACROSS A TRANSITION.** Two
    /// pieces that overlap cannot share a track, so the picture after a
    /// transition goes on the other lane; across a plain cut it follows on the
    /// same one. (Its sound changes lane only where two sounds cross — below.) An arrangement with no transition is one lane,
    /// exactly as it was before overlaps existed — which is what lets it play
    /// with no video composition at all.
    ///
    /// ⚠️ **SCALED ON ITS OWN TWO TRACKS, NEVER ON THE COMPOSITION.** A
    /// composition-level `scaleTimeRange` rescales every track inside its range —
    /// here that would stretch the other lane's piece where the two overlap. A
    /// piece's picture and its sound are each scaled by the same call on their
    /// own track, so they keep one clock, and the other lane is not touched.
    ///
    /// ⚠️ **AND EVERY POSITION IS WORKED OUT IN TICKS, NEVER READ BACK.** A piece
    /// starts where the one before it ends less their overlap; the overlaps are
    /// measured on the composition's own lengths, so the two windows around a
    /// piece fit inside it without a second clamp — `floor(y/2) ==
    /// floor(floor(y)/2)`.
    ///
    /// ⚠️ **WHERE A RAMP IS NOT SAFE, THE SOUND IS CUT AT THE MIDDLE INSTEAD.** A
    /// volume ramp over a piece played at 3x or 4x has frozen the export for good
    /// (memory `export-volume-ramp-hang`). So across a transition that touches a
    /// rated piece the two sounds do not cross: the outgoing piece's sound is
    /// inserted up to the middle of the overlap and the incoming one's from it —
    /// an edit, with no automation at all, and each sound still exactly under
    /// its own picture.
    ///
    /// ⚠️ **AND A RATED PIECE'S SOUND HAS A TRACK OF ITS OWN, WITH NOTHING BEFORE
    /// IT.** A rate change on an audio track that has already played something
    /// is now and then LOST: the log says `AppendRateChange: scheduling rate
    /// change at unscaled t=16538, but we previously did a conversion for
    /// t=19456` — the line the export freeze left too — and the piece plays
    /// silent. Measured (12 exports each): a 3x piece whose sound followed
    /// 0.375s of its neighbour's on one track, cut at the middle, was silent 4
    /// times; after another piece's sound and a gap, silent in one read of
    /// three; after a plain cut, as before overlaps existed, 0 to 1 time. On a
    /// track of its own, empty up to it, 0 times in 12 in every one of those
    /// shapes. Pieces as shot share two tracks and change track only where two
    /// sounds cross, since only they ever ramp.
    private struct Inserted {
        let composition: AVMutableComposition
        let laid: [Laid]
        let cuts: [Cut]
        let video: [AVMutableCompositionTrack]
        let audio: [AVMutableCompositionTrack]
    }

    private static func insertPieces(
        of source: AVAssetTrack, audio sourceAudio: AVAssetTrack?,
        cut pieces: [VideoExportSegment]
    ) throws -> Inserted {
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        let ranges = pieces.map { CMTimeRange(start: time($0.start), end: time($0.end)) }
        let played = zip(pieces, ranges).map { piece, range in
            piece.isAsShot || piece.speed <= 0 ? range.duration : time(piece.sourceSeconds / piece.speed)
        }
        var overlaps: [CMTime] = []
        for index in pieces.indices.dropLast() {
            let seconds = transitionOverlap(
                pieces[index].transitionOut, seconds: pieces[index].transitionSeconds,
                outgoingPlayedSeconds: played[index].seconds, incomingPlayedSeconds: played[index + 1].seconds
            )
            // ⚠️ ROUNDED, NOT FLOORED: the value is already on the grid, and
            // flooring its product again loses a tick to the floating point.
            overlaps.append(CMTime(value: CMTimeValue((seconds * 600).rounded()), timescale: 600))
        }
        var lanes = [0]
        var starts = [CMTime.zero]
        for index in overlaps.indices {
            lanes.append(overlaps[index] > .zero ? 1 - lanes[index] : lanes[index])
            starts.append(starts[index] + played[index] - overlaps[index])
        }
        // Where each piece's sound goes: pieces as shot on lane 0 or 1, changing
        // only where two sounds cross; a rated piece on a track of its own.
        var sounds: [Int] = []
        var asShotLane = 0
        for index in pieces.indices {
            if index > 0, overlaps[index - 1] > .zero, pieces[index - 1].isAsShot, pieces[index].isAsShot {
                asShotLane = 1 - asShotLane
            }
            sounds.append(pieces[index].isAsShot ? asShotLane : 2 + index)
        }
        let used = Array(Set(sounds)).sorted()
        let soundLanes = sounds.map { used.firstIndex(of: $0) ?? 0 }
        var cuts: [Cut] = []
        for index in overlaps.indices where overlaps[index] > .zero {
            guard let kind = pieces[index].transitionOut else { continue }
            let opens = starts[index + 1]
            cuts.append(Cut(
                kind: kind, opens: opens,
                at: opens + CMTime(value: overlaps[index].value / 2, timescale: 600),
                closes: opens + overlaps[index], outgoing: index,
                crossfades: pieces[index].isAsShot && pieces[index + 1].isAsShot
            ))
        }

        let composition = AVMutableComposition()
        let laneCount = overlaps.contains { $0 > .zero } ? 2 : 1
        var video: [AVMutableCompositionTrack] = []
        var audio: [AVMutableCompositionTrack] = []
        for _ in 0..<laneCount {
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoExportError.exportFailed
            }
            video.append(track)
        }
        // A clip with no sound is ordinary — a screen recording, a muted export
        // — and an audio track it cannot fill would be left empty.
        for _ in used where sourceAudio != nil {
            guard let sound = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoExportError.exportFailed
            }
            audio.append(sound)
        }
        // ⚠️ **ONLY A RATED PIECE IS EVER SCALED.** A piece as shot plays its
        // own ticks, so its range and its length are the same number — and if a
        // rounding anywhere ever made them differ by one, a scaled edit of a 1x
        // sound on a shared lane, under a crossfade's ramp, is exactly the shape
        // `export-volume-ramp-hang` and the lost rate changes above forbid. It
        // is laid as it is instead.
        func place(
            _ range: CMTimeRange, of track: AVAssetTrack, on lane: AVMutableCompositionTrack,
            at start: CMTime, lasting target: CMTime, rated: Bool
        ) throws {
            if lane.timeRange.end < start {
                lane.insertEmptyTimeRange(CMTimeRange(start: lane.timeRange.end, end: start))
            }
            try lane.insertTimeRange(range, of: track, at: start)
            if rated, range.duration != target {
                lane.scaleTimeRange(CMTimeRange(start: start, duration: range.duration), toDuration: target)
            }
        }
        do {
            for (index, piece) in pieces.enumerated() {
                let rated = !piece.isAsShot && piece.speed > 0
                try place(
                    ranges[index], of: source, on: video[lanes[index]], at: starts[index],
                    lasting: played[index], rated: rated
                )
                let lane = soundLanes[index]
                guard let sourceAudio, audio.indices.contains(lane) else { continue }
                // Played time cut off this piece's sound at a cut that does not
                // cross-fade: from the window's opening to its middle (incoming),
                // from its middle to its close (outgoing).
                let head = cuts.first { $0.outgoing + 1 == index && !$0.crossfades }.map { $0.at - $0.opens } ?? .zero
                let tail = cuts.first { $0.outgoing == index && !$0.crossfades }.map { $0.closes - $0.at } ?? .zero
                // ⚠️ **IN TICKS, NEVER BACK THROUGH SECONDS.**
                // `CMTime(seconds:preferredTimescale:)` TRUNCATES: 55/600 of a
                // second comes back as 54/600, and so do 305 of the tick values
                // from 1 to 6000. Where an overlap is clamped by a rated
                // neighbour's half, a piece as shot then heard a tick more film
                // than it plays for, a tick early. As shot a trim is its own
                // ticks; rated, `CMTimeMultiplyByFloat64` rounds.
                func film(_ played: CMTime) -> CMTime {
                    rated ? CMTimeMultiplyByFloat64(played, multiplier: piece.speed) : played
                }
                let heard = CMTimeRange(
                    start: ranges[index].start + film(head), end: ranges[index].end - film(tail)
                )
                guard heard.duration > .zero else { continue }
                try place(
                    heard, of: sourceAudio, on: audio[lane], at: starts[index] + head,
                    lasting: played[index] - head - tail, rated: rated
                )
            }
        } catch {
            throw VideoExportError.exportFailed
        }
        let laid = pieces.indices.map {
            Laid(
                lane: lanes[$0], soundLane: soundLanes[$0], start: starts[$0], played: played[$0],
                look: pieces[$0].look
            )
        }
        return Inserted(composition: composition, laid: laid, cuts: cuts, video: video, audio: audio)
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
        /// The board the composition reads its whole look from, when it was
        /// built with one.
        var live: VideoLiveLook?
        /// Where the song and the film's own sound are, when a song is laid —
        /// what a playing item's levels are changed through.
        var sound: SoundtrackLayout? = nil

        /// What a preview reads its composed pictures from — nil when nothing
        /// is drawn.
        var composed: ComposedVideo? {
            videoComposition.map {
                ComposedVideo(asset: asset, tracks: videoTracks, composition: $0, live: live)
            }
        }
    }

    /// The kept pieces, each scaled to the rate it plays at, overlapping at every
    /// transition, with every transition drawn in its overlap.
    ///
    /// ⚠️ **ONE BUILDER FOR THE PREVIEW AND THE EXPORT** — the editor's canvas
    /// plays exactly what the post will be, transitions and sound included.
    ///
    /// ⚠️ **A TRANSITION OVERLAPS ITS TWO PIECES, AND THE RESULT IS THAT MUCH
    /// SHORTER.** Chosen by the author, over pictures that held still to keep
    /// the length: *"oui, chevauche les deux segments"*. The last `d` of the
    /// outgoing piece and the first `d` of the incoming one play at once, each
    /// real film at its own pace on its own lane, each over its own sound — so
    /// on a split of one continuous shot the two pictures are `d` apart and a
    /// dissolve is plainly seen (`insertPieces`).
    ///
    /// ⚠️ **THE INSTRUCTIONS TILE THE WHOLE DURATION ON THE COMPOSITION'S OWN
    /// CLOCK.** Cut times come from the laid pieces in ticks, never from a sum
    /// of source seconds; a set that ends one tick short renders in an image
    /// generator and FAILS THE EXPORT (-11841), and a gap renders black with no
    /// error at all.
    ///
    /// ⚠️ **EVERYTHING IS DRAWN BY `VideoCompositor`.** A custom compositor
    /// takes over the whole composition, so the dips and the zoom are its too —
    /// one drawing for every kind, in the preview and in the export — and so
    /// are the pieces' looks and the finish.
    ///
    /// ⚠️ **NO VIDEO COMPOSITION UNLESS SOMETHING IS DRAWN.** An arrangement with
    /// no transition, no look and no finish, from an upright source, is the
    /// composition it always was — no compositor in the way of the seams
    /// charter T12 measured.
    ///
    /// ⚠️ **EXCEPT UNDER A LIVE BOARD, WHICH ALWAYS COMPOSES.** `live` is the
    /// preview's promise that its look can change at any moment without a new
    /// item — including on a clip that wears nothing yet. An item left plain
    /// has no compositor to hand the next look to, and the author's first
    /// filter would reach the poster and never the playing picture.
    ///
    /// `longestSide` caps the composed picture — the preview's, which a phone
    /// screen shows at a fraction of a 4K frame's pixels. Nil composes at the
    /// source's own size, which is what an export must do.
    ///
    /// ⚠️ **AN UNCUT CLIP IS THE FILE ITSELF, UNLESS A SONG GOES UNDER IT.**
    /// Something drawn over it needs only a video composition over the file's
    /// own track; a song needs a composition to be laid into, so the clip is
    /// then built as one piece covering the whole of its picture.
    ///
    /// ⚠️ **THE SONG GOES IN AFTER THE PIECES ARE SCALED** — see
    /// `applySoundtrack`.
    static func arrangement(
        of asset: AVURLAsset, cut segments: [VideoExportSegment], orientation: OrientationRule,
        longestSide: CGFloat? = nil, soundtrack: VideoSoundtrack? = nil,
        finish: FrameFinish = .none, artwork: (any OverlayArtwork)? = nil, live: VideoLiveLook? = nil
    ) async throws -> Arrangement {
        guard let source = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }
        let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
        let preferred = (try? await source.load(.preferredTransform)) ?? .identity
        let natural = (try? await source.load(.naturalSize)) ?? .zero
        let shortestFrame = (try? await source.load(.minFrameDuration)) ?? .invalid
        let sourceRange = (try? await source.load(.timeRange)) ?? .invalid
        let upright = orientation == .always && !preferred.isIdentity
        let dressed = !finish.isNone || live != nil
        let canvas = Canvas(
            preferred: preferred, natural: natural, shortestFrame: shortestFrame,
            longestSide: longestSide, crop: finish.crop
        )
        let drawing = Drawing(canvas: canvas, finish: finish, artwork: artwork, live: live)

        if segments.isEmpty, soundtrack == nil {
            guard upright || dressed else {
                return Arrangement(asset: asset, videoComposition: nil, audioMix: nil, windows: [])
            }
            let duration = try await asset.load(.duration)
            let composition = try composed(
                pieces: [(Laid(lane: 0, soundLane: 0, start: .zero, played: duration, look: nil), source.trackID)],
                drawing: drawing, windows: [], duration: duration
            )
            return Arrangement(
                asset: asset, videoComposition: composition, audioMix: nil, windows: [],
                videoTracks: [source], live: live
            )
        }

        let kept = (segments.isEmpty ? [try await whole(range: sourceRange, of: asset)] : segments)
            .filter { $0.sourceSeconds > 0 }
        let inserted = try insertPieces(of: source, audio: sourceAudio, cut: kept)
        // ⚠️ THE TRANSFORM TRAVELS WITH THE PICTURES. Without it a clip a phone
        // recorded upright exports on its side — a composition track starts
        // with an identity transform whatever the source carried. (The
        // compositor turns the frames itself; this keeps a composition that
        // draws nothing upright for whoever plays it without one.)
        for lane in inserted.video { lane.preferredTransform = preferred }
        let composition = inserted.composition
        let duration = composition.duration
        let windows = inserted.cuts
        let steps = soundSteps(of: inserted.laid, cuts: windows, audio: inserted.audio)
        // ⚠️ HERE, AND NOT EARLIER: every piece is laid and scaled, and a song
        // is laid over the result's whole length, which is only known now.
        let music = try await applySoundtrack(
            soundtrack, to: composition, originals: inserted.audio, steps: steps
        )

        let looks = kept.map(\.look)
        guard !windows.isEmpty || upright || dressed || looks.contains(where: { $0 != nil }) else {
            return Arrangement(
                asset: composition, videoComposition: nil, audioMix: music?.mix, windows: [],
                sound: music?.layout
            )
        }
        let video = try composed(
            pieces: inserted.laid.map { ($0, inserted.video[$0.lane].trackID) },
            drawing: drawing, windows: windows, duration: duration
        )
        return Arrangement(
            asset: composition, videoComposition: video,
            audioMix: music?.mix ?? soundMix(steps: steps),
            windows: windows.map { $0.opens.seconds...$0.closes.seconds },
            videoTracks: composition.tracks(withMediaType: .video), live: live,
            sound: music?.layout
        )
    }

    /// The whole of a clip's picture, as one piece played as shot.
    ///
    /// ⚠️ **THE VIDEO TRACK'S RANGE, NOT THE ASSET'S LENGTH.** The asset lasts as
    /// long as its longest track, and a sound track that runs on past the
    /// picture would ask the video track for film it does not have.
    private static func whole(range: CMTimeRange, of asset: AVURLAsset) async throws -> VideoExportSegment {
        if range.isValid, range.duration.isNumeric, range.duration > .zero {
            return VideoExportSegment(start: range.start.seconds, end: range.end.seconds)
        }
        return VideoExportSegment(start: 0, end: try await asset.load(.duration).seconds)
    }

    /// How far the zoom goes at the cut.
    static let zoomThroughScale: CGFloat = 2

    /// The picture's geometry, worked out once per source.
    ///
    /// ⚠️ **THE ONE PLACE ORIENTATION AND SIZE ARE WORKED OUT** — the upright
    /// canvas the lanes are drawn on, and the render size the crop leaves of it.
    private struct Canvas {
        /// The upright picture, as the lanes are drawn and blended.
        let upright: CGSize
        /// What is rendered: the kept part of `upright`.
        let size: CGSize
        /// Upright, at the origin, in Core Image's y-up space.
        let orientation: CGAffineTransform
        let frame: CMTime

        init(
            preferred: CGAffineTransform, natural: CGSize, shortestFrame: CMTime, longestSide: CGFloat?,
            crop: FrameCrop
        ) {
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            let full = CGSize(width: abs(bounds.width).rounded(), height: abs(bounds.height).rounded())
            // ⚠️ THE CAP IS ON WHAT IS RENDERED, WHICH IS WHAT THE CROP KEEPS: a
            // square cut out of a 4K frame is composed at the cap, not at the
            // cap's share of the whole frame.
            let rendered = crop.isUntouched ? full : crop.outputSize(forUpright: full)
            // ⚠️ SCALED DOWN, NEVER UP, AND TO EVEN PIXELS — a 4:2:0 encoder and
            // the sample-buffer layer both want whole chroma samples.
            let longest = max(rendered.width, rendered.height)
            let factor = longestSide.map { longest > $0 && longest > 0 ? $0 / longest : 1 } ?? 1
            let size = factor < 1
                ? CGSize(
                    width: max(2, (full.width * factor / 2).rounded() * 2),
                    height: max(2, (full.height * factor / 2).rounded() * 2)
                )
                : full
            self.upright = size
            self.size = crop.isUntouched ? size : crop.outputSize(forUpright: size)
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

    /// Everything drawn over the film that does not change from one stretch
    /// to the next.
    private struct Drawing {
        let canvas: Canvas
        let finish: FrameFinish
        let artwork: (any OverlayArtwork)?
        let live: VideoLiveLook?
    }

    /// The video composition: the picture upright, each piece in its look,
    /// every transition drawn and the finish over it all, by `VideoCompositor`.
    ///
    /// ⚠️ **ONE INSTRUCTION PER STRETCH, SPLIT WHEREVER A PIECE STARTS OR ENDS
    /// AND AT THE MIDDLE OF EVERY WINDOW.** A stretch carries one look per lane,
    /// so one that ran across two pieces would dress the second in the first's
    /// look. A window opens where the incoming piece starts and closes where the
    /// outgoing one ends, so those marks are its edges; its middle is where a dip
    /// or a zoom changes piece.
    ///
    /// ⚠️ **INSIDE A WINDOW LANE A IS THE OUTGOING PIECE AND LANE B THE INCOMING
    /// ONE, EACH ON ITS OWN TRACK AND AT ITS OWN PACE.** Outside one, lane A is
    /// whichever track the one playing piece is on.
    private static func composed(
        pieces: [(laid: Laid, track: CMPersistentTrackID)], drawing: Drawing, windows: [Cut], duration: CMTime
    ) throws -> AVVideoComposition {
        let canvas = drawing.canvas
        // ⚠️ POSITIVE OR NOTHING: an item handed a zero render size or frame
        // duration raises an Objective-C exception rather than an error.
        guard canvas.size.width > 0, canvas.size.height > 0, duration > .zero, !pieces.isEmpty else {
            throw VideoExportError.exportFailed
        }
        func instruction(from start: CMTime, to end: CMTime) -> VideoCompositorInstruction {
            var scene = VideoCompositionScene(
                orientation: canvas.orientation, uprightSize: canvas.upright, renderSize: canvas.size,
                finish: drawing.finish
            )
            let laneA: CMPersistentTrackID
            var laneB: CMPersistentTrackID?
            if let cut = windows.first(where: { $0.opens <= start && start < $0.closes }) {
                let outgoing = pieces[cut.outgoing]
                let incoming = pieces[cut.outgoing + 1]
                scene.transition = .init(
                    kind: cut.kind, opens: cut.opens.seconds, cut: cut.at.seconds, closes: cut.closes.seconds
                )
                laneA = outgoing.track
                laneB = incoming.track
                scene.looks.a = outgoing.laid.look
                scene.looks.b = incoming.laid.look
            } else {
                let playing = pieces.last { $0.laid.start <= start } ?? pieces[0]
                laneA = playing.track
                scene.looks.a = playing.laid.look
            }
            return VideoCompositorInstruction(
                timeRange: CMTimeRange(start: start, end: end), laneA: laneA, laneB: laneB,
                scene: scene, artwork: drawing.artwork, live: drawing.live
            )
        }
        // ⚠️ THE MARKS TILE [0, duration] WITH NO GAP AND NO OVERLAP: every
        // stretch starts where the last one ended, on the composition's clock.
        let edges = pieces.flatMap { [$0.laid.start, $0.laid.end] } + windows.map(\.at)
        var marks: [CMTime] = []
        for mark in ([.zero, duration] + edges).filter({ $0 >= .zero && $0 <= duration }).sorted()
        where marks.last != mark {
            marks.append(mark)
        }
        let instructions = zip(marks, marks.dropFirst()).map { instruction(from: $0, to: $1) }

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

    /// One change to the level of the film's own sound, on one of its lanes —
    /// relative to the level the author left it at, 0...1.
    ///
    /// ⚠️ **A VALUE, SO THE SONG'S MIX CAN REBUILD THE SAME AUTOMATION** at the
    /// level the author left the original sound at, rather than inventing its
    /// own (`SoundtrackLayout.mix`).
    struct SoundStep: Sendable, Equatable {
        enum Shape: Sendable, Equatable {
            /// From `from` to `to` across `range`.
            case ramp(from: Float, to: Float, range: CMTimeRange)
            /// `level` from `at` on.
            case level(Float, at: CMTime)
        }

        let track: CMPersistentTrackID
        let shape: Shape
    }

    /// How the film's own sound crosses each transition.
    ///
    /// ⚠️ **ACROSS THE WHOLE OVERLAP, AND WITH THE PICTURE.** Most kinds cross
    /// the two sounds over the window, the outgoing one down as the incoming one
    /// comes up; a dip takes the outgoing sound down to silence by the middle and
    /// brings the incoming one up from it, as its picture goes through black or
    /// white.
    ///
    /// ⚠️ **NEVER ACROSS A PIECE THAT IS NOT AS SHOT — A RAMP THERE CAN FREEZE THE
    /// EXPORT FOR GOOD.** Measured on the iOS 26.5 simulator: a volume ramp at
    /// the start of a piece played at 3x or 4x left `AVAssetExportSession` with
    /// every remaker thread waiting and no error, once in twelve exports. Such a
    /// cut was never laid to cross (`insertPieces` cuts the two sounds at its
    /// middle), so it has no step here.
    ///
    /// ⚠️ **THE SECOND LANE IS SILENCED BEFORE ITS FIRST PIECE, NEVER ON IT.** A
    /// piece that arrives through a crossing must start from silence, and a
    /// ramp that opens on a track's very first sample does not do that: until
    /// the ramp takes hold, a track plays at the level it was left at — full,
    /// on a lane nothing has set yet. Measured: the incoming piece's first
    /// 25ms at full volume, a burst under every dissolve that put the heard
    /// pitch 80ms off its picture. So the lane is set to silence half way
    /// through the empty stretch before it is first heard: away from any
    /// piece's first sample, where the freeze was measured. After that a lane
    /// silenced by crossing out of it is only ever re-entered by crossing back
    /// into it, which ramps it up — pieces as shot change lane only where they
    /// cross (`insertPieces`) — and a rated piece's own track is never set at
    /// all, so no other level is ever needed.
    private static func soundSteps(
        of laid: [Laid], cuts: [Cut], audio: [AVMutableCompositionTrack]
    ) -> [SoundStep] {
        guard !audio.isEmpty else { return [] }
        var steps: [SoundStep] = []
        var heard = [Bool](repeating: false, count: audio.count)
        for (index, piece) in laid.enumerated() where audio.indices.contains(piece.soundLane) {
            let lane = piece.soundLane
            let track = audio[lane].trackID
            defer { heard[lane] = true }
            let arriving = cuts.first { $0.outgoing + 1 == index }
            let leaving = cuts.first { $0.outgoing == index }
            if let cut = arriving, cut.crossfades {
                if !heard[lane] {
                    steps.append(SoundStep(track: track, shape: .level(
                        0, at: CMTimeMultiplyByRatio(cut.opens, multiplier: 1, divisor: 2)
                    )))
                }
                if cut.kind.dipsTheSound {
                    steps.append(SoundStep(track: track, shape: .ramp(
                        from: 0, to: 0, range: CMTimeRange(start: cut.opens, end: cut.at)
                    )))
                    steps.append(SoundStep(track: track, shape: .ramp(
                        from: 0, to: 1, range: CMTimeRange(start: cut.at, end: cut.closes)
                    )))
                } else {
                    steps.append(SoundStep(track: track, shape: .ramp(
                        from: 0, to: 1, range: CMTimeRange(start: cut.opens, end: cut.closes)
                    )))
                }
            }
            if let cut = leaving, cut.crossfades {
                steps.append(SoundStep(track: track, shape: .ramp(
                    from: 1, to: 0,
                    range: CMTimeRange(start: cut.opens, end: cut.kind.dipsTheSound ? cut.at : cut.closes)
                )))
            }
        }
        return steps
    }

    /// The film's own sound, following `steps`; nil when nothing moves it.
    private static func soundMix(steps: [SoundStep]) -> AVAudioMix? {
        guard !steps.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = SoundStep.parameters(
            steps, tracks: Array(Set(steps.map(\.track))).sorted(), level: 1, stated: false
        )
        return mix
    }

    /// The whole clip, unchanged — what every caller asked for before a trim
    /// existed, kept so widening the requirement churned nothing.
    public func export(_ sourceURL: URL) async throws -> ExportedVideo {
        try await export(VideoExportPlan(sourceURL: sourceURL))
    }

    /// What the export session of `plan` is handed: its composition, the
    /// drawing over it and the mix — nil when the file leaves by a `timeRange`
    /// or as it is.
    ///
    /// ⚠️ **ONE CALL FOR THE EXPORT AND FOR THE TESTS THAT READ ITS PICTURES.**
    /// Reading these frames directly is reading what the session encodes,
    /// without paying for the encode; a copy of the call in a test would agree
    /// with `export` only until one of them changed.
    static func exportArrangement(of asset: AVURLAsset, for plan: VideoExportPlan) async throws -> Arrangement? {
        guard needsComposition(for: plan) else { return nil }
        return try await arrangement(
            of: asset, cut: plan.segments, orientation: .whenComposited,
            soundtrack: plan.soundtrack, finish: plan.finish, artwork: plan.artwork
        )
    }

    public func export(_ plan: VideoExportPlan) async throws -> ExportedVideo {
        let asset = AVURLAsset(url: plan.sourceURL)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
            throw VideoExportError.noVideoTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).mp4")

        // ⚠️ **ONE PIECE AT 1x NEVER BUILDS A COMPOSITION.** A `timeRange` on
        // the session is what a trim has always been, and a composition would be
        // a second reader, a second set of tracks and a second thing to get
        // wrong for a result that is identical. The composition exists for what
        // a `timeRange` CANNOT say: several pieces, a rate other than as-shot, a
        // look, something drawn over the film or a song under it.
        let needsComposition = Self.needsComposition(for: plan)
        let arranged = try await Self.exportArrangement(of: asset, for: plan)
        let subject: AVAsset = arranged?.asset ?? asset
        // ⚠️ **PASSTHROUGH DRAWS NOTHING, AND SAYS NOTHING.** It ignores a video
        // composition and an audio mix and still reports success — measured with
        // two tracks and no blend. A plan that asked for it gets this exporter's
        // own preset the moment something has to be drawn or mixed — and a song
        // counts even before its mix exists, since passthrough would drop it too.
        var presetName = plan.preset ?? preset
        let drawsOrMixes = arranged?.videoComposition != nil || arranged?.audioMix != nil
            || plan.soundtrack != nil
        if drawsOrMixes, presetName == AVAssetExportPresetPassthrough {
            presetName = preset == AVAssetExportPresetPassthrough ? AVAssetExportPreset1280x720 : preset
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
        } else if let arranged {
            // ⚠️ **A COMPOSITION IS BOUND TO ITS OWN LENGTH — WHICH CUTS NONE OF
            // ITS FILM, AND ENDS THE SOUND WITH THE PICTURES.** The time-pitch
            // pass hands a rated piece's sound back with a tail past the end of
            // its edit, and unbound the writer kept it: a 0.5x piece ending the
            // film published 160–165ms of silence after the last picture (and a
            // plain rated export 35–55ms), which a looping feed holds on a still
            // frame every time round.
            session.timeRange = CMTimeRange(start: .zero, duration: try await arranged.asset.load(.duration))
        }

        await session.export()
        guard session.status == .completed else {
            throw VideoExportError.exportFailed
        }

        // Natural size, transform-corrected so portrait clips report portrait.
        // ⚠️ **READ FROM THE OUTPUT, NOT THE SOURCE.** A crop changes how big
        // the pictures are, a composition bakes the turn into them, and the
        // preset may scale them down; only the written track knows what the
        // server will receive. The duration is read from the output too.
        let output = AVURLAsset(url: outputURL)
        guard let written = try? await output.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.exportFailed
        }
        let naturalSize = try await written.load(.naturalSize)
        let transform = try await written.load(.preferredTransform)
        let corrected = naturalSize.applying(transform)
        let width = Int(abs(corrected.width).rounded())
        let height = Int(abs(corrected.height).rounded())

        let duration = try await output.load(.duration)

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
