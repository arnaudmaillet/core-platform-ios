/// What the author has decided about each page of the editor, and the steps
/// the header's two arrows walk through those decisions.
///
/// ⚠️ **OUT OF THE SCREEN SO THE RULES CAN BE ASKED WITHOUT ONE.** "Absent
/// means untouched", "a drag is one step" and "a restored look goes live" were
/// rules inside `MediaEditorViewController`, and a rule inside a view
/// controller can only be checked by driving a view controller. The screen
/// keeps everything that DRAWS an edit — the redraws, the preview, the modes,
/// the arrows' enabled state — and asks this what there is to draw.
///
/// ⚠️ **A CLASS, NOT A VALUE, AND THE REASON IS THE MUTATE CLOSURE.** `change`
/// hands the caller's closure the page's edits to rewrite, and that closure
/// belongs to a mode that may read the host's edits while it runs. Held as a
/// struct in the screen, the whole of `change` would be one exclusive access to
/// the screen's property, and such a read would trap at runtime. Here each
/// read and each write is its own instant, exactly as it was when the
/// dictionary lived in the screen.
final class MediaEditSession {
    /// What the author has decided about each picture: how it is laid, the look
    /// it wears, and what is kept of it.
    ///
    /// ⚠️ **PER ITEM, NOT PER SCREEN.** Every one of those is a decision about
    /// ONE picture: a portrait shot and a landscape one in the same carousel want
    /// opposite answers, and a single screen-wide value would make choosing for
    /// one of them undo the choice for the other.
    ///
    /// ⚠️ **CARRIED TO THE PUBLISH PATH, AND BAKED THERE.** The editor's `onNext`
    /// hands this on, and the finalisation screen applies the crop and the look
    /// to the FULL-RESOLUTION picture it uploads — not to the preview. What is
    /// chosen here is therefore in the post, which is why nothing may quietly
    /// drop it.
    ///
    /// ⚠️ **AND ONLY WHAT WAS ACTUALLY CHOSEN IS IN HERE.** Reading with
    /// `edits[id, default: .untouched]` would write an entry for every page that
    /// merely scrolled past, and "nothing was changed, so nothing is carried"
    /// would stop being true — `nextHandsOnWhatWasChosenInTheOrderItWasChosen`
    /// pins it. Read through `edits(for:)`, write through `change(_:_:)`.
    private(set) var edits: [String: MediaEdits]

    /// What the two arrows in the header walk — see `MediaEditHistory`.
    private var history = MediaEditHistory<MediaEdits>()

    /// Where the drag under the finger began, filed by the first sample.
    ///
    /// ⚠️ **ONE SLOT, BECAUSE THERE IS ONE FINGER.** A second page cannot be
    /// dragged while this one is, and a page that changes under a held finger
    /// is not a thing the editor can do — so an id that does not match is a
    /// drag that ended without a lift, and the slot is simply taken over.
    private var pendingBefore: (id: String, state: MediaEdits)?

    /// ⚠️ **WHAT THE MEDIA ARRIVE WEARING, NOT A STEP.** The camera hands its
    /// captures over with the look and the shape the author chose while
    /// shooting; those are where the editing STARTS, so they are not in the
    /// history — a step back from the first change the author makes here
    /// lands on them, never behind them. Only edits that say something, about
    /// a page that is in `ids`, are kept, for `edits`'s own reason: an entry
    /// that says nothing is worse than none.
    init(initial: [String: MediaEdits] = [:], ids: [String]) {
        edits = initial.filter { id, edit in
            !edit.isUntouched && ids.contains(id)
        }
    }

    func edits(for id: String) -> MediaEdits { edits[id] ?? .untouched }

    /// Whether anything at all is stored for a page — the difference between
    /// "chose the default" and "never chose".
    func hasEdits(for id: String) -> Bool { edits[id] != nil }

    /// ⚠️ AN ENTRY THAT SAYS NOTHING IS WORSE THAN NO ENTRY: it makes "was this
    /// picture edited?" answerable two ways. Undoing every change removes the
    /// entry rather than storing a neutral one.
    /// ⚠️ **`settling: false` IS A CHANGE STILL UNDER A FINGER.** A ruler
    /// dragged across the screen writes sixty values a second; each one is a
    /// change, and none of them is a STEP. The mode that owns the finger is the
    /// only thing that knows, so it says — everything else settles by default.
    func change(_ id: String, settling: Bool = true, _ mutate: (inout MediaEdits) -> Void) {
        let before = edits[id] ?? .untouched
        var value = before
        mutate(&value)
        edits[id] = value.isUntouched ? nil : value
        guard settling else {
            // ⚠️ **THE STATE THE FINGER LANDED ON, KEPT UNTIL IT LIFTS.** Only
            // the FIRST sample of a drag holds it; every later one would file
            // the value the sample before it wrote, and the step the author
            // gets back would be one frame of their own gesture.
            if pendingBefore?.id != id { pendingBefore = (id, before) }
            return
        }
        // ⚠️ **AND A LIFT THAT WRITES THE VALUE ALREADY ON THE PAGE IS STILL
        // THE END OF A STEP.** A ruler's last sample and its settle carry the
        // same number, so recording from `before` here would compare the value
        // to itself, find no change, and file nothing — a drag across the whole
        // screen, and a back arrow that never lit.
        let opening = pendingBefore?.id == id ? (pendingBefore?.state ?? before) : before
        pendingBefore = nil
        history.record(opening, changingTo: value, for: id)
    }

    func canUndo(_ id: String) -> Bool { history.canUndo(id) }
    func canRedo(_ id: String) -> Bool { history.canRedo(id) }

    /// One step back through this page's own changes, put on the page — and
    /// what kind of change that was, or nil when there was no step to take.
    ///
    /// ⚠️ **THE WHOLE EDIT, NOT THE MODE'S PART OF IT.** The arrow that stood
    /// in the header used to undo "what this mode owns", so a step back meant
    /// something different depending on which tools happened to be open. A
    /// step is a change the author made; going back to it puts the page
    /// exactly where it was, whichever band they were in at the time.
    func undo(_ id: String) -> MediaEditKind? {
        guard let restored = history.undo(id, from: edits(for: id)) else { return nil }
        return restore(restored, on: id)
    }

    /// One step forward again — see `undo(_:)`.
    func redo(_ id: String) -> MediaEditKind? {
        guard let restored = history.redo(id, from: edits(for: id)) else { return nil }
        return restore(restored, on: id)
    }

    /// Puts a state back on the page and says what kind of change it was.
    ///
    /// ⚠️ **A RESTORED LOOK GOES LIVE; ANYTHING ELSE REBUILDS THE ITEM.**
    /// Rebuilding for a look would work and would be wrong twice over: the clip
    /// stutters where it does not have to, and the live path (`setLiveLook`)
    /// stops being exercised by the arrows at all. What decides is whether ANY
    /// field other than the look moved — written as a comparison rather than a
    /// list, so a field added to `MediaEdits` tomorrow lands on the safe side by
    /// itself. `.film` is the widest kind the screen has.
    private func restore(_ restored: MediaEdits, on id: String) -> MediaEditKind {
        let showing = edits(for: id)
        var asIfOnlyTheLookMoved = showing
        asIfOnlyTheLookMoved.filter = restored.filter
        asIfOnlyTheLookMoved.adjustments = restored.adjustments
        asIfOnlyTheLookMoved.effect = restored.effect
        edits[id] = restored.isUntouched ? nil : restored
        return asIfOnlyTheLookMoved == restored ? .look : .film
    }
}
