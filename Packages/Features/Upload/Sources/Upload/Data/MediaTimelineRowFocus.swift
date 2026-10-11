/// Which row the timeline's tools have open, on which clip — a cut's
/// transition or a piece's filter — and the author's pause, which an open row
/// borrows and gives back.
///
/// ⚠️ **OUT OF THE SCREEN SO THE BORROW CAN BE ASKED WITHOUT ONE.** Opening a
/// row plays the stretch it is about whatever the author had asked for, and
/// closing it puts the author's choice back. That dance was written out in
/// four places in `MediaEditorViewController` — two openings, two closings —
/// and the rule that a toggle during the row WINS lived in a fifth. The screen
/// keeps the player calls, the tools and the loop ranges; this keeps the facts
/// they are decided from.
///
/// ⚠️ **POSITIONAL, AND SAFE ONLY BECAUSE NOTHING ELSE EDITS WHILE A ROW IS
/// OPEN.** The track takes no gesture while collapsed, the cut and rate actions
/// and the arrows are disabled, and every way off the clip closes the row
/// first.
struct MediaTimelineRowFocus: Equatable {
    /// The cut whose transition is being chosen: the one after piece `seam` of
    /// clip `id`.
    struct Transition: Equatable {
        let id: String
        var seam: Int
    }

    /// The piece whose filter is being chosen: piece `piece` of clip `id`.
    ///
    /// ⚠️ **RECORDED BEFORE THE TRACK COLLAPSES** — collapsing puts the held
    /// piece down, and the piece is what the row is open on.
    struct Piece: Equatable {
        let id: String
        var piece: Int
    }

    /// The transitions row's cut, while that row is open.
    var transition: Transition?

    /// The piece filter row's piece, while that row is open.
    var piece: Piece?

    /// ⚠️ **WHETHER THE AUTHOR STOPPED THE CLIP, AS OPPOSED TO THE TRACK.**
    /// Scrubbing stops playback and lets it go again, and without this the
    /// release would restart a clip the author had deliberately paused — their
    /// decision undone by a gesture that was only meant to move the film.
    /// `VideoTrimmerControl`'s example carries the same flag under the name
    /// `wasPlaying`, for the same moment.
    private(set) var pausedByAuthor = false

    /// Whether the author had stopped the clip when the row opened. The row
    /// plays its stretch whatever it was; closing it puts the author's choice
    /// back — unless they toggled playback meanwhile (nil).
    private var pausedBeforeRow: Bool?

    /// The clip a row is open on, the transitions row first.
    var focusedID: String? { transition?.id ?? piece?.id }

    /// The cut the transitions row is rehearsing — nil unless that row is open
    /// on the clip that is both in front of the author and playing.
    ///
    /// ⚠️ **READ LIVE, EVERY TIME.** A load that lands after the row closed must
    /// loop nothing, and one that lands on the next cut must loop that one.
    func rehearsedSeam(current: String?, playing: String?) -> Int? {
        guard let transition, transition.id == current, transition.id == playing else { return nil }
        return transition.seam
    }

    /// The piece the filter row is rehearsing, on the same terms as
    /// `rehearsedSeam`.
    func rehearsedPiece(current: String?, playing: String?) -> Int? {
        guard let piece, piece.id == current, piece.id == playing else { return nil }
        return piece.piece
    }

    /// A row has opened: the author's pause is put aside and the clip plays.
    mutating func borrowThePause() {
        pausedBeforeRow = pausedByAuthor
        pausedByAuthor = false
    }

    /// A choice in the row replays its stretch, without forgetting what the
    /// row will give back.
    mutating func rehearse() {
        pausedByAuthor = false
    }

    /// The author stopped or started the clip.
    ///
    /// ⚠️ **A TOGGLE DURING THE TRANSITIONS ROW WINS.** Closing it puts back the
    /// pause the author had before it opened — unless they have said something
    /// since. Only that row: a toggle while a piece's filter row is open keeps
    /// the borrowed pause, which is what the screen did before this type
    /// existed, kept as it was by a refactor that changes no behaviour.
    mutating func authorChose(paused: Bool) {
        pausedByAuthor = paused
        if transition != nil { pausedBeforeRow = nil }
    }

    /// A row has closed: the pause it borrowed becomes the author's again, or
    /// the author's own stands if nothing was borrowed. Returns it.
    mutating func giveBackThePause() -> Bool {
        let paused = pausedBeforeRow ?? pausedByAuthor
        pausedBeforeRow = nil
        pausedByAuthor = paused
        return paused
    }
}
