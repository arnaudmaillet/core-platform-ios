import Auth
import AuthInterface
import ChatInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
#if MOCK_BACKEND
import CoreNetworkingMocks
import MediaPlaybackFixtures
#endif
import FeedInterface
import Foundation
import MediaCore
import UIKit
import Upload
import UploadInterface

// Compose and upload (#2375): the upload feature, the post composer and the
// media transport. Its properties are declared in `AppContainer.swift`, since
// an extension holds no stored property; they are built here.
extension AppContainer {
    // ⚠️ THE PIPELINE, WITH NO SCREEN IN FRONT OF IT. The compose screen was
    // deleted with the header "+" (#152): upload is being rebuilt from
    // scratch, and a half-designed screen is not a starting point.
    // `PostComposer` is — IssueUploadTicket → byte upload → CommitUpload →
    // ResolveDelivery → CreatePost → PublishPost is the same flow whatever
    // picks the media, it is covered by tests, and `-mock-compose-demo` still
    // drives it end to end. Whatever the new screens are, they talk to this.
    //
    // The "+" is back, in the TAB BAR, as a menu (`CreateTabItem`). Its Text
    // Post entry is Feed's text page, born empty, publishing through this
    // pipeline; Upload Media still opens an empty screen on purpose — see
    // `UploadFeatureBuilder`.

    /// Built on demand: its only state is what it is handed. The Text Post
    /// screen is Feed's, reached through a closure for the same lazy-cycle
    /// reason Chat's thread screens are (`chatFeature`).
    var uploadFeature: any UploadFeatureBuilding { uploadBuilder }

    /// The builder itself: Chat's send picker (`chatMediaPicker`) takes its
    /// picks, which the interface does not carry.
    var uploadBuilder: UploadFeatureBuilder {
        UploadFeatureBuilder(
            composer: postComposer, textPostScreens: { [unowned self] in self.feedFeature },
            fakeLibraryClips: Self.fakeLibraryClips
        )
    }

    /// `-upload-fake-library`'s clips (DEBUG): the mock's synthesised ones
    /// (#2516). The production app ships no synthetic media.
    private static var fakeLibraryClips: FakeLibraryClips? {
        #if MOCK_BACKEND
        return { seconds in PlaceholderVideoFetcher(durationSeconds: seconds) }
        #else
        return nil
        #endif
    }

    /// Where media bytes go: the mock's blob store, or the fleet's object
    /// store. Shared by posts and messages (#681).
    var mediaUploadTransport: any MediaUploadTransport {
        switch environment {
        #if MOCK_BACKEND
        case .mock:
            return MockMediaUploadTransport(store: mockBackend.blobStore, faults: mockNetworkFaults)
        #endif
        case .remote:
            // The media service presigns object-store URLs against the
            // Docker-internal host (minio:9000), unreachable from the
            // client; rewrite to the published host, preserving the signed
            // Host header. Remove once the fleet presigns a reachable host.
            return URLSessionMediaUploadTransport(
                hostRewrite: HostRewrite(from: "minio:9000", to: "localhost:9000")
            )
        }
    }

    // Computed (not lazy): the PostComposer init is actor-isolated, which a
    // stored-property initializer can't call under default-MainActor isolation.
    private(set) var postComposer: PostComposer {
        get {
            if let cachedPostComposer {
                return cachedPostComposer
            }
            let uploadTransport = mediaUploadTransport
            let composer = PostComposer(
                mediaClient: Media_V1_MediaServiceClient(client: authenticatedRPCClient),
                postClient: Post_V1_PostServiceClient(client: authenticatedRPCClient),
                profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient),
                authSession: sessionManager,
                viewer: viewerSession,
                uploadTransport: uploadTransport,
                imagePipeline: imagePipeline,
                composedChannel: composedPostChannel,
                // The author's just-published clips (#898): the app's one.
                publishedVideos: publishedVideos
            )
            cachedPostComposer = composer
            return composer
        }
        set { cachedPostComposer = newValue }
    }

    #if DEBUG
    /// The publisher of `-mock-compose-demo` and `-mock-compose-video-demo`,
    /// over the composer — built when this is read.
    var composeDemo: ComposeDemo { ComposeDemo(composer: postComposer) }
    #endif
}

#if DEBUG
/// Exercises the real upload + create + publish flow, so the compose wiring
/// is verifiable without driving the picker (the app coordinator's
/// `-mock-compose-demo` and `-mock-compose-video-demo`).
struct ComposeDemo: Sendable {
    let composer: PostComposer

    func publish(image: UIImage, caption: String) async {
        _ = try? await composer.publish(media: .image(PickedImage(image)), caption: caption)
    }

    func publish(videoAt source: URL, caption: String) async {
        _ = try? await composer.publish(media: .video(PickedVideo(sourceURL: source)), caption: caption)
    }
}
#endif
