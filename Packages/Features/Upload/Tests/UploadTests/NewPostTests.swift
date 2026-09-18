// `AVURLAsset`, to prove the file the stub hands over is a real clip and not a
// URL that merely looks like one.
import AVFoundation
import CoreModels
import DesignSystem
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
        let preview: StubPreview
        let handed: Handed
    }

    /// Records what the screen ASKED the playback seam for, which is the whole
    /// subject of the cover tests.
    ///
    /// ⚠️ **A STUB IS NOT A CONVENIENCE HERE, IT IS THE ONLY WAY TO ASK.** The
    /// default is a real `MediaPreviewPlayer`, and this suite's `StubLibrary`
    /// synthesises genuine H.264 — so without this every one of the twenty-odd
    /// tests below would bind an `AVPlayer` to an offscreen surface and decode
    /// a real composition for nothing. What is assertable is narrower and
    /// entirely answerable: which arrangement was handed over, into which
    /// surface, whether it was silenced, and whether it was given back.
    /// `MediaEditorPlaybackTests.StubPreview` is the same shape.
    private final class StubPreview: MediaVideoPreviewing {
        /// Every arrangement the screen asked to be played, and the surface it
        /// asked for it in — paired, because "the cover's tile hosts it" is
        /// half the claim and "this is the plan it was given" is the other.
        private(set) var plans: [(plan: VideoExportPlan, surface: VideoRenderView)] = []
        /// Where each accepted load landed. A landing naming no range is the
        /// whole arrangement, looping.
        private(set) var landings: [VideoLoadLanding] = []
        private(set) var stopped: [VideoRenderView] = []
        private(set) var mutes: [(muted: Bool, surface: VideoRenderView)] = []
        private(set) var loops: [ClosedRange<Double>?] = []
        private var boundSurfaces: Set<ObjectIdentifier> = []

        /// ⚠️ **ONLY A LOAD THE LANDING ACCEPTS COUNTS AS BOUND** — the real
        /// controller binds nothing for a load its caller abandons, and the
        /// bound count is this suite's leak assertion.
        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard let landed = landing() else { return }
            landings.append(landed)
            plans.append((plan, surface))
            boundSurfaces.insert(ObjectIdentifier(surface))
        }

        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {
            loops.append(range)
        }

        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}

        func stop(_ surface: VideoRenderView) {
            stopped.append(surface)
            boundSurfaces.remove(ObjectIdentifier(surface))
        }

        func setPaused(_ paused: Bool, in surface: VideoRenderView) {}
        func isPaused(in surface: VideoRenderView) -> Bool? { false }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        func isBound(_ surface: VideoRenderView) -> Bool {
            boundSurfaces.contains(ObjectIdentifier(surface))
        }
        func playheadSeconds(in surface: VideoRenderView) -> Double? { nil }
        func seek(
            toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double
        ) {}
        /// ⚠️ **IT HAS TO ANSWER NOW: THE SHEETS ARE BUILT FROM THIS.** Every
        /// clip tile samples a few frames for the preview it falls back to, and
        /// a stub answering nothing would leave every tile without one — so the
        /// whole state machine would read as working while nothing was ever
        /// drawn. Each frame is a distinct grey, so a test can tell one from
        /// another.
        private(set) var frameRequests: [[Double]] = []
        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] {
            frameRequests.append(seconds)
            return Dictionary(uniqueKeysWithValues: seconds.enumerated().map { index, second in
                let shade = CGFloat(index + 1) / CGFloat(seconds.count + 1)
                let frame = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 20)).image { context in
                    UIColor(white: shade, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 12, height: 20))
                }
                return (second, frame)
            })
        }
        @discardableResult
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) -> Bool { true }
        func setMuted(_ muted: Bool, in surface: VideoRenderView) {
            mutes.append((muted, surface))
        }
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {}

        /// ⚠️ **THE COUNT OF BOUND SURFACES IS THE LEAK ASSERTION.** A screen
        /// that started every clip in the strip would still satisfy "the cover
        /// plays"; only this can say that the other nineteen did not.
        var boundCount: Int { boundSurfaces.count }
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

        /// Forgets what has been asked for so far.
        ///
        /// ⚠️ **THE STRIP READS CLIPS TOO NOW.** Every clip tile samples a few
        /// frames for the sheet it falls back to, so "which files did this
        /// screen open" stopped being the same question as "which files did the
        /// PUBLISH open". Clearing the record is what keeps the second one
        /// exact, rather than asserting a superset and calling it an order.
        func forgetVideoRequests() { videoRequests = [] }

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
        /// The file each id was actually vended.
        ///
        /// ⚠️ **RECORDED, BECAUSE IT CANNOT BE PREDICTED.**
        /// `PlaceholderVideoFetcher` names its cache file from a hash of the
        /// mock URL and `Hasher` is seeded per process, so a test that built the
        /// expected path itself would be asserting on a different name every
        /// run. This is how "the plan carries the COVER's file" is said.
        private(set) var vended: [String: URL] = [:]

        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            videoRequests.append(item)
            guard !answersNoVideoFile else { return nil }
            guard let source = URL(string: "mock://video/\(item)?w=64&h=64") else { return nil }
            let file = try? await PlaceholderVideoFetcher(durationSeconds: 0.4, framesPerSecond: 10)
                .playableURL(for: source)
            if let file { vended[item] = file }
            return file
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

    /// ⚠️ **REDUCE MOTION IS STATED, NEVER READ OFF THE SIMULATOR.** Left to
    /// `UIAccessibility`, every curve-deciding test below would pass or fail
    /// with a setting on whatever machine ran it.
    ///
    /// ⚠️ **`landed: false` IS FOR THE ONE QUESTION THAT NEEDS THE MOMENT BEFORE
    /// THE SCREEN LANDS.** Made the root of a window that is then shown, the
    /// screen is sent `viewDidAppear` before this returns — measured: the strip's
    /// entrance, which nothing but `viewDidAppear` starts, had already run. A
    /// window left hidden lays out no cells at all. So the view is laid in a
    /// shown window WITHOUT its controller being the root, and appearance is
    /// then `appear()`'s alone to send.
    private func open(
        _ items: [MediaLibraryItem],
        edits: [String: MediaEdits] = [:],
        reducesMotion: Bool = false,
        landed: Bool = true
    ) -> Screen {
        let library = StubLibrary()
        let composer = RecordingComposer()
        let preview = StubPreview()
        let handed = Handed()
        let post = NewPostViewController(
            items: items, edits: edits, library: library, composer: composer, preview: preview,
            reducesMotion: { reducesMotion }
        ) { handed.entry = $0 }
        let navigation = UINavigationController(rootViewController: post)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        if landed {
            window.rootViewController = navigation
        } else {
            post.view.frame = window.bounds
            window.addSubview(post.view)
        }
        window.isHidden = false
        window.layoutIfNeeded()
        return Screen(
            post: post, navigation: navigation, window: window,
            library: library, composer: composer, preview: preview, handed: handed
        )
    }

    /// ⚠️ **APPEARANCE IS DRIVEN BY HAND — AND THE REASON THAT STOOD HERE WAS
    /// WRONG.** It said a hosted window never sends `viewDidAppear`. Under
    /// `open()` it does, before `open` returns: measured 2026-09-18 on iOS 27,
    /// the strip's entrance — which nothing but `viewDidAppear` starts — had
    /// already run by the first line after it. Sending it again is harmless (the
    /// cover's re-entrancy guard and the entrance's once-only flag both exist
    /// for a second appearance) and keeps each test saying where the screen
    /// lands. `open(landed: false)` is how to ask about the moment before.
    /// `MediaEditorPlaybackTests` drives its editor the same way.
    private func appear(_ screen: Screen) {
        screen.post.beginAppearanceTransition(true, animated: false)
        screen.post.endAppearanceTransition()
        screen.window.layoutIfNeeded()
    }

    private func disappear(_ screen: Screen) {
        screen.post.beginAppearanceTransition(false, animated: false)
        screen.post.endAppearanceTransition()
    }

    /// A breath, for a claim that something did NOT happen.
    ///
    /// ⚠️ **`settle(until:)` IS THE WRONG INSTRUMENT FOR A NEGATIVE.** Its bound
    /// is thirty seconds — sized for a CI machine finishing a real publish — and
    /// a condition that must never hold pays all of it, once per negative test.
    /// What "nothing happened" needs is long enough for the work to have
    /// STARTED, and the first thing a cover load does is ask the library for a
    /// file, which is one suspension away.
    private func breathe() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
    }

    /// ⚠️ **RAISED FROM 300 BECAUSE VIDEO ARRIVED.** Three seconds was ample
    /// while this screen only fetched images. The video tests synthesise real
    /// H.264 behind their stub, and on CI — one machine, nine package lanes,
    /// every suite `@MainActor` — they timed out mid-publish with partial
    /// results. A bound that is too large costs nothing when the condition
    /// holds.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<3000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The bars

    /// The bar is `[‹][save] ——— [Post]` and nothing else: a centred title
    /// competes with the two words either side of it on a phone.
    @Test func theScreenCarriesNoTitleOfItsOwn() throws {
        let screen = open(Self.items(2))

        #expect(screen.post.title == nil, "no 'New post' in the middle of the bar")
        // ⚠️ THE CHEVRON IS UIKit'S — see `MediaEditorTests`. The flag is what
        // makes "Save draft" sit BESIDE the back button rather than in its place,
        // and the back-swipe survives only while it is set.
        let left = try #require(screen.post.navigationItem.leftBarButtonItems)
        // An icon rather than the words, for the bar's width budget — see
        // `MediaEditorTests`. Asked by spoken name, because a titleless item's
        // `title` is nil and an icon with no spoken name cannot be announced.
        #expect(left.map(\.accessibilityLabel) == ["Save draft"],
                "the draft alone; the chevron is the system's")
        #expect(left.first?.image != nil, "an icon bar item with no icon is a blank capsule")
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

        // ⚠️ **THE STRIP HAS ALREADY OPENED BOTH CLIPS.** Every clip tile samples
        // a few frames for the sheet it falls back to, so what this screen has
        // read is no longer what the PUBLISH read. Cleared, so the assertion
        // below stays exact rather than becoming a superset wearing the word
        // "order".
        screen.library.forgetVideoRequests()
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
        // ⚠️ **A SET, NOT A SEQUENCE, AND THE ORDER IS PINNED ABOVE.** The strip
        // samples frames for every clip tile on its own schedule, so reads from
        // the sheet land among the publish's whenever they finish. The claim
        // that matters — that the clips go in the order they were chosen — is
        // the `kinds` assertion above, which reads what the composer was handed.
        #expect(Set(screen.library.videoRequests).isSuperset(of: ["video-1", "video-2"]),
                "the clips were not fetched as files: \(screen.library.videoRequests)")
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

    /// ⚠️ **A STICKER IS BAKED INTO THE PHOTOGRAPH THAT IS PUBLISHED.** Its
    /// frames are baked before the render runs; without them the renderer
    /// skips the sticker and the post goes out bare. The reader averages the
    /// whole picture — here half red, half blue — so the sticker is laid at
    /// five times its size, most of the frame, and the average turns towards
    /// its yellow.
    @Test func aStickerIsBakedIntoThePublishedPhotograph() async throws {
        var edited = MediaEdits()
        edited.overlays = [FrameOverlay(
            content: .sticker(id: "Idea"), placement: OverlayPlacement(scale: 5)
        )]
        let bare = open(Self.items(1))
        bare.library.answersTwoColours = true
        bare.post.debugTapPost()
        let bareImages = try await publishedImages(from: bare.composer)
        let barePicture = try #require(bareImages.first, "guard: nothing bare was published")
        let plain = try #require(Self.centrePixel(of: barePicture.image))
        let screen = open(Self.items(1), edits: ["photo-0": edited])
        screen.library.answersTwoColours = true

        screen.post.debugTapPost()
        let images = try await publishedImages(from: screen.composer)

        let picture = try #require(images.first, "nothing reached the composer")
        let pixel = try #require(Self.centrePixel(of: picture.image))
        #expect(pixel.g > plain.g + 40, "no sticker was laid: \(pixel) against \(plain)")
    }

    /// ⚠️ **THE WHOLE EDIT OF A CLIP IS HANDED ON, NOT ONLY ITS PIECES.** A
    /// look, a crop, the text and a song were shown in the editor and, until
    /// this, published as if never made.
    @Test func aClipsWholeEditReachesTheComposer() async throws {
        let text = FrameOverlay(
            id: "t", content: .text(TextOverlay(
                text: "Hi", font: .classic, colour: .white, background: .none, alignment: .centre
            )),
            placement: .centred
        )
        let song = VideoSoundtrack(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("song.m4a"),
            title: "Song", startSeconds: 2, musicVolume: 0.5, originalVolume: 0.25
        )
        var edited = MediaEdits(filter: .noir)
        edited.crop = MediaCrop(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        edited.overlays = [text]
        edited.soundtrack = song
        let screen = open(Self.items(2, videosAt: [1]), edits: ["video-1": edited])

        screen.post.debugTapPost()
        try await settle(until: { screen.handed.entry != nil })

        let calls = await screen.composer.calls
        let clip = try #require(calls.first?.videos.first)
        #expect(clip.finish.look.preset == .noir, "the look was left behind")
        #expect(clip.finish.crop == edited.crop, "the crop was left behind")
        #expect(clip.finish.overlays == [text], "the text was left behind")
        #expect(clip.soundtrack == song, "the song was left behind")
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

    // MARK: - The strip's entrance

    /// ⚠️ **HELD UNTIL THE SCREEN LANDS, THEN ONE AFTER ANOTHER.** Asked for:
    /// the thumbnails arrive staggered, "like the filter row". The DECISION is
    /// what is asserted — how many tiles were staged and with what delays —
    /// because `alpha` and `transform` read their end values the moment
    /// `UIView.animate` is called (`uiview-animate-from-value-trap`).
    @Test func theThumbnailsWaitForTheScreenToLandThenArriveOneAfterAnother() async throws {
        let screen = open(Self.items(3), landed: false)
        let strip = try #require(Self.strips(in: screen.window).first, "the first layout built no strip")
        try #require(strip.debugArrivals.isEmpty, "guard: the screen had not landed yet")
        #expect(strip.debugHeldTileCount == 3, "the tiles were drawn before the screen landed")

        appear(screen)

        #expect(
            strip.debugArrivals == [[0, 1, 2].map { BandPop.stagger(for: $0) }],
            "not the band's ripple: \(strip.debugArrivals)"
        )
        #expect(strip.debugHeldTileCount == 0, "a tile was left invisible")
    }

    /// ⚠️ **A NEW COVER IS A SMALL EDIT, AND THE STRIP DOES NOT RE-ENTER FOR
    /// IT.** The reorder rebuilds every tile; rippling them all back in from
    /// the first would read as the screen reloading. The new order just
    /// appears — nothing held invisible, nothing replayed.
    @Test func aNewCoverRebuildsTheStripWithoutReplayingItsEntrance() async throws {
        let screen = open(Self.items(3))
        appear(screen)
        let strip = try #require(Self.strips(in: screen.window).first)
        try #require(strip.debugArrivals.count == 1, "guard: the strip made its entrance")

        screen.post.debugSetCover("photo-2")
        screen.window.layoutIfNeeded()

        let rebuilt = try #require(Self.strips(in: screen.window).first)
        try #require(rebuilt === strip, "guard: the reconfigure kept the cell")
        try #require(rebuilt.debugTileIDs == ["photo-2", "photo-0", "photo-1"],
                     "guard: the strip was rebuilt in the new order: \(rebuilt.debugTileIDs)")
        #expect(rebuilt.debugHeldTileCount == 0,
                "the new tiles are held invisible for an entrance that already happened")
        #expect(rebuilt.debugArrivals.count == 1, "the entrance replayed: \(rebuilt.debugArrivals)")
    }

    /// Reduce Motion: the thumbnails are simply there — never held invisible
    /// for a curve that will not run.
    @Test func underReduceMotionTheThumbnailsAreSimplyThere() async throws {
        let screen = open(Self.items(3), reducesMotion: true, landed: false)
        let strip = try #require(Self.strips(in: screen.window).first, "the first layout built no strip")
        #expect(strip.debugHeldTileCount == 0, "tiles held invisible under Reduce Motion")

        appear(screen)

        #expect(strip.debugArrivals.isEmpty, "a ripple ran under Reduce Motion: \(strip.debugArrivals)")
    }

    /// ⚠️ **THE RIPPLE STARTS AS THE PUSH BEGINS, NOT ONCE IT HAS LANDED.**
    /// Asked for as *"déclencher avant, peut-être dès le tap sur Next"*: measured,
    /// `viewDidAppear` waits for the whole transition to settle, most of a
    /// second after the tap. So this is a real animated push from a real stack,
    /// read before the transition could have finished — the tiles have already
    /// been told to ripple, and the screen has not landed.
    @Test func theThumbnailsRippleInWhileThePushIsStillUnderWay() throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let post = NewPostViewController(
            items: Self.items(3), library: StubLibrary(), composer: RecordingComposer(),
            preview: StubPreview(), reducesMotion: { false }
        ) { _ in }

        navigation.pushViewController(post, animated: true)
        window.layoutIfNeeded()

        try #require(!post.debugHasLanded, "guard: the push had already landed, so this proves nothing")
        let strip = try #require(Self.strips(in: window).first, "the push has not built the strip")
        #expect(
            strip.debugArrivals == [[0, 1, 2].map { BandPop.stagger(for: $0) }],
            "the ripple waits for the landing: \(strip.debugArrivals)"
        )
        #expect(strip.debugHeldTileCount == 0, "a tile is still held invisible")
    }

    // MARK: - The thumbnails as buttons

    /// ⚠️ **EVERY THUMBNAIL GIVES AND TICKS — A PHOTOGRAPH'S TOO — AND ONLY A
    /// CLIP'S DOES ANYTHING ELSE.** Asked for as thumbnails that behave like
    /// buttons, without an action being invented for a photograph. A tile is
    /// an image view, born deaf to touches, so the photograph's has to have
    /// been woken for the finger to reach it at all.
    ///
    /// ⚠️ **THE TOUCH ITSELF IS DESIGNSYSTEM'S TO TEST** (`PressFeedbackTests`:
    /// a drag takes the press away silently, a tap beside it does not). What is
    /// pinned here is that every tile wears it, and wears it on itself.
    @Test func everyThumbnailGivesUnderTheFingerAndTicksOnATap() throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        let strip = try #require(Self.strips(in: screen.window).first)

        for id in ["photo-0", "video-1"] {
            let feedback = try #require(strip.debugPressFeedback(for: id), "\(id)'s tile does not answer a press")
            let tile = try #require(feedback.debugTarget)
            #expect(feedback.style == .press)
            #expect(tile.isUserInteractionEnabled, "\(id)'s tile never feels the finger")
            #expect(feedback.debugRecognizer?.view === tile, "\(id)'s press is watched from somewhere else")

            feedback.press()
            feedback.release(asTap: true)

            #expect(feedback.debugEvents == [
                .pressed(scale: PressFeedback.pressedScale(for: tile.bounds.size)),
                .released(tap: true, sprang: true)
            ], "\(id): \(feedback.debugEvents)")
        }
    }

    /// Reduce Motion reaches the tiles through the screen, as it reaches their
    /// entrance: a press moves nothing, and the tap still ticks.
    @Test func underReduceMotionAThumbnailTicksWithoutMoving() throws {
        let screen = open(Self.items(1), reducesMotion: true)
        let strip = try #require(Self.strips(in: screen.window).first)
        let feedback = try #require(strip.debugPressFeedback(for: "photo-0"))

        feedback.press()
        feedback.release(asTap: true)

        #expect(feedback.debugEvents == [.pressed(scale: 1), .released(tap: true, sprang: false)],
                "\(feedback.debugEvents)")
    }

    // MARK: - The cover button

    /// ⚠️ **THE REGRESSION NO VIEW-TREE ASSERTION CAN SEE.** Pinned to the
    /// row's full width, this button's menu took the whole upload sheet off the
    /// screen while it was open — and the hierarchy said the sheet was still
    /// there, unhidden, at full alpha. The symptom lives in the render server,
    /// so what is pinned is its cause: the button's width. See
    /// `NewPostButtonCell` for the measurements.
    @Test func theCoverButtonLeavesItsRowRoomEitherSide() async throws {
        let screen = open(Self.items(3))
        try await settle(until: { !Self.views(of: NewPostButtonCell.self, in: screen.window).isEmpty })
        screen.window.layoutIfNeeded()
        let cell = try #require(Self.views(of: NewPostButtonCell.self, in: screen.window).first)
        let titles = cell.debugMenu?.children.compactMap { ($0 as? UIAction)?.title }
        try #require(titles == ["Photo 1", "Photo 2", "Photo 3"], "guard: this is the cover's button")
        let row = cell.debugRowWidth
        let button = cell.debugButtonFrame
        try #require(row > 300 && button.width > 0, "guard: laid out — row \(row), button \(button)")

        // Measured on a 402pt window: 396 lost the sheet, 370 kept it.
        #expect(NewPostButtonCell.widestShare < 370.0 / 402.0, "the cap is inside the band that failed")
        #expect(button.width <= row * NewPostButtonCell.widestShare + 0.5,
                "the button spans \(button.width) of a \(row)pt row")
        #expect(abs(button.midX - row / 2) < 1, "and it left the strip's middle: \(button)")
    }

    // MARK: - The cover, moving

    /// **ONE PLAYER, ON ONE CLIP, WHATEVER WAS CHOSEN.**
    ///
    /// Three clips are chosen here on purpose: "a clip plays" is satisfied just
    /// as well by a strip that starts every tile, and the count is the only
    /// thing that can tell those apart. The cover among them rests, so the one
    /// that plays is the next in publish order.
    @Test func oneClipPlaysMutedOnItsOwnTileAndNothingElseDoes() async throws {
        let screen = open(Self.items(3, videosAt: [0, 1, 2]))
        appear(screen)
        // Silencing is the LAST thing a cover load does, so waiting on it means
        // the whole sequence has run — and the breath after it is what gives a
        // strip that started the other two time to be caught doing it.
        try await settle(until: { screen.preview.mutes.count == 1 })
        try await breathe()
        screen.window.layoutIfNeeded()

        let strip = try #require(Self.strips(in: screen.window).first)
        #expect(screen.preview.plans.count == 1, "one clip moves, whatever was chosen")
        #expect(screen.preview.boundCount == 1, "exactly one surface holds a player")
        let started = try #require(screen.preview.plans.first)
        // What was ASKED FOR: one clip's file, in that clip's own tile. It is
        // `video-1` because `video-0` is the cover and the cover rests.
        #expect(started.plan.sourceURL == screen.library.vended["video-1"])
        #expect(strip.debugSurfaceTileID == "video-1",
                "the surface sits on \(strip.debugSurfaceTileID ?? "nothing")")
        #expect(started.surface === strip.debugVideoSurface,
                "the seam was handed the surface the tile is hosting")
        // ⚠️ SILENCED EXPLICITLY, AND AFTER THE ITEM IS IN. `MediaPreviewPlayer`
        // un-mutes a clip carrying a song at the end of its own load, which is
        // right on the editor's canvas and wrong on a settings form.
        let silenced = try #require(screen.preview.mutes.last)
        #expect(silenced.muted, "a thumbnail that makes noise beside a caption field is a defect")
        #expect(silenced.surface === strip.debugVideoSurface)
        // A landing naming no range is the whole arrangement, looping.
        #expect(screen.preview.landings == [VideoLoadLanding(seconds: 0)])
    }

    /// The witness. Without it, a seam that played nothing at all — a library
    /// answering nil, a surface never found — would satisfy every "stops"
    /// assertion below and read as careful bookkeeping.
    @Test func aStripWithNoFilmInItAsksForNothing() async throws {
        let screen = open(Self.items(3))
        appear(screen)
        try await breathe()
        screen.window.layoutIfNeeded()

        let strip = try #require(Self.strips(in: screen.window).first)
        #expect(screen.preview.plans.isEmpty, "three photographs; nothing moves")
        #expect(screen.library.videoRequests.isEmpty,
                "not even read: \(screen.library.videoRequests)")
        #expect(screen.preview.boundCount == 0)
        #expect(strip.debugSurfaceTileID == nil, "no tile wears a video surface")
    }

    /// ⚠️ **THE COVER RESTS ON ITS FRAMES AND THE NEXT CLIP PLAYS.** Asked for:
    /// a clip tile is interactive and plays by default, and the COVER's default
    /// is its frames instead — it is the tile wearing the word the author is
    /// here to check, and a label over moving film is noise. With one player,
    /// that also settles who gets it: the first clip in publish order that
    /// wants to play.
    @Test func theCoverRestsOnItsFramesWhileTheNextClipPlays() async throws {
        let screen = open(Self.items(3, videosAt: [0, 2]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()

        let strip = try #require(Self.strips(in: screen.window).first)
        #expect(strip.debugSurfaceTileID == "video-2",
                "the player went to \(strip.debugSurfaceTileID ?? "nothing")")
        #expect(strip.debugCoverBadgeIsShowing(for: "video-0"), "the resting cover lost its word")
        #expect(!strip.debugCoverBadgeIsShowing(for: "video-2"), "a tile that is not the cover wears the word")
    }

    /// ⚠️ **A TAP TAKES THE FILM OFF, AND A SECOND ONE STARTS IT AGAIN FROM THE
    /// BEGINNING.** Asked for in those words. Not a pause: an author who taps a
    /// thumbnail twice is asking to watch it again, not to carry on from
    /// wherever it happened to be.
    @Test func tappingAClipShowsItsFramesAndTappingAgainRestartsIt() async throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        try #require(strip.debugSurfaceTileID == "video-1", "guard: it started")

        strip.debugTapTile("video-1")
        try await breathe()

        #expect(strip.debugSurfaceTileID == nil, "the surface stayed over a tile that stopped")
        #expect(screen.preview.stopped.count == 1, "the player was not given back")
        #expect(strip.debugClipState(for: "video-1") == .sheet)

        strip.debugTapTile("video-1")
        try await settle(until: { screen.preview.plans.count == 2 })

        #expect(screen.preview.plans.count == 2, "a second item — the film starts over")
        #expect(screen.preview.landings.last == VideoLoadLanding(seconds: 0), "and from the beginning")
        #expect(strip.debugSurfaceTileID == "video-1")
    }

    /// ⚠️ **THE WORD IS FOR A TILE AT REST.** Asked for: show "Cover" only while
    /// that thumbnail is on its frames. A label over moving film is the noise
    /// the editor keeps its own chrome off the picture to avoid — and it comes
    /// back the moment the film stops.
    @Test func theCoversWordGoesWhileItsFilmRunsAndComesBackAfter() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        appear(screen)
        try await breathe()
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        try #require(strip.debugClipState(for: "video-0") == .sheet, "guard: the cover rests")
        #expect(strip.debugCoverBadgeIsShowing(for: "video-0"), "a resting cover with no word")

        strip.debugTapTile("video-0")
        try await settle(until: { screen.preview.plans.count == 1 })

        #expect(strip.debugClipState(for: "video-0") == .playing, "the tap did not start it")
        #expect(!strip.debugCoverBadgeIsShowing(for: "video-0"), "the word stayed over the film")

        strip.debugTapTile("video-0")
        try await breathe()

        #expect(strip.debugCoverBadgeIsShowing(for: "video-0"), "and it did not come back")
    }

    /// ⚠️ **THE WORD ARRIVES ON THE BAND'S SPRING AND LEAVES QUICKER THAN IT
    /// CAME.** Asked for: "spring scale + fade", in and out. What is asserted is
    /// the curve that was CHOSEN — `alpha` reads its end value the moment a curve
    /// is asked for, so it cannot say whether one ran.
    @Test func theCoversWordSpringsInAndSlipsOutOnTheBandsCurve() async throws {
        let screen = open(Self.items(2, videosAt: [0]))
        appear(screen)
        try await breathe()
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        try #require(strip.debugClipState(for: "video-0") == .sheet, "guard: the cover rests")
        #expect(strip.debugBadgeChanges.isEmpty,
                "putting a new tile right is not a change: \(strip.debugBadgeChanges)")

        strip.debugTapTile("video-0")

        let leaving = try #require(strip.debugBadgeChanges.last, "the word never went")
        #expect(leaving.id == "video-0" && !leaving.showing, "got \(leaving)")
        #expect(leaving.duration > 0, "cut rather than faded")
        #expect(leaving.duration < BandPop.duration, "leaving is as slow as arriving: \(leaving.duration)")
        #expect(leaving.dampingRatio == nil, "a departure that bounces")

        strip.debugTapTile("video-0")

        #expect(strip.debugBadgeChanges.count == 2, "got \(strip.debugBadgeChanges)")
        #expect(
            strip.debugBadgeChanges.last == NewPostMediaCell.BadgeChange(
                id: "video-0", showing: true,
                duration: BandPop.duration, dampingRatio: BandPop.dampingRatio
            ),
            "not the band's spring: \(String(describing: strip.debugBadgeChanges.last))"
        )
    }

    /// Reduce Motion: the word still comes and goes, with no curve at all.
    @Test func underReduceMotionTheCoversWordComesAndGoesAtOnce() async throws {
        let screen = open(Self.items(2, videosAt: [0]), reducesMotion: true)
        appear(screen)
        try await breathe()
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        try #require(strip.debugClipState(for: "video-0") == .sheet, "guard: the cover rests")

        strip.debugTapTile("video-0")
        #expect(!strip.debugCoverBadgeIsShowing(for: "video-0"), "the word stayed over the film")
        strip.debugTapTile("video-0")
        #expect(strip.debugCoverBadgeIsShowing(for: "video-0"), "and it did not come back")

        let changes = strip.debugBadgeChanges
        try #require(changes.map(\.showing) == [false, true], "guard: it went and came back: \(changes)")
        #expect(changes.allSatisfy { $0.duration == 0 }, "a curve ran under Reduce Motion: \(changes)")
    }

    /// ⚠️ **A TILE'S FIRST STATE IS ITS DRESS.** `show` builds every badge
    /// showing and forgets every state, so a cover tile rebuilt while it is
    /// meant to be playing — a recycled cell — would be seen wearing its word
    /// and then shrugging it off. Asked of the cell directly, because no route
    /// through the screen rebuilds the strip without also resetting the states.
    @Test func aTileBuiltPlayingTakesItsWordOffWithoutACurve() throws {
        let strip = NewPostMediaCell(frame: CGRect(x: 0, y: 0, width: 390, height: 224))
        strip.reducesMotion = { false }
        strip.show(Self.items(2, videosAt: [0]), coverID: "video-0") { _, _ in nil }
        try #require(strip.debugCoverBadgeIsShowing(for: "video-0"), "guard: a badge is built showing")

        strip.setClipState(.playing, for: "video-0")

        #expect(!strip.debugCoverBadgeIsShowing(for: "video-0"))
        #expect(strip.debugBadgeChanges.map(\.duration) == [0],
                "a fresh tile was dressed on a curve: \(strip.debugBadgeChanges)")
    }

    /// ⚠️ **A FALLBACK HOLDS STILL.** The sheet under a playing surface is there
    /// for the moment before the first frame lands, and for the load that never
    /// arrives — left cycling it would be a second picture changing behind an
    /// opaque one, for nobody. It runs on the tiles that are AT REST.
    @Test func theFallbackUnderTheFilmHoldsStillWhileTheFilmRuns() async throws {
        let screen = open(Self.items(3, videosAt: [0, 2]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        // ⚠️ **REQUIRED, NOT WAITED FOR AND HOPED.** `settle(until:)` returns
        // when it gives up as well as when it succeeds, so a sheet that never
        // arrived would fall through to the assertions below and fail there
        // saying something else entirely. It did: a shared staleness counter
        // let each clip's sampling cancel the one before it, and what this
        // read as was "the frames are frozen".
        try await settle(until: { strip.debugSheetFrameCount(for: "video-0") > 0 })
        try await settle(until: { strip.debugSheetFrameCount(for: "video-2") > 0 })
        try #require(strip.debugSheetFrameCount(for: "video-0") > 0, "the cover's frames never arrived")
        try #require(strip.debugSheetFrameCount(for: "video-2") > 0, "the playing clip's frames never arrived")

        #expect(strip.debugSheetIsCycling(for: "video-0"), "the resting cover's frames are frozen")
        #expect(!strip.debugSheetIsCycling(for: "video-2"),
                "the frames under the running film are cycling too")
    }

    /// ⚠️ **THE SHEET IS UNDER THE SURFACE, WHICH IS WHAT MAKES IT A FALLBACK.**
    /// Asked for in those words. Over it, a tile would show sampled frames on
    /// top of the film it sampled them from; under it, the frames are what shows
    /// until the first real one lands — and if it never does.
    @Test func theFramesSitUnderTheFilmTheyWereSampledFrom() async throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        try await settle(until: { strip.debugSheetFrameCount(for: "video-1") > 0 })

        // See the note in `theFallbackUnderTheFilmHoldsStillWhileTheFilmRuns`:
        // a settle that gave up reads as a wrong answer rather than as no
        // answer, so the count is required before it is judged.
        try #require(strip.debugSheetFrameCount(for: "video-1") > 0, "the frames never arrived")
        #expect(strip.debugSheetFrameCount(for: "video-1") > 1, "one frame is not a sheet")
        #expect(strip.debugSheetIsUnderTheSurface(for: "video-1") == true,
                "the sheet is over the film, or one of them is not installed")

        // ⚠️ **AND AGAIN AFTER A ROUND TRIP, WHICH IS THE ORDER THAT CAN GO
        // WRONG.** On the first play the sheet does not exist yet — it is
        // sampled asynchronously and inserted underneath whatever is already
        // there, so the layering comes out right by accident. It is the SECOND
        // play, over a tile that already has its frames, where the surface has
        // to be put above them by name rather than at an index.
        strip.debugTapTile("video-1")
        try await breathe()
        strip.debugTapTile("video-1")
        try await settle(until: { screen.preview.plans.count == 2 })

        #expect(strip.debugSheetIsUnderTheSurface(for: "video-1") == true,
                "the second play put the film under its own fallback")
    }

    /// ⚠️ **A PUSH IS A DISAPPEARANCE TOO**, which is why the stop lives in
    /// `viewWillDisappear` rather than behind an `isMovingFromParent` guard.
    @Test func leavingTheScreenStopsThePlayingClip() async throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)
        let surface = try #require(strip.debugVideoSurface)

        disappear(screen)

        #expect(screen.preview.stopped.count == 1, "the player was given back")
        #expect(screen.preview.stopped.last === surface)
        #expect(screen.preview.boundCount == 0)
        #expect(strip.debugSurfaceTileID == nil, "the tile is a still again")
    }

    /// Publishing builds an export over the very file the strip is playing.
    @Test func postingStopsThePlayingClip() async throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        let strip = try #require(Self.strips(in: screen.window).first)

        screen.post.debugTapPost()

        #expect(screen.preview.boundCount == 0, "nothing is still decoding beside the export")
        #expect(screen.preview.stopped.count == 1)
        #expect(strip.debugSurfaceTileID == nil)
    }

    /// The cover row is a real control, and the player follows it — AWAY from
    /// the new cover.
    ///
    /// ⚠️ **THIS REVERSES THE DIRECTION IT WAS FIRST WRITTEN IN.** When the
    /// cover was the only tile that could move, naming a clip as cover was how
    /// you played it. The cover is now the tile that RESTS, so naming one is how
    /// you stop it — and the player goes to the next clip that wants it. Both
    /// readings are "the player follows the cover row"; only one of them is
    /// what the author asked for.
    @Test func changingTheCoverMovesThePlayerOffTheNewCover() async throws {
        let screen = open(Self.items(3, videosAt: [0, 2]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()
        try #require(Self.strips(in: screen.window).first?.debugSurfaceTileID == "video-2",
                     "guard: the non-cover clip is the one playing")

        screen.post.debugSetCover("video-2")
        try await settle(until: { screen.preview.plans.count == 2 })
        screen.window.layoutIfNeeded()

        let strip = try #require(Self.strips(in: screen.window).first)
        #expect(screen.preview.boundCount == 1, "not two players, one moved")
        #expect(strip.debugSurfaceTileID == "video-0",
                "the player stayed on the new cover: \(strip.debugSurfaceTileID ?? "nothing")")
        #expect(screen.preview.plans.last?.plan.sourceURL == screen.library.vended["video-0"])
        #expect(screen.preview.plans.last?.surface === strip.debugVideoSurface)
        #expect(strip.debugCoverBadgeIsShowing(for: "video-2"), "the new cover does not wear the word")
    }

    /// ⚠️ **THE RE-ENTRANCY PIN.** `viewDidAppear` runs again on every return to
    /// this screen, and the strip is redrawn by any reconfigure — so "start the
    /// cover" is asked far more often than the cover changes. Asking twice for
    /// the same clip in the same rectangle must mint nothing: a second item over
    /// a bound player restarts the picture the author is watching.
    @Test func askingTwiceForTheSameClipBindsNothingFurther() async throws {
        let screen = open(Self.items(2, videosAt: [1]))
        appear(screen)
        try await settle(until: { screen.preview.plans.count == 1 })
        screen.window.layoutIfNeeded()

        appear(screen)
        try await breathe()

        #expect(screen.preview.plans.count == 1, "the second appearance found it already playing")
        #expect(screen.preview.stopped.isEmpty, "and stopped nothing to find that out")
        #expect(screen.preview.boundCount == 1)
    }

    /// The strip cell, dug out of the hosted window — the same recursive shape
    /// `MediaEditorTests` uses to find its pages.
    private static func strips(in view: UIView) -> [NewPostMediaCell] {
        views(of: NewPostMediaCell.self, in: view)
    }

    private static func views<Kind: UIView>(of kind: Kind.Type, in view: UIView) -> [Kind] {
        var found: [Kind] = []
        for subview in view.subviews {
            if let match = subview as? Kind { found.append(match) }
            found += views(of: kind, in: subview)
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
