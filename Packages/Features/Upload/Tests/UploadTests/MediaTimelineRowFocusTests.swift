import Testing
@testable import Upload

/// Which row the timeline has open, and the author's pause it borrows, without
/// a screen or a player.
///
/// ⚠️ **THE PLAYER CALLS ARE THE EDITOR'S TESTS'.** These pin the facts the
/// screen decides them from: what a row borrows on opening, what it gives back
/// on closing, and which clip a rehearsal answers for.
struct MediaTimelineRowFocusTests {
    @Test func nothingIsOpenAndNothingIsPausedAtFirst() {
        let focus = MediaTimelineRowFocus()

        #expect(focus.transition == nil)
        #expect(focus.piece == nil)
        #expect(focus.focusedID == nil)
        #expect(!focus.pausedByAuthor)
        #expect(focus.rehearsedSeam(current: "clip", playing: "clip") == nil)
        #expect(focus.rehearsedPiece(current: "clip", playing: "clip") == nil)
    }

    /// ⚠️ **THE ROW PLAYS ITS STRETCH, AND CLOSING PUTS THE AUTHOR'S CHOICE
    /// BACK.**
    @Test func aRowPlaysTheClipAndGivesTheAuthorsPauseBackWhenItCloses() {
        var focus = MediaTimelineRowFocus()
        focus.authorChose(paused: true)

        focus.transition = .init(id: "clip", seam: 0)
        focus.borrowThePause()
        #expect(!focus.pausedByAuthor, "the row plays whatever the author had asked for")

        focus.transition = nil
        let givenBack = focus.giveBackThePause()
        #expect(givenBack)
        #expect(focus.pausedByAuthor)
    }

    @Test func aChoiceInTheRowReplaysWithoutForgettingWhatToGiveBack() {
        var focus = MediaTimelineRowFocus()
        focus.authorChose(paused: true)
        focus.piece = .init(id: "clip", piece: 1)
        focus.borrowThePause()

        focus.rehearse()
        #expect(!focus.pausedByAuthor)

        focus.piece = nil
        let givenBack = focus.giveBackThePause()
        #expect(givenBack, "the pause from before the row comes back")
    }

    /// ⚠️ **A TOGGLE DURING THE TRANSITIONS ROW WINS.** The author said
    /// something since the row opened, and closing it must not overrule them.
    @Test func aToggleDuringTheTransitionsRowWinsOverTheBorrowedPause() {
        var focus = MediaTimelineRowFocus()
        focus.transition = .init(id: "clip", seam: 2)
        focus.borrowThePause()

        focus.authorChose(paused: true)
        focus.transition = nil

        let givenBack = focus.giveBackThePause()
        #expect(givenBack)
        #expect(focus.pausedByAuthor)
    }

    /// ⚠️ **A TOGGLE DURING THE FILTER ROW WINS TOO** (#869). A pause made
    /// while a piece's filter row is open must survive the row closing.
    @Test func aToggleDuringThePieceRowWinsOverTheBorrowedPause() {
        var focus = MediaTimelineRowFocus()
        focus.piece = .init(id: "clip", piece: 1)
        focus.borrowThePause()

        focus.authorChose(paused: true)
        focus.piece = nil

        let givenBack = focus.giveBackThePause()
        #expect(givenBack, "closing the filter row undid the author's pause")
        #expect(focus.pausedByAuthor)
    }

    /// The other way round: the author had stopped the clip, the row played
    /// it, and the author started it again — closing must not stop it.
    @Test func aPlayDuringThePieceRowWinsOverTheBorrowedPause() {
        var focus = MediaTimelineRowFocus()
        focus.authorChose(paused: true)
        focus.piece = .init(id: "clip", piece: 0)
        focus.borrowThePause()

        focus.authorChose(paused: true)
        focus.authorChose(paused: false)
        focus.piece = nil

        let givenBack = focus.giveBackThePause()
        #expect(!givenBack, "closing the filter row stopped a clip the author had started")
        #expect(!focus.pausedByAuthor)
    }

    @Test func closingWithNothingBorrowedKeepsTheAuthorsOwnPause() {
        var focus = MediaTimelineRowFocus()
        focus.authorChose(paused: true)

        let givenBack = focus.giveBackThePause()
        #expect(givenBack)
        #expect(focus.pausedByAuthor)
    }

    /// ⚠️ **A REHEARSAL ANSWERS ONLY FOR THE CLIP IN FRONT THAT IS PLAYING.** A
    /// load landing after a swipe, or on a clip that is not playing, loops
    /// nothing.
    @Test func aRehearsalAnswersOnlyForTheCurrentPlayingClip() {
        var focus = MediaTimelineRowFocus()
        focus.transition = .init(id: "clip", seam: 3)

        #expect(focus.rehearsedSeam(current: "clip", playing: "clip") == 3)
        #expect(focus.rehearsedSeam(current: "other", playing: "clip") == nil)
        #expect(focus.rehearsedSeam(current: "clip", playing: nil) == nil)
        #expect(focus.rehearsedPiece(current: "clip", playing: "clip") == nil)

        focus.transition = nil
        focus.piece = .init(id: "clip", piece: 1)
        #expect(focus.rehearsedPiece(current: "clip", playing: "clip") == 1)
        #expect(focus.rehearsedPiece(current: "clip", playing: "other") == nil)
    }

    @Test func theFocusedClipIsTheOpenRows() {
        var focus = MediaTimelineRowFocus()
        focus.piece = .init(id: "piece-clip", piece: 0)
        #expect(focus.focusedID == "piece-clip")

        focus.transition = .init(id: "cut-clip", seam: 0)
        #expect(focus.focusedID == "cut-clip", "the transitions row is asked first")
    }
}
