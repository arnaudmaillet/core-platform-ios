// `AVURLAsset`, to prove the file the stub hands over is a real clip and not a
// URL that merely looks like one.
import AVFoundation
import CoreModels
// `PlaceholderVideoFetcher` — the feed's mock video source, which synthesises
// the real H.264 bytes the publish path then opens for real.
import MediaPlayback
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

        /// ⚠️ **A FLAT COLOUR CANNOT SHOW A CROP.** Every other test here is
        /// served by 2x2 of pure red — a look changes its colour, so a pixel is
        /// enough. A crop changes WHICH pixels, and a picture that is red
        /// everywhere is red wherever you cut it. Set this and the stub answers
        /// red over blue, large enough to cut.
        var answersTwoColours = false

        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        /// Nothing to present against a stub — the seam exists so the picker can
        /// offer the system sheet without importing `Photos`.
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            requests.append((item, size))
            guard answersTwoColours else {
                return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
                }
            }
            return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
            }
        }

        /// The strip asks small and the publish loop asks large, so the large
        /// ones are the post itself.
        var publishedIDs: [String] { requests.filter { $0.size.width >= 1000 }.map(\.id) }

        /// Every video the publish loop asked for a file for, in order.
        private(set) var videoRequests: [String] = []

        /// Makes `videoFile` answer nothing — how "a clip that cannot be read
        /// stops the publish" is told apart from "it silently shrinks it".
        var answersNoVideoFile = false

        /// ⚠️ **A REAL CLIP, SYNTHESISED — NOT A URL THAT LOOKS LIKE ONE.**
        /// `PostComposer` runs an `AVAssetExportSession` over whatever comes
        /// back and pulls a poster out of it with `AVAssetImageGenerator`; a URL
        /// with no video track behind it fails both, and the test would be
        /// measuring this stub rather than the screen. Tiny and short on
        /// purpose, and `PlaceholderVideoFetcher` caches by URL on disk, so the
        /// whole suite pays for one encode per id.
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            videoRequests.append(item)
            guard !answersNoVideoFile else { return nil }
            guard let source = URL(string: "mock://video/\(item)?w=64&h=64") else { return nil }
            return try? await PlaceholderVideoFetcher(durationSeconds: 0.4, framesPerSecond: 10)
                .playableURL(for: source)
        }
    }

    private actor RecordingComposer: PostComposing {
        struct Call: Sendable {
            let mediaCount: Int
            let caption: String
            /// ⚠️ **THE PICTURES THEMSELVES, NOT JUST THEIR COUNT.** A composer
            /// that records `mediaCount` alone cannot tell a baked look from an
            /// untouched photograph, and a test written against it would pass
            /// whether or not the filter was ever applied.
            let images: [PickedImage]
            /// ⚠️ **AND THEIR KINDS, IN CAROUSEL ORDER.** Since videos publish,
            /// `mediaCount == 3` is satisfied just as well by three photographs
            /// as by the two-photos-and-a-clip that was actually chosen — and
            /// the ORDER is the carousel, which `post.v1` cannot express any
            /// other way.
            let kinds: [String]
            let videos: [PickedVideo]
        }

        private(set) var calls: [Call] = []

        func publish(
            media: [ComposeMedia], caption: String, as author: AuthorSummary?
        ) async throws -> FeedEntry {
            let pictures: [PickedImage] = media.compactMap {
                if case .image(let picked) = $0 { return picked }
                return nil
            }
            let clips: [PickedVideo] = media.compactMap {
                if case .video(let picked) = $0 { return picked }
                return nil
            }
            let kinds: [String] = media.map {
                if case .video = $0 { return "video" }
                return "photo"
            }
            calls.append(Call(
                mediaCount: media.count, caption: caption,
                images: pictures, kinds: kinds, videos: clips
            ))
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
        edits: [String: MediaEdits] = [:]
    ) -> Screen {
        let library = StubLibrary()
        let composer = RecordingComposer()
        let handed = Handed()
        let post = NewPostViewController(
            items: items, edits: edits, library: library, composer: composer
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

    // MARK: - The look, baked

    /// The centre pixel of an image, as three 0–255 components.
    private static func centrePixel(of image: UIImage) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func publishedImages(from composer: RecordingComposer) async throws -> [PickedImage] {
        for _ in 0..<300 {
            let calls = await composer.calls
            if let first = calls.first { return first.images }
            try await Task.sleep(for: .milliseconds(10))
        }
        return []
    }

    /// ⚠️ **THE LOOK MUST REACH THE UPLOAD, NOT JUST THE PREVIEW.** The editor
    /// shows a filter on a canvas-sized render and on a 56pt chip; neither of
    /// those is what the composer is handed. This asserts on the picture that
    /// actually goes, and it reads its PIXELS — "an image was published" is
    /// satisfied just as well by an untouched photograph.
    @Test func aChosenLookIsBakedIntoThePictureThatIsPublished() async throws {
        let screen = open(Self.items(1), edits: ["photo-0": MediaEdits(filter: .mono)])

        screen.post.debugTapPost()
        let images = try await publishedImages(from: screen.composer)

        let picture = try #require(images.first, "nothing reached the composer")
        let pixel = try #require(Self.centrePixel(of: picture.image))
        #expect(abs(pixel.r - pixel.g) < 12, "mono levels red and green: \(pixel)")
        #expect(abs(pixel.g - pixel.b) < 12, "and green and blue: \(pixel)")
    }

    /// ⚠️ **THE OTHER HALF, AND WITHOUT IT THE ONE ABOVE PROVES LESS THAN IT
    /// SEEMS.** A renderer that quietly returned grey for everything would
    /// satisfy the mono assertion; only the untouched case shows the picture is
    /// left alone when no look was chosen. The stub answers in pure red.
    @Test func noLookLeavesThePicturePreciselyAsItWas() async throws {
        let screen = open(Self.items(1))

        screen.post.debugTapPost()
        let images = try await publishedImages(from: screen.composer)

        let picture = try #require(images.first, "nothing reached the composer")
        let pixel = try #require(Self.centrePixel(of: picture.image))
        #expect(pixel.r > pixel.g + 60, "still the red the library answered with: \(pixel)")
        #expect(pixel.r > pixel.b + 60, "untouched, not levelled: \(pixel)")
    }

    /// ⚠️ **THE CROP MUST REACH THE UPLOAD TOO, AND NOTHING ASSERTED THAT UNTIL
    /// THIS EXISTED.** The look had `aChosenLookIsBakedIntoThePictureThatIsPublished`
    /// from the day it shipped; the crop travelled through four render paths with
    /// only the preview ones checked. This reads the PIXELS of the picture handed
    /// to the composer, which is the only place the author's rectangle actually
    /// matters.
    @Test func aChosenCropIsBakedIntoThePictureThatIsPublished() async throws {
        let top = MediaCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        let screen = open(Self.items(1), edits: ["photo-0": MediaEdits(crop: top)])
        screen.library.answersTwoColours = true

        screen.post.debugTapPost()
        let images = try await publishedImages(from: screen.composer)

        let picture = try #require(images.first, "nothing reached the composer")
        let pixel = try #require(Self.centrePixel(of: picture.image))
        #expect(pixel.r > pixel.b + 60, "the top half is red: \(pixel)")
    }

    /// The half that makes it mean something: move the rectangle and the
    /// published pixels move with it. Without this, a bake that ignored the crop
    /// entirely would satisfy the line above — the source's centre is red too.
    @Test func aCropOfTheBottomPublishesTheBottom() async throws {
        let bottom = MediaCrop(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let screen = open(Self.items(1), edits: ["photo-0": MediaEdits(crop: bottom)])
        screen.library.answersTwoColours = true

        screen.post.debugTapPost()
        let images = try await publishedImages(from: screen.composer)

        let picture = try #require(images.first, "nothing reached the composer")
        let pixel = try #require(Self.centrePixel(of: picture.image))
        #expect(pixel.b > pixel.r + 60, "the bottom half is blue: \(pixel)")
    }

    // MARK: - The cover

    /// ⚠️ NOT SIMPLY THE FIRST ITEM. Only photos publish, so if the viewer's
    /// ⚠️ **THE FIRST ITEM, EVEN WHEN IT IS A VIDEO — AND THIS TEST USED TO
    /// ASSERT THE OPPOSITE.** While videos could not be published, the cover
    /// skipped to the first PHOTO so the strip would not badge a face the feed
    /// never showed. A video now publishes and carries a poster, so skipping it
    /// would silently reorder a selection that was chosen clip-first.
    @Test func theCoverIsTheFirstItemEvenWhenItIsAVideo() {
        let screen = open(Self.items(3, videosAt: [0]))

        #expect(screen.post.debugCoverID == "video-0")
        #expect(screen.post.debugPublishOrder.first == "video-0", "and it leads the carousel")
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

    /// ⚠️ **EVERY ITEM NOW, AND THE TITLES SAY WHICH IS WHICH.** This asserted
    /// "photos only" for as long as a video could not be published. The number
    /// is the item's place in the SELECTION, not among its own kind, so the
    /// label answers "which one" rather than "which video".
    @Test func theCoverMenuOffersEveryItemAndNamesItsKind() {
        let screen = open(Self.items(4, videosAt: [1, 3]))

        let titles = screen.post.debugCoverMenu().children.compactMap { ($0 as? UIAction)?.title }

        #expect(titles == ["Photo 1", "Video 2", "Photo 3", "Video 4"], "got \(titles)")
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

    /// ⚠️ **THE WHOLE POINT OF THIS SLICE, AND THIS TEST USED TO ASSERT THE
    /// LOSS.** It was `videosAreLeftBehindRatherThanPublishedEmpty`, and it
    /// pinned `mediaCount == 2` out of a four-item selection. Everything below
    /// the `where !item.isVideo` clause in `post()` was already built and green;
    /// the clause was the whole of the gap.
    ///
    /// The KINDS are asserted, not just the count: four photographs would
    /// satisfy `mediaCount == 4` exactly as well as the two-and-two that was
    /// chosen, and the array's order IS the carousel's.
    @Test func aVideoIsPublishedAlongsideThePhotosInCarouselOrder() async throws {
        let screen = open(Self.items(4, videosAt: [1, 2]))

        screen.post.debugTapPost()
        // ⚠️ WAITING ON THE HAND-BACK, NOT ON THE COMPOSER. `settle(until:)` takes
        // a SYNCHRONOUS condition and the composer is an actor, so reading its
        // calls inside one cannot compile — and `onPublished` firing is the real
        // "it finished" signal anyway.
        try await settle(until: { screen.handed.entry != nil })

        let calls = await screen.composer.calls
        #expect(calls.first?.mediaCount == 4, "all four were chosen, all four go")
        #expect(calls.first?.kinds == ["photo", "video", "video", "photo"],
                "in the order they were chosen: \(calls.first?.kinds ?? [])")
        #expect(screen.library.publishedIDs == ["photo-0", "photo-3"],
                "only the photographs are fetched as images")
        #expect(screen.library.videoRequests == ["video-1", "video-2"],
                "and the clips are fetched as files")
    }

    /// ⚠️ **A URL IS NOT A VIDEO, AND ONLY OPENING IT SAYS SO.** `PostComposer`
    /// runs an `AVAssetExportSession` over whatever this screen hands it and
    /// pulls a poster out with `AVAssetImageGenerator`; a path that merely looks
    /// plausible fails both, at publish time, in front of the author. The stub
    /// synthesises real H.264, so this asks the file the same question the
    /// composer will.
    @Test func theVideoHandedToTheComposerIsAPlayableFile() async throws {
        let screen = open(Self.items(2, videosAt: [1]))

        screen.post.debugTapPost()
        try await settle(until: { screen.handed.entry != nil })

        let calls = await screen.composer.calls
        let clip = try #require(calls.first?.videos.first)
        #expect(clip.sourceURL.isFileURL)
        let tracks = try await AVURLAsset(url: clip.sourceURL).loadTracks(withMediaType: .video)
        #expect(tracks.isEmpty == false, "the file handed over carries no video track")
    }

    /// ⚠️ **A CLIP THAT CANNOT BE READ STOPS THE POST — IT DOES NOT SHRINK IT.**
    /// Publishing three of the four things the author assembled, with no word
    /// said, is the exact defect this slice removes; doing it again by way of an
    /// error path would be the same bug wearing a different sleeve. The usual
    /// cause is an unfinished iCloud download, which is worth saying out loud.
    @Test func aVideoThatCannotBeReadStopsThePostRatherThanShrinkingIt() async throws {
        let screen = open(Self.items(3, videosAt: [1]))
        screen.library.answersNoVideoFile = true

        screen.post.debugTapPost()
        try await settle(until: { screen.post.presentedViewController is UIAlertController })

        #expect(screen.handed.entry == nil, "nothing was handed back")
        let calls = await screen.composer.calls
        #expect(calls.isEmpty, "and the composer was never asked to publish a short carousel")
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
        let screen = open(Self.items(3), edits: ["photo-1": MediaEdits(fit: .fit)])
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

    /// ⚠️ **THE APOLOGY IS GONE BECAUSE THE LIMITATION IS.** This was
    /// `theVideoWarningAppearsOnlyWhenAVideoWasChosen`, and it required the
    /// media footer to read "Videos can't be posted yet" whenever a clip was in
    /// the selection. A notice that outlives the thing it apologises for is
    /// worse than none: it tells the author their video will be dropped while
    /// the screen quietly publishes it.
    ///
    /// The text section keeps ITS footer — §21 is still true — which is the
    /// witness that this is reading a real footer and not a broken accessor.
    @Test func theMediaSectionNoLongerApologisesForVideos() {
        let withVideo = open(Self.items(2, videosAt: [1]))
        let withoutVideo = open(Self.items(2))

        #expect(withVideo.post.debugFooterText(forSection: 0) == nil)
        #expect(withoutVideo.post.debugFooterText(forSection: 0) == nil)
        #expect(withVideo.post.debugFooterText(forSection: 1)?.isEmpty == false,
                "guard: the text section still states what it does not publish")
    }
}
