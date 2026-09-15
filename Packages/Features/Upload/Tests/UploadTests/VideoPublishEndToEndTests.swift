import AuthInterface
import AVFoundation
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE WHOLE CREATION PATH, WITH NOTHING STOOD IN FOR BUT THE NETWORK.**
///
/// Every other suite here cuts the chain somewhere: `NewPostTests` hands the
/// screen a stub library and a recording composer, `PostComposerTests` hands the
/// composer a clip and never opens a screen. Both are right for what they pin,
/// and together they still cannot answer the question a person actually asks —
/// *if I pick a video in this app, does it get posted?*
///
/// So this one runs the real `DebugMediaLibrary` (the device-media stand-in a
/// simulator build uses, synthesising genuine H.264), through the real
/// `NewPostViewController`, into a real `PostComposer`, against `MockBFF` — the
/// same in-process fleet the app talks to by default. Only the transport is
/// fake, and it is fake in exactly the way the app's own mock mode is.
///
/// ⚠️ **WHY THIS IS NOT REDUNDANT WITH THE SIMULATOR.** A simulator pass proves
/// it once, by hand, on a machine. CI has no photo library and no camera, and
/// for the whole life of this flow that meant the video path was untestable and
/// therefore untested — which is how `where !item.isVideo` survived four
/// screens' worth of work. `DebugMediaLibrary` is what removes that excuse.
@MainActor
struct VideoPublishEndToEndTests {
    private struct ViewerSessionStub: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    @MainActor
    private final class Handed {
        var entry: FeedEntry?
    }

    private struct Harness {
        let screen: NewPostViewController
        let window: UIWindow
        let library: DebugMediaLibrary
        let bff: MockBFF
        let handed: Handed

        var ticketCount: Int {
            bff.recordedRequests.filter { $0.path == "/media.v1.MediaService/IssueUploadTicket" }.count
        }
    }

    /// `DebugMediaLibrary` marks every fourth item a video, so a run of four
    /// gives exactly one clip among three photographs — the mixed selection the
    /// publish loop's ordering rules are about.
    private func open(_ chosen: [Int], of count: Int = 4) async -> Harness {
        let library = DebugMediaLibrary(count: count)
        let all = await library.items(in: "recents")
        let items = chosen.map { all[$0] }

        let bff = MockBFF()
        let blobStore = MockBlobStore()
        let postStore = MockPostStore()
        MockAuthService().register(on: bff)
        MockSocialServices(postStore: postStore).register(on: bff)
        MockMediaService(store: blobStore).register(on: bff)
        MockPostAuthoringService(store: postStore).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: bff
        )
        let composer = PostComposer(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: ViewerSessionStub(),
            uploadTransport: MockMediaUploadTransport(store: blobStore),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            composedChannel: ComposedPostChannel()
        )

        let handed = Handed()
        let screen = NewPostViewController(
            items: items, edits: [:], library: library, composer: composer
        ) { handed.entry = $0 }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        window.layoutIfNeeded()
        return Harness(
            screen: screen, window: window, library: library, bff: bff, handed: handed
        )
    }

    /// Generous: this one really encodes H.264, really runs an
    /// `AVAssetExportSession` and really walks the ticket/commit/resolve dance.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The mock library really is a video

    /// ⚠️ **A DURATION STAMP IS NOT A VIDEO.** `DebugMediaLibrary` marked every
    /// fourth item `.video(duration:)` and handed back a flat coloured square
    /// with no bytes anywhere behind it, which is enough to draw a grid and
    /// enough to fool every test that only ever looked at the grid. Everything
    /// downstream opens the file for real.
    @Test func theDeviceMockVendsAPlayableClipForItsVideos() async throws {
        let library = DebugMediaLibrary(count: 4)
        let items = await library.items(in: "recents")
        let video = try #require(items.first(where: { $0.isVideo }))

        let file = try #require(await library.videoFile(for: video.id))
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        #expect(tracks.isEmpty == false, "no video track behind \(file.lastPathComponent)")
        #expect(try await asset.load(.duration).seconds > 0)
    }

    /// The witness: a photograph answers nothing, so the line above is about
    /// videos and not about the method answering a file for anything at all.
    @Test func theDeviceMockVendsNoFileForAPhotograph() async throws {
        let library = DebugMediaLibrary(count: 4)
        let items = await library.items(in: "recents")
        let photo = try #require(items.first(where: { !$0.isVideo }))

        #expect(await library.videoFile(for: photo.id) == nil)
    }

    /// ⚠️ **A CLIP FOLLOWS THE SAME SHAPE RULE AS THE PHOTOGRAPH BESIDE IT, AND
    /// COMPARING IT TO ITS OWN TILE WOULD PROVE NOTHING.** That is what this
    /// test asked first, and it could not fail: since a video's tile IS a frame
    /// of its file, the two agree by construction. What is actually at risk is
    /// the rule *underneath* — the fixture alternates 3:4 and 4:3 by index so
    /// that fill and fit are visibly different in both directions, and a clip
    /// pinned to one orientation would quietly break that for every video tile.
    ///
    /// So it is asked against a PHOTOGRAPH of the same parity: same rule, two
    /// independent implementations of it.
    @Test func aMockVideoFollowsTheSameShapeRuleAsAPhotographOfItsParity() async throws {
        let library = DebugMediaLibrary(count: 8)
        let items = await library.items(in: "recents")
        // 3 and 7 are the videos; one is odd-indexed, the other odd too — so
        // reach for a photograph whose index has the SAME parity as each.
        let video = try #require(items.first(where: { $0.isVideo }))
        let index = Int(video.id.dropFirst("debug-".count)) ?? 0
        let twin = try #require(
            items.first { !$0.isVideo && (Int($0.id.dropFirst("debug-".count)) ?? 0) % 2 == index % 2 }
        )

        let file = try #require(await library.videoFile(for: video.id))
        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let photo = try #require(
            await library.thumbnail(for: twin.id, size: CGSize(width: 200, height: 200))
        )

        let clipIsPortrait = natural.height > natural.width
        let photoIsPortrait = photo.size.height > photo.size.width
        #expect(clipIsPortrait == photoIsPortrait,
                "clip \(video.id) is \(natural) but photograph \(twin.id) is \(photo.size)")
    }

    /// ⚠️ **A POSTER THAT IS BLACK IS NOT A POSTER.** The whole reason a clip
    /// uploads a still is that an .mp4 in `thumbnail_url` draws black; shipping
    /// a black JPEG instead would be the same hole with a `image/jpeg` label on
    /// it, and every structural assertion — two tickets, a non-mp4 URL, a seeded
    /// pipeline — would still pass. So this reads the PIXELS.
    ///
    /// Measured on the raw frame, before the tile's number is drawn over it.
    @Test func aMockVideosPosterHasActualColourInIt() async throws {
        let library = DebugMediaLibrary(count: 4)
        let items = await library.items(in: "recents")
        let video = try #require(items.first(where: { $0.isVideo }))
        let file = try #require(await library.videoFile(for: video.id))

        let frame = try #require(await VideoExporter().posterImage(for: file))
        let ink = try #require(Self.averageColour(of: frame))

        #expect(ink.r + ink.g + ink.b > 90,
                "the poster is black: r=\(ink.r) g=\(ink.g) b=\(ink.b)")
    }

    /// Mean RGB of an image, by drawing it down to a single pixel.
    private static func averageColour(of image: UIImage) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    // MARK: - Real clips, and the offline guarantee

    /// ⚠️ **THE MOST IMPORTANT LINE IN THIS FILE.** `MockMediaFixtures`' header
    /// states the rule the whole mock layer rests on: the unit suite, previews
    /// and CI run offline and must not depend on the network. Real clips are
    /// therefore opt-in, and this is what stops a future edit from making every
    /// run of this suite download Big Buck Bunny.
    ///
    /// The witness matters as much as the assertion: without it, a `realClip`
    /// that returned nil because the ROTATION broke would read as "correctly
    /// off".
    @Test func realClipsAreOffWithoutTheFlagSoTheSuiteNeverReachesTheNetwork() {
        #expect(DebugMediaLibrary.usesRealClips == false,
                "this suite must never be run with -rich-media")
        #expect(DebugMediaLibrary.realClip(forIndex: 3) == nil)
        #expect(DebugMediaLibrary.rotatedClip(forIndex: 3) != nil,
                "guard: the nil above is the flag, not a broken rotation")
    }

    /// Each video tile shows a different film until the catalogue runs out.
    /// Videos sit at every fourth index, so rotating on the index rather than on
    /// the video's ordinal would hand three of them the same clip.
    @Test func eachVideoGetsADifferentFilmBeforeTheRotationRepeats() throws {
        let films = [3, 7, 11].map { DebugMediaLibrary.rotatedClip(forIndex: $0)?.url }
        #expect(Set(films.compactMap { $0 }).count == 3, "got \(films)")
        #expect(
            DebugMediaLibrary.rotatedClip(forIndex: 15)?.url
                == DebugMediaLibrary.rotatedClip(forIndex: 3)?.url,
            "and the fourth wraps back to the first"
        )
    }

    @Test func onlyAVideoIndexGetsAFilm() {
        for index in [0, 1, 2, 4, 5, 6] {
            #expect(DebugMediaLibrary.rotatedClip(forIndex: index) == nil, "index \(index)")
        }
    }

    /// ⚠️ **A MANIFEST IS NOT A FILE, AND THE CATALOGUE IS FULL OF THEM.**
    /// `MockMediaFixtures` holds HLS ladders alongside progressive MP4s, and an
    /// `.m3u8` is an index over many segments: `PlaceholderVideoFetcher` passes
    /// it straight through uncached, `AVAssetExportSession` cannot write it to a
    /// file, and the publish would fail at the last step with the bytes already
    /// chosen. Copying one in here is a one-character mistake, so it is pinned.
    @Test func everyRealClipIsAProgressiveMp4OverHttps() throws {
        for clip in DebugMediaLibrary.realClips {
            let url = try #require(URL(string: clip.url))
            #expect(url.scheme == "https", "\(clip.url)")
            #expect(url.pathExtension.lowercased() == "mp4",
                    "\(clip.url) is not a progressive file")
            #expect(clip.seconds > 0)
        }
    }

    // MARK: - Picking a video and posting it

    /// ⚠️ **THE QUESTION THIS WHOLE SLICE EXISTS TO ANSWER, ASKED ONCE, END TO
    /// END.** Real device-media mock, real screen, real composer, real
    /// `AVAssetExportSession`, real ticket/commit/resolve/create/publish. If any
    /// link is broken this fails; nothing here is stubbed into agreeing.
    @Test func pickingAVideoAndPostingItPublishesAVideoAttachment() async throws {
        // Item 3 is the video; 0 and 1 are photographs.
        let harness = await open([0, 1, 3])

        harness.screen.debugTapPost()
        try await settle(until: { harness.handed.entry != nil })

        let entry = try #require(harness.handed.entry)
        #expect(entry.post.attachments.count == 3, "two photographs and a clip")

        let clip = try #require(entry.post.attachments.first { $0.mimeType == "video/mp4" })
        #expect(clip.pixelWidth > 0 && clip.pixelHeight > 0)
        // The optimistic entry plays the exported LOCAL file, so the author sees
        // their own clip before any fetch.
        #expect(clip.url?.isFileURL == true)
        let played = try #require(clip.url)
        #expect(try await AVURLAsset(url: played).loadTracks(withMediaType: .video).isEmpty == false,
                "the published clip has no video track: \(played.lastPathComponent)")

        // ⚠️ AND ITS FACE IS NOT THE CLIP. An .mp4 in `thumbnail_url` is a black
        // feed, not a missing picture — see `PostComposer.uploadPoster`.
        let poster = try #require(clip.thumbnailURL)
        #expect(poster != clip.url)
        #expect(poster.isFileURL == false, "the poster is uploaded, so it wears a delivery URL")

        // Four assets: three media, plus the clip's poster.
        #expect(harness.ticketCount == 4, "got \(harness.ticketCount)")

        let paths = harness.bff.recordedRequests.map(\.path)
        for step in [
            "/media.v1.MediaService/IssueUploadTicket",
            "/media.v1.MediaService/CommitUpload",
            "/media.v1.MediaService/ResolveDelivery",
            "/post.v1.PostService/CreatePost",
            "/post.v1.PostService/PublishPost"
        ] {
            #expect(paths.contains(step), "never reached \(step)")
        }
    }

    /// ⚠️ **AND THE ORDER SURVIVES, BECAUSE THE ORDER IS THE CAROUSEL.**
    /// `post.v1` has no per-attachment index, so the array's order is the only
    /// thing that says which medium leads — and a video is allowed to.
    @Test func aVideoChosenAsTheCoverLeadsThePublishedCarousel() async throws {
        let harness = await open([0, 1, 3])
        let video = try #require(
            await harness.library.items(in: "recents").first(where: { $0.isVideo })
        )

        harness.screen.debugSetCover(video.id)
        #expect(harness.screen.debugPublishOrder.first == video.id, "guard: it leads on screen")

        harness.screen.debugTapPost()
        try await settle(until: { harness.handed.entry != nil })

        let entry = try #require(harness.handed.entry)
        #expect(entry.post.attachments.first?.mimeType == "video/mp4",
                "the cover leads the carousel, and here the cover is the clip")
        #expect(entry.post.attachments.count == 3)
    }

    /// A post made only of clips is not a special case anywhere, and saying so
    /// costs one test — the cover default, the publish loop and the composer all
    /// have a "first photograph" shape in their history.
    @Test func aPostOfNothingButVideoPublishes() async throws {
        let harness = await open([3, 7], of: 8)
        let videos = await harness.library.items(in: "videos")
        #expect(videos.count >= 2, "guard: the Videos album holds more than one")
        harness.screen.debugTapPost()
        try await settle(until: { harness.handed.entry != nil })

        let entry = try #require(harness.handed.entry)
        #expect(entry.post.attachments.count == 2)
        #expect(entry.post.attachments.allSatisfy { $0.mimeType == "video/mp4" })
    }
}
