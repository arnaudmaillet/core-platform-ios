import UIKit

/// The one photograph every look card is drawn from while the page being edited
/// is a VIDEO — the filter chips (`MediaFilterRowView`) and the effect pills
/// (`MediaEffectsToolsView`) alike.
///
/// ⚠️ **A CLIP'S CARDS ARE NOT DRAWN FROM ITS OWN FILM, AND THAT IS THE WHOLE
/// POINT.** They used to be dressed from the clip's poster — the picture the
/// library vends for its first frame — and a poster is routinely black, blurred,
/// or one flat colour: a phone lifted before recording, a fade-in, a dark room.
/// Twelve effects and nine presets rendered over a flat frame draw twelve and
/// nine identical squares, so the row says nothing about what any of them does
/// and the author picks by name. A photograph's cards keep the author's own
/// picture, where "this is what tapping it will look like" is both true and
/// legible.
///
/// ⚠️ **AND THE AUTHOR'S CROP IS NEVER APPLIED TO IT.** A crop is a decision
/// about THEIR film; this photograph is not their film. Cutting it would throw
/// away the very parts of the spectrum it is here to carry — a square kept out
/// of the sky would leave nine blue chips — and it would claim to show a
/// framing that these pixels know nothing about. So the reference goes through
/// `MediaLookThumbnails.base(_:crop:pixels:)` with `.untouched`, while a
/// photograph's own picture is still cut by the page's crop exactly as before.
///
/// The picture is Zelenci, Slovenia, from Wikimedia Commons under CC0 1.0 —
/// `Resources/LookReference/README.md` has the source, the licence and why this
/// frame and no other.
enum MediaLookReference {
    /// Whether this page's cards are drawn from the reference photograph rather
    /// than from the page's own picture.
    ///
    /// ⚠️ **THE MEDIUM DECIDES, NOT THE PICTURE.** A poster frame that happens
    /// to be colourful is still a poster frame, and a photograph that happens to
    /// be flat is still the author's own: asking the item what it IS keeps the
    /// rule one line long and the same on every page, where guessing from the
    /// pixels would make a clip's cards change source as its first frame
    /// changed.
    static func standsIn(for item: MediaLibraryItem?) -> Bool { item?.isVideo == true }

    /// The photograph, or nil when the bundle has no such resource.
    ///
    /// ⚠️ **READ ONCE PER PROCESS, NOT ONCE PER CARD.** Twelve pills and nine
    /// chips are dressed from it on every settle and on every turn of a dial;
    /// decoding an 800×800 JPEG each time would put a file read on the path of
    /// a finger dragging a ruler. `static let` is lazy and runs once, whichever
    /// thread asks first.
    ///
    /// ⚠️ **NIL IS A BLANK CARD, NOT A CRASH** — so the callers fall back to
    /// the page's own picture, which is exactly the old behaviour, and the
    /// suite asserts the resource is really there
    /// (`MediaLookReferenceTests.theReferencePhotographIsInTheBundle`): a
    /// missing bundle resource is otherwise silent.
    static var picture: UIImage? { stored }

    private static let stored: UIImage? = {
        // ⚠️ **`Bundle.module` IS UPLOAD'S BUNDLE** — StickerKit's note, for the
        // same reason: the file is `.copy`'d as part of `Resources/LookReference`,
        // so it keeps its folder in the bundle and is addressed by subdirectory.
        guard let url = Bundle.module.url(
            forResource: "filter-reference", withExtension: "jpg", subdirectory: "LookReference"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()
}
