import CoreModels
import Testing
import UIKit
@testable import Upload

/// **THE LAST SCREEN DRAWS MORE THAN THE CONTRACT CARRIES, AND THAT IS THE
/// POINT OF THESE.** Of everything the author can set here, only the media,
/// their ORDER and the caption reach the server. The title and the six settings
/// are honoured by the screen alone (`dev/BACKEND_GAPS.md` §21, §22) — so what
/// is pinned below is exactly that boundary: what goes, what stays, and the fact
/// that the screen says which is which.
@MainActor
struct NewPostTests {
    private struct Screen {
        let post: NewPostViewController
        let navigation: UINavigationController
        let window: UIWindow
        let library: StubLibrary
        let composer: RecordingComposer
        let handed: Handed
    }

    /// ⚠️ `@MainActor` IS STATED, NOT INHERITED — a nested type does not take the
    /// enclosing suite's isolation, and this holds a main-actor value.
    @MainActor
    private final class Handed {
        var entry: FeedEntry?
    }

    /// Records what it was ASKED FOR, which is how the publish order is proved:
    /// `post()` fetches each image at publish size, one at a time, in the order
    /// the carousel will carry them.
    private final class StubLibrary: MediaLibraryReading {
        private(set) var requests: [(id: String, size: CGSize)] = []

        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        /// Nothing to present against a stub — the seam exists so the picker can
        /// offer the system sheet without importing `Photos`.
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            requests.append((item, size))
            return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        }

        /// The strip asks small and the publish loop asks large, so the large
        /// ones are the post itself.
        var publishedIDs: [String] { requests.filter { $0.size.width >= 1000 }.map(\.id) }
    }

    private actor RecordingComposer: PostComposing {
        struct Call: Sendable {
            let mediaCount: Int
            let caption: String
        }

        private(set) var calls: [Call] = []

        func publish(
            media: [ComposeMedia], caption: String, as author: AuthorSummary?
        ) async throws -> FeedEntry {
            calls.append(Call(mediaCount: media.count, caption: caption))
            let by = author ?? AuthorSummary(
                id: ProfileID("first"), handle: "first", displayName: "First", avatarURL: nil
            )
            return FeedEntry(
                post: Post(
                    id: PostID("new"), authorID: by.id, caption: caption,
                    attachments: [], publishedAt: Date()
                ),
                author: by
            )
        }
    }

    /// `photo-N` unless the index is named a video.
    private static func items(_ count: Int, videosAt videoIndexes: Set<Int> = []) -> [MediaLibraryItem] {
        (0..<count).map { index in
            let isVideo = videoIndexes.contains(index)
            return MediaLibraryItem(
                id: isVideo ? "video-\(index)" : "photo-\(index)",
                kind: isVideo ? .video(duration: 9) : .photo
            )
        }
    }

    private func open(
        _ items: [MediaLibraryItem],
        fits: [String: ContentFit] = [:]
    ) -> Screen {
        let library = StubLibrary()
        let composer = RecordingComposer()
        let handed = Handed()
        let post = NewPostViewController(
            items: items, fits: fits, library: library, composer: composer
        ) { handed.entry = $0 }
        let navigation = UINavigationController(rootViewController: post)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return Screen(
            post: post, navigation: navigation, window: window,
            library: library, composer: composer, handed: handed
        )
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The bars

    /// The bar is `[‹][Save draft] ——— [Post]` and nothing else: a centred title
    /// competes with the two words either side of it on a phone.
    @Test func theScreenCarriesNoTitleOfItsOwn() throws {
        let screen = open(Self.items(2))

        #expect(screen.post.title == nil, "no 'New post' in the middle of the bar")
        // ⚠️ THE CHEVRON IS UIKit'S — see `MediaEditorTests`. The flag is what
        // makes "Save draft" sit BESIDE the back button rather than in its place,
        // and the back-swipe survives only while it is set.
        let left = try #require(screen.post.navigationItem.leftBarButtonItems)
        #expect(left.map(\.title) == ["Save draft"], "the draft alone; the chevron is the system's")
        #expect(screen.post.navigationItem.leftItemsSupplementBackButton)
        #expect(screen.post.navigationItem.rightBarButtonItems?.map(\.title) == ["Post"])
    }

    // MARK: - The cover

    /// ⚠️ NOT SIMPLY THE FIRST ITEM. Only photos publish, so if the viewer's
    /// first pick is a video the cover is the first PHOTO — otherwise the strip
    /// would badge a cover the feed never shows.
    @Test func theCoverIsTheFirstPhotoEvenWhenAVideoWasChosenFirst() {
        let screen = open(Self.items(3, videosAt: [0]))

        #expect(screen.post.debugCoverID == "photo-1")
        #expect(screen.post.debugPublishOrder.first == "photo-1", "and it leads the carousel")
    }

    @Test func choosingACoverMovesItToTheFrontAndKeepsTheRestInOrder() {
        let screen = open(Self.items(4))

        screen.post.debugSetCover("photo-2")

        #expect(screen.post.debugCoverID == "photo-2")
        #expect(
            screen.post.debugPublishOrder == ["photo-2", "photo-0", "photo-1", "photo-3"],
            "the cover leads; everything else keeps the order it was chosen in"
        )
    }

    /// A video cannot be published, so offering one as the cover would promise a
    /// face for the post that never arrives.
    @Test func theCoverMenuOffersPhotosOnly() {
        let screen = open(Self.items(4, videosAt: [1, 3]))

        let choices = screen.post.debugCoverMenu().children

        #expect(choices.count == 2, "two photos among four items: \(choices.map(\.title))")
    }

    // MARK: - What actually gets published

    /// ⚠️ **THE ORDER IS PROVED FROM THE REAL LOOP.** `post()` asks the library
    /// for each image at publish size, one at a time, in carousel order — so the
    /// ids it asked for ARE the order, rather than a re-reading of the same
    /// property the screen used.
    @Test func thePostIsFetchedCoverFirstInCarouselOrder() async throws {
        let screen = open(Self.items(3))
        screen.post.debugSetCover("photo-2")

        screen.post.debugTapPost()
        try await settle(until: { screen.library.publishedIDs.count == 3 })

        #expect(screen.library.publishedIDs == ["photo-2", "photo-0", "photo-1"])
    }

    @Test func videosAreLeftBehindRatherThanPublishedEmpty() async throws {
        let screen = open(Self.items(4, videosAt: [1, 2]))

        screen.post.debugTapPost()
        // ⚠️ WAITING ON THE HAND-BACK, NOT ON THE COMPOSER. `settle(until:)` takes
        // a SYNCHRONOUS condition and the composer is an actor, so reading its
        // calls inside one cannot compile — and `onPublished` firing is the real
        // "it finished" signal anyway.
        try await settle(until: { screen.handed.entry != nil })

        #expect(screen.library.publishedIDs == ["photo-0", "photo-3"], "the videos were never fetched")
        let calls = await screen.composer.calls
        #expect(calls.first?.mediaCount == 2, "and only the photos reached the composer")
    }

    /// ⚠️ **THE REGRESSION §21 EXISTS FOR.** Folding the title into the caption
    /// would publish a composite string no reader could split apart again — so
    /// the caption that goes must be the caption that was typed, and nothing more.
    @Test func theTitleIsHeldOnTheScreenAndNeverPublished() async throws {
        let screen = open(Self.items(1))
        screen.post.debugType(title: "A title nobody will see")
        screen.post.debugType(caption: "The caption")

        screen.post.debugTapPost()
        try await settle(until: { screen.handed.entry != nil })

        #expect(screen.post.debugTitle == "A title nobody will see", "the screen keeps it")
        let calls = await screen.composer.calls
        #expect(calls.first?.caption == "The caption", "and sends only the caption")
    }

    // MARK: - The settings

    @Test func theSettingsStartWhereAPostWouldWantThem() {
        let screen = open(Self.items(1))

        let settings = screen.post.debugSettings

        // ⚠️ EVERY ENGAGEMENT SWITCH RESTS ON. Phrased as "Show …" the resting
        // position IS the behaviour; the old "Hide …" wording defaulted OFF and
        // meant the opposite of what the row said.
        #expect(settings.comments == .enabled)
        #expect(settings.showsPoints)
        #expect(settings.showsReposts)
        #expect(settings.showsBookmarks)
        #expect(settings.allowsDownloads)
        // The one exception, and it is not an engagement control: a post must
        // not claim to be AI-generated unless the author says so.
        #expect(settings.disclosesAI == false)
    }

    @Test func aChosenCommentPolicyIsHeldForTheLengthOfTheCompose() {
        let screen = open(Self.items(1))

        screen.post.debugSetComments(.disabled)

        #expect(screen.post.debugSettings.comments == .disabled)
    }

    /// ⚠️ THE HONESTY THIS SCREEN OWES. The settings are operable and reach
    /// nothing; a screen that offers them silently would convert a known gap
    /// into a false belief — the privacy screen's rule (§13a).
    @Test func theScreenSaysPlainlyThatItsSettingsAreNotSent() throws {
        let screen = open(Self.items(1))

        // ⚠️ THE LAST OF THE THREE SETTINGS CARDS. Splitting the settings moved
        // this footer from section 2 to section 4 — a test that pins an index
        // has to move with the sections it names.
        let settingsFooter = try #require(screen.post.debugFooterText(forSection: 4))
        #expect(settingsFooter.contains("aren't sent"), "got: \(settingsFooter)")

        let titleFooter = try #require(screen.post.debugFooterText(forSection: 1))
        #expect(titleFooter.contains("Titles aren't carried"), "got: \(titleFooter)")
    }

    /// Every control here is a switch, a menu button or a text field, so a row
    /// that greys itself under a finger announces a selection that does not
    /// exist.
    @Test func nothingOnThisScreenIsSelectable() {
        let screen = open(Self.items(1))

        #expect(screen.post.debugAllowsSelection == false)
    }

    /// ⚠️ THE TRAP A DISMISS TAP SETS. Installed cancelling, it eats the touches
    /// meant for the switches, the Comments menu and "Change cover" — the
    /// controls stop responding and the cause is invisible. PostDetail's stream
    /// tap carries the same note.
    @Test func theKeyboardDismissTapLetsTheControlsKeepTheirTouches() throws {
        let screen = open(Self.items(1))

        let cancelsTouches = try #require(
            screen.post.debugDismissTapCancelsTouches,
            "the dismiss tap is installed, and findable by name"
        )
        #expect(cancelsTouches == false, "or it swallows the switches' and the menu's touches")
    }

    /// ⚠️ **THE REGRESSION A SCREENSHOT COULD NOT CATCH.** The strip pins every
    /// picture to 156x208 — which IS 3:4 — and the debug fixture renders even
    /// indices at 3:4, so `scaleAspectFit` of that image into that frame
    /// letterboxes by ZERO. Fill and fit are pixel-identical for those tiles,
    /// and a device capture proves nothing either way. This asks the view
    /// directly, so the geometry cannot hide the answer.
    @Test func theThumbnailsWearTheFitChosenInTheEditor() async throws {
        let screen = open(Self.items(3), fits: ["photo-1": .fit])
        try await settle(until: { !Self.strips(in: screen.window).isEmpty })
        screen.window.layoutIfNeeded()

        let strip = try #require(Self.strips(in: screen.window).first)
        #expect(
            strip.debugContentModes == [.scaleAspectFill, .scaleAspectFit, .scaleAspectFill],
            "only the one the author chose to show whole is fitted: \(strip.debugContentModes)"
        )
    }

    /// The strip cell, dug out of the hosted window — the same recursive shape
    /// `MediaEditorTests` uses to find its pages.
    private static func strips(in view: UIView) -> [NewPostMediaCell] {
        var found: [NewPostMediaCell] = []
        for subview in view.subviews {
            if let strip = subview as? NewPostMediaCell { found.append(strip) }
            found += strips(in: subview)
        }
        return found
    }

    /// Six switches in one card is a wall. Grouped, each card asks one question
    /// — and the engagement four are the group the author actually thinks about
    /// together.
    @Test func theSettingsAreGroupedRatherThanStackedInOneCard() {
        let screen = open(Self.items(1))

        #expect(screen.post.debugSectionCount == 5, "media, text, and three settings cards")
        #expect(screen.post.debugHeaderText(forSection: 2) == "Engagement")
        #expect(screen.post.debugHeaderText(forSection: 3) == "Sharing")
        #expect(screen.post.debugHeaderText(forSection: 4) == "Disclosure", "moved below Sharing")
        #expect(screen.post.debugRowCount(inSection: 2) == 4, "comments, points, reposts, bookmarks")
        #expect(screen.post.debugHeaderText(forSection: 0) == nil, "the media wears no header")
    }

    /// The video warning is worth drawing only when there is a video to warn
    /// about — an unconditional apology is furniture.
    @Test func theVideoWarningAppearsOnlyWhenAVideoWasChosen() {
        let withVideo = open(Self.items(2, videosAt: [1]))
        let withoutVideo = open(Self.items(2))

        #expect(withVideo.post.debugFooterText(forSection: 0)?.contains("Videos can't be posted") == true)
        #expect(withoutVideo.post.debugFooterText(forSection: 0) == nil)
    }
}
