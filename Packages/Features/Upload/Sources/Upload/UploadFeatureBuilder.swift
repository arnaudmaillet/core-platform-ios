import FeedInterface
import UIKit

/// The screens behind the tab bar's "+" menu that belong to this package:
/// Upload Media and Text Post.
///
/// TEXT POST IS DRAWN BY FEED. It is a text post's own page, born empty — the
/// same header, stream, composer and footer — and the first message the viewer
/// sends is published as the post, which the page then becomes. Upload supplies
/// the part it owns: `PostComposer`, behind Feed's `TextPostPublishing`.
///
/// UPLOAD MEDIA IS THIS PACKAGE'S OWN SCREEN. It opens on the device library
/// (`MediaPickerViewController`), goes on to the editor
/// (`MediaEditorViewController`), which shows what was chosen full-bleed in the
/// order it was chosen and can lay each one filled or whole, and ends at
/// `NewPostViewController` — the cover, a title, a caption and the post's
/// settings — which publishes through `PostComposer`.
///
/// ⚠️ **THAT LAST SCREEN DRAWS MORE THAN THE CONTRACT CARRIES, ON PURPOSE.**
/// Of what it offers, only the media, their ORDER (the cover) and the caption
/// reach the server; the title and the six settings are honoured by the screen
/// alone and say so on it (`dev/BACKEND_GAPS.md` §21, §22). Read that screen's
/// own comment before wiring anything there to a field that does not exist.
@MainActor
public struct UploadFeatureBuilder {
    private let composer: any PostComposing
    /// A closure rather than a value, for the reason Chat's `threadScreens` is
    /// one: the composition root builds the feed builder lazily, and the feed
    /// builder reaches the router, which reaches back here.
    private let textPostScreens: () -> any TextPostScreenBuilding

    public init(
        composer: any PostComposing,
        textPostScreens: @escaping () -> any TextPostScreenBuilding
    ) {
        self.composer = composer
        self.textPostScreens = textPostScreens
    }

    /// "Upload Media" — photos and videos from the library.
    ///
    /// A sheet that opens to the top and stays there, showing the album as a
    /// three-column grid.
    public func makeMediaUploadViewController() -> UIViewController {
        // ⚠️ ONE LIBRARY FOR THE WHOLE FLOW, NOT ONE PER SCREEN. The Photos
        // implementation keeps the assets it fetched keyed by identifier, and
        // every thumbnail request looks its asset up in there — so an editor
        // handed a library of its own would be asking for pictures that library
        // has never fetched, and would draw nothing at all.
        let library = Self.makeLibrary()
        // ⚠️ **ONE DRAFT PER PRESENTATION, AND IT MUST BE BORN HERE.** The
        // finalisation screen is rebuilt on every "Next" — the closure below
        // constructs a fresh `NewPostViewController` each time — so a caption
        // typed before stepping back to the editor had nowhere to survive.
        //
        // Declared OUTSIDE both closures on purpose: inside, it would be made
        // again on every call and would reproduce the very bug it fixes while
        // looking exactly like the fix. It lives as long as this sheet and dies
        // with it — session-scoped, nothing on disk, nothing global.
        let draft = PostDraft()
        let picker = MediaPickerViewController(library: library) { chosen in
            MediaEditorViewController(items: chosen, library: library) { editing, fits in
                // ⚠️ THE SCREEN DISMISSES ITSELF. This closure cannot reach the
                // navigation controller — it is built below, after the picker
                // that owns this one — and a published post is broadcast on
                // `ComposedPostChannel`, so the feed already has it and nobody
                // here needs telling.
                NewPostViewController(
                    items: editing, fits: fits, library: library, composer: composer,
                    draft: draft
                ) { _ in }
            }
        }
        // ⚠️ NOT A PLAIN `UINavigationController`: UIKit's full-width back-swipe
        // would let a drag anywhere on the screen leave the flow, and this one is
        // wanted from the window's edge only. See `UploadNavigationController`.
        let navigation = UploadNavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            // ONE DETENT, AND THE FLOW IS SIMPLER FOR IT. The picker used to
            // offer a resting height of a single album row and open from there;
            // it now opens to the top and stays, so there is no second height to
            // travel to, nothing to expand when the album is scrolled at its
            // edge, and no custom detent to resolve.
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    /// "Text Post" — a post with no media, written on its own page.
    public func makeTextPostViewController() -> UIViewController {
        textPostScreens().makeTextPostScreen(publisher: ComposerTextPostPublisher(composer: composer))
    }

    private static func pendingMessage(for chosen: [MediaLibraryItem]) -> String {
        let videos = chosen.filter(\.isVideo).count
        let photos = chosen.count - videos
        var parts: [String] = []
        if photos > 0 {
            parts.append(photos == 1 ? "1 photo" : "\(photos) photos")
        }
        if videos > 0 {
            parts.append(videos == 1 ? "1 video" : "\(videos) videos")
        }
        let what = parts.joined(separator: " and ")
        return "\(what), in the order you chose. Writing the caption and publishing comes next."
    }

    /// The real library, unless a DEBUG build was asked for a made-up one.
    ///
    /// `-upload-fake-library <count>` stands in a synthetic library, for the
    /// reason `-mock-compose-demo` draws its own gradient: a simulator's own
    /// library is six stock images deep, which is too few to photograph a
    /// numbered selection or a tray that scrolls.
    private static func makeLibrary() -> any MediaLibraryReading {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-upload-fake-library"),
           arguments.count > flag + 1,
           let count = Int(arguments[flag + 1]) {
            return DebugMediaLibrary(count: count)
        }
        #endif
        return PhotosMediaLibrary()
    }
}
