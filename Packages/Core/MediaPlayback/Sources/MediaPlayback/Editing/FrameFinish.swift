/// Everything done to a picture after its film is cut: the crop, the look over
/// the whole of it, and what is laid on top.
///
/// ⚠️ **ONE VALUE FOR THE PHOTO AND THE VIDEO.** A photograph is finished by
/// `MediaEdits.applied` in Upload and a clip by the compositor; both read this,
/// in the same order — crop, then look, then overlays — so the two cannot
/// disagree about what a finish means.
///
/// ⚠️ **A SEGMENT'S OWN FILTER IS NOT IN HERE.** It belongs to a piece of film
/// (`VideoExportSegment.look`) and is drawn before the transitions blend two
/// pieces; this is drawn once over the finished film.
public struct FrameFinish: Equatable, Sendable {
    public var crop: FrameCrop
    public var look: FrameLook
    /// Bottom first: the last one is drawn on top.
    public var overlays: [FrameOverlay]

    public init(crop: FrameCrop = .untouched, look: FrameLook = .neutral, overlays: [FrameOverlay] = []) {
        self.crop = crop
        self.look = look
        self.overlays = overlays
    }

    public static let none = FrameFinish()

    /// ⚠️ `==` AGAINST THE EMPTY VALUE, NOT A LIST OF FIELDS — see
    /// `FrameLook.isNeutral`.
    public var isNone: Bool { self == .none }
}
