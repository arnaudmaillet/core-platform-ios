import Foundation

/// What the author has written and chosen, kept for as long as they are still in
/// the flow.
///
/// ⚠️ **THE FINALISATION SCREEN IS REBUILT EVERY TIME "NEXT" IS PRESSED.**
/// `UploadFeatureBuilder` hands the editor a closure that constructs a fresh
/// `NewPostViewController(items:fits:library:composer:)`, so going back pops that
/// screen and destroys it, and coming forward again builds a new one. A caption
/// typed before stepping back was never lost — it had nowhere to survive.
///
/// ⚠️ **A REFERENCE TYPE, AND WRITTEN AS THE AUTHOR TYPES.** The alternative —
/// snapshotting state in `viewWillDisappear` — misses every disappearance that is
/// not a clean transition, which is the exact path that breaks today. The screen
/// writes here at the same moments it writes its own properties, so there is no
/// second source of truth to keep in step.
///
/// ⚠️ **SESSION-SCOPED ON PURPOSE.** One instance is made where the flow's
/// closures are built, so it lives exactly as long as the sheet and dies with it.
/// Nothing is written to disk and nothing is held globally — "keep the state
/// locally, do not store it at the application level" was the standing
/// instruction, and a draft that outlived the sheet would break it.
///
/// `PostDraftStore` is a different thing entirely and must not be confused with
/// this: it holds TEXT posts, and the "Save draft" button on this screen is drawn
/// and inert because media drafts do not exist yet.
@MainActor
final class PostDraft {
    var title = ""
    var caption = ""
    var settings = NewPostViewController.Settings()

    /// ⚠️ **`nil` MEANS "THE AUTHOR NEVER CHOSE", NOT "NO COVER".** The screen's
    /// initialiser picks the first photo as a default, so a draft that stored
    /// that default could not be told apart from a real choice — and restoring it
    /// would be indistinguishable either way. Only an explicit pick is recorded,
    /// and the screen falls back to its own default when this is empty.
    var coverID: String?

    /// The songs the editor imported for this post — the files themselves.
    ///
    /// ⚠️ **HERE, AND NOT IN THE EDITOR, SO THEY OUTLIVE PUBLISHING.** The
    /// export reads a song while "Post" is working, and the sheet — with this
    /// draft — is dismissed only once the post is out. The files are deleted
    /// when the draft goes.
    let soundtrackFiles = TempFileBag()

    /// What the camera captured for this post — photographs, clips and the
    /// video a take is stitched into.
    ///
    /// ⚠️ **HERE FOR `soundtrackFiles`' REASON.** The editor and the
    /// finalisation screen both read these files, and publishing reads them
    /// last; the folder is removed when the draft goes, which is when the sheet
    /// does. See `CaptureFolder`.
    let captureFolder = CaptureFolder()

    init() {}
}
