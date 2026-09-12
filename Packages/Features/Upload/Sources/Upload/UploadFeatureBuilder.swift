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
/// (`MediaPickerViewController`), and the step that writes a caption and
/// publishes is still a stand-in — the picker hands it what was chosen, in the
/// order it was chosen. Whatever that step becomes, it publishes through
/// `PostComposer` too.
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
    /// A sheet that rests on a single row of the album and opens into the whole
    /// grid. The resting detent is the screen's own, because only the screen
    /// knows how tall one row is and whether the tray is up;
    /// `MediaPickerViewController` says why the album changes axis with it.
    public func makeMediaUploadViewController() -> UIViewController {
        let picker = MediaPickerViewController(library: Self.makeLibrary()) { chosen in
            PendingScreenViewController(
                title: "New Post",
                message: Self.pendingMessage(for: chosen),
                showsClose: false
            )
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [picker.makeRestingDetent(), .large()]
            sheet.selectedDetentIdentifier = MediaPickerViewController.restingDetentIdentifier
            sheet.prefersGrabberVisible = true
            // ⚠️ OFF, OR THE SHEET OPENS ITSELF. A sheet expands to its largest
            // detent when the scroll view it tracks is scrolled at its edge, and
            // the picker sets the grid's offset itself as soon as an album
            // lands — which reads to UIKit as exactly that scroll. The album
            // opens the sheet only when the viewer drags it.
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
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
