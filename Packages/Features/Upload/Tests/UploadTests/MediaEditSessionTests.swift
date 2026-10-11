import Testing
@testable import Upload

/// What each page of the editor carries, and the steps the header's arrows
/// walk, without a screen.
///
/// ⚠️ **THE HISTORY'S OWN ARITHMETIC IS `MediaEditHistoryTests`'.** These pin
/// what the session adds on top: "absent means untouched", a drag filed as one
/// step, the arrival edits that are not steps, and the look-or-film answer a
/// restore gives the screen.
struct MediaEditSessionTests {
    private func session(_ initial: [String: MediaEdits] = [:]) -> MediaEditSession {
        MediaEditSession(initial: initial, ids: ["one", "two"])
    }

    @Test func aPageNobodyTouchedCarriesNothing() {
        let edits = session()

        #expect(edits.edits(for: "one") == .untouched)
        #expect(!edits.hasEdits(for: "one"))
        #expect(edits.edits.isEmpty)
        #expect(!edits.canUndo("one"))
    }

    @Test func aChangeIsCarriedAndIsAStep() {
        let edits = session()
        edits.change("one") { $0.filter = .noir }

        #expect(edits.edits(for: "one").filter == .noir)
        #expect(edits.hasEdits(for: "one"))
        #expect(edits.canUndo("one"))
        #expect(!edits.canUndo("two"), "the history is per page")
    }

    /// ⚠️ **AN ENTRY THAT SAYS NOTHING IS WORSE THAN NO ENTRY.** Changing a page
    /// back to neutral removes it, so "was this edited?" has one answer.
    @Test func aChangeBackToNeutralRemovesTheEntry() {
        let edits = session()
        edits.change("one") { $0.fit = .fit }
        edits.change("one") { $0.fit = .fill }

        #expect(!edits.hasEdits(for: "one"))
        #expect(edits.edits.isEmpty)
        #expect(edits.canUndo("one"), "going back to neutral is still a step")
    }

    /// ⚠️ **A DRAG IS ONE STEP, AND IT GOES BACK TO WHERE THE FINGER LANDED.**
    @Test func aDragIsFiledAsOneStepFromWhereItBegan() {
        let edits = session()
        edits.change("one", settling: false) { $0.filter = .chrome }
        edits.change("one", settling: false) { $0.filter = .fade }

        #expect(!edits.canUndo("one"), "nothing is a step while the finger is down")

        edits.change("one") { $0.filter = .mono }
        #expect(edits.undo("one") != nil)
        #expect(edits.edits(for: "one") == .untouched)
        #expect(!edits.canUndo("one"), "the whole drag was a single step")
    }

    /// ⚠️ **A LIFT THAT WRITES THE LAST SAMPLE'S VALUE STILL ENDS THE STEP.** A
    /// ruler's last sample and its settle carry the same number.
    @Test func aLiftOnTheLastSamplesValueStillFilesTheStep() {
        let edits = session()
        edits.change("one", settling: false) { $0.filter = .tonal }
        edits.change("one") { $0.filter = .tonal }

        #expect(edits.canUndo("one"))
        #expect(edits.undo("one") != nil)
        #expect(edits.edits(for: "one") == .untouched)
    }

    @Test func whatIsSteppedBackFromCanBeSteppedForwardInto() {
        let edits = session()
        edits.change("one") { $0.filter = .noir }

        #expect(edits.undo("one") != nil)
        #expect(!edits.hasEdits(for: "one"))
        #expect(edits.canRedo("one"))
        #expect(edits.redo("one") != nil)
        #expect(edits.edits(for: "one").filter == .noir)
        #expect(edits.undo("two") == nil, "a page with no step has nothing to undo")
        #expect(edits.redo("two") == nil)
    }

    /// ⚠️ **WHAT THE MEDIA ARRIVE WEARING IS WHERE EDITING STARTS, NOT A STEP.**
    /// And only what says something, about a page that is here, is kept.
    @Test func theArrivalEditsAreCarriedButAreNotSteps() {
        var worn = MediaEdits()
        worn.filter = .instant
        let edits = session(["one": worn, "two": .untouched, "gone": worn])

        #expect(edits.edits(for: "one") == worn)
        #expect(!edits.canUndo("one"))
        #expect(!edits.hasEdits(for: "two"), "a neutral arrival is no entry")
        #expect(edits.edits.keys.sorted() == ["one"], "a page not in the selection is dropped")

        edits.change("one") { $0.filter = .noir }
        #expect(edits.undo("one") != nil)
        #expect(edits.edits(for: "one") == worn, "a step back lands on the arrival, never behind it")
    }

    /// ⚠️ **A RESTORED LOOK GOES LIVE; ANYTHING ELSE REBUILDS THE ITEM.**
    @Test func aRestoreThatOnlyMovesTheLookSaysLook() {
        let edits = session()
        edits.change("one") { $0.filter = .noir }

        #expect(edits.undo("one") == .look)
        #expect(edits.redo("one") == .look)
    }

    @Test func aRestoreThatMovesAnythingElseSaysFilm() {
        let edits = session()
        edits.change("one") {
            $0.filter = .noir
            $0.fit = .fit
        }

        #expect(edits.undo("one") == .film)
        #expect(edits.redo("one") == .film)
    }

    /// ⚠️ **THE MUTATE CLOSURE MAY READ THE SESSION.** A mode's closure can ask
    /// the host for the page's edits while it runs; the session must not hold
    /// an access across the call.
    @Test func aChangeMayReadTheSessionWhileItRuns() {
        let edits = session()
        edits.change("two") { $0.fit = .fit }
        edits.change("one") { $0.fit = edits.edits(for: "two").fit }

        #expect(edits.edits(for: "one").fit == .fit)
    }
}
