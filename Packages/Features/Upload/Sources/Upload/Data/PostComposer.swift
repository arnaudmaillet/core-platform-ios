import AuthInterface
import CoreContracts
import CoreNetworking
import MediaCore
import MediaPlayback
import CoreModels
import Foundation
import OSLog
import UIKit

/// A picked image ready to compose. Boxed so it can cross into the composer
/// actor; picked images are immutable.
public struct PickedImage: @unchecked Sendable {
    public let image: UIImage
    /// media.v1's idempotency key for this picture's upload (#795).
    ///
    /// ⚠️ **ONE PER PICTURE THE AUTHOR CHOSE, NOT ONE PER PUBLISH.** A screen
    /// that offers a retry hands the SAME key back on the retry
    /// (`NewPostViewController.uploadKey(for:)`), so an upload whose answer
    /// was lost is not reserved and sent a second time.
    public let uploadKey: String

    /// A one-shot picture, with no retry to keep a key for: a key of its own.
    /// (Its own initialiser, not a defaulted parameter, so `PickedImage.init`
    /// still reads as `(UIImage) -> PickedImage` where it is passed along.)
    public init(_ image: UIImage) {
        self.init(image, uploadKey: UUID().uuidString)
    }

    public init(_ image: UIImage, uploadKey: String) {
        self.image = image
        self.uploadKey = uploadKey
    }
}

/// A picked video (a local file URL from the photo library) ready to compose.
public struct PickedVideo: Sendable, Equatable {
    public let sourceURL: URL

    /// The pieces of the clip to publish, in order, each with the rate it plays
    /// at. Empty is the whole of it, untouched.
    ///
    /// ⚠️ **SECONDS, NOT A `MediaTimeline` — AND THE BOUNDARY IS THE POINT.** A cut
    /// is an editor idea: handles, a minimum length, a stored value that can
    /// outlive the clip it was made for. None of that is the composer's
    /// business. What crosses is the answer, already resolved against the real
    /// duration, in the only unit an exporter accepts.
    ///
    /// ⚠️ **AND IT IS A LIST, WHICH IT WAS NOT.** It carried ONE range, so a
    /// timeline of several pieces could only ever publish its first — a split
    /// that looked like it worked and silently threw the rest away. The list is
    /// what makes the split safe to offer at all.
    ///
    /// Empty rather than one piece covering everything, for the reason
    /// `VideoExportPlan.segments` gives: the two are different instructions, and
    /// only empty takes the passthrough.
    public let keptPieces: [VideoExportSegment]

    /// What is drawn over the whole clip — its crop, its look and its
    /// overlays — as the editor showed it.
    public let finish: FrameFinish

    /// The author's own song under the clip, if any.
    public let soundtrack: VideoSoundtrack?

    /// The baked frames of the stickers the finish lays over the clip.
    public let artwork: (any OverlayArtwork)?

    /// media.v1's idempotency key for this clip's upload (#795). Kept across
    /// a retry for the reason `PickedImage.uploadKey` gives, and NOT compared
    /// by `==`: equality is about what is published, not which attempt it is.
    public let uploadKey: String

    /// The poster still's key: its own asset, so its own key — but derived,
    /// so a retried clip retries its poster under the same one too.
    var posterUploadKey: String { uploadKey + ".poster" }

    public init(
        sourceURL: URL, keptPieces: [VideoExportSegment] = [], finish: FrameFinish = .none,
        soundtrack: VideoSoundtrack? = nil, artwork: (any OverlayArtwork)? = nil,
        uploadKey: String = UUID().uuidString
    ) {
        self.uploadKey = uploadKey
        self.sourceURL = sourceURL
        self.keptPieces = keptPieces
        self.finish = finish
        self.soundtrack = soundtrack
        self.artwork = artwork
    }

    /// ⚠️ **THE ARTWORK IS NOT COMPARED.** It is a cache of pictures baked from
    /// the sticker identifiers the finish already names; two clips with equal
    /// finishes show the same stickers.
    public static func == (lhs: PickedVideo, rhs: PickedVideo) -> Bool {
        lhs.sourceURL == rhs.sourceURL && lhs.keptPieces == rhs.keptPieces
            && lhs.finish == rhs.finish && lhs.soundtrack == rhs.soundtrack
    }

    /// The export this clip asks for.
    ///
    /// ⚠️ **EVERY FIELD, OR THE PUBLISHED FILM IS NOT THE ONE WATCHED.** This
    /// crossed with the pieces alone: a whole-clip look, a crop, the text and
    /// the song were all shown in the editor and published as if never made.
    var plan: VideoExportPlan {
        VideoExportPlan(
            sourceURL: sourceURL, segments: keptPieces, finish: finish, soundtrack: soundtrack,
            artwork: artwork
        )
    }
}

/// The media attached to a compose draft.
public enum ComposeMedia: Sendable {
    case image(PickedImage)
    case video(PickedVideo)
}

public enum ComposeError: Error, Equatable, Sendable {
    case notAuthenticated
    case noViewerProfile
    case emptyPost
    /// The media could not be prepared or uploaded. `failure` keeps WHY an
    /// upload failed (#794); nil when it never reached the network.
    case media(String, failure: NetworkFailure? = nil)
    /// PST-1009: someone the post mentions doesn't allow mentions from the
    /// author ("Who Can Mention", #397). Nothing was created.
    case mentionRefused
    /// A post.v1 / profile.v1 call failed. `failure` keeps WHY (#794):
    /// offline, a timeout, a refusal, a server fault. Defaulted, so every
    /// `.transport("…")` still builds and every `case .transport:` matches.
    case transport(String, failure: NetworkFailure? = nil)
    /// CreatePost or PublishPost went out and its answer never came back: a
    /// timeout, or a connection lost mid-request (#794).
    ///
    /// ⚠️ THE POST MAY EXIST, so the author is told to look first, not to
    /// try again. CreatePost now carries the screen's key (#795), so a retry
    /// of the same post from the same screen is answered with the post that
    /// exists; but PublishPost has none and keys live in memory only.
    /// Apart from `transport`, whose failures never reached the server.
    case unconfirmed(String, failure: NetworkFailure? = nil)
}

extension ComposeError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        switch self {
        case .media(_, let failure), .transport(_, let failure), .unconfirmed(_, let failure): failure
        case .notAuthenticated, .noViewerProfile, .emptyPost, .mentionRefused: nil
        }
    }
}

extension ComposeError {
    /// What an `unconfirmed` publish says: look before posting again.
    public static let unconfirmedMessage =
        "Couldn\u{2019}t confirm your post. Check your profile before posting again."
}

extension ComposeError: LocalizedError {
    /// Said to the author by any screen, including those that don't import
    /// this module (the Text Post page). Only the refused mention has words
    /// of its own; the rest keep each screen's generic message.
    public var errorDescription: String? {
        switch self {
        case .mentionRefused: "Someone you mentioned doesn't allow mentions from you. Remove the mention and try again."
        case .unconfirmed: Self.unconfirmedMessage
        default: nil
        }
    }
}

/// What the compose screens drive.
public protocol PostComposing: Sendable {
    /// Runs the full media.v1 upload + post.v1 create/publish flow as `author`
    /// — one of the signed-in account's profiles; nil means its first — and,
    /// on success, publishes the new entry to the shared `ComposedPostChannel`
    /// so the feed prepends it. Returns that same entry, so a screen can show
    /// the post it just made without fetching it back. Throws on any failed
    /// step; nothing partial is broadcast.
    /// ⚠️ **PLURAL SINCE 2026-09-12, BECAUSE THE PICKER ALWAYS WAS.** The media
    /// picker lets a viewer choose up to twenty and `post.v1.CreatePostRequest`
    /// takes `attachments` repeated with `kind = .carousel`, but this seam took
    /// exactly one — so a twenty-item selection could only ever have published
    /// its first, silently. The contract was never the limit; this signature was.
    @discardableResult
    func publish(media: [ComposeMedia], caption: String, as author: AuthorSummary?) async throws -> FeedEntry

    /// `publish(media:caption:as:)` under the screen's `idempotencyKey` for
    /// this post (#795): minted once per publish intent and handed back by
    /// every retry of the same post — a new one when its content changes —
    /// so a CreatePost whose answer was lost is answered with the post it
    /// created instead of creating a second.
    @discardableResult
    func publish(
        media: [ComposeMedia], caption: String, as author: AuthorSummary?, idempotencyKey: String
    ) async throws -> FeedEntry
}

public extension PostComposing {
    /// Composers with no key to send (fakes): the publish as it was.
    @discardableResult
    func publish(
        media: [ComposeMedia], caption: String, as author: AuthorSummary?, idempotencyKey: String
    ) async throws -> FeedEntry {
        try await publish(media: media, caption: caption, as: author)
    }

    /// One item, or none — what the text-post path and every caller before the
    /// carousel says. Kept so widening the requirement churned nothing.
    @discardableResult
    func publish(media: ComposeMedia?, caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
        try await publish(media: media.map { [$0] } ?? [], caption: caption, as: author)
    }

    /// As the account's first profile — what every post was published as before
    /// a screen could say who its author is.
    @discardableResult
    func publish(media: ComposeMedia?, caption: String) async throws -> FeedEntry {
        try await publish(media: media, caption: caption, as: nil)
    }
}

/// Orchestrates the create-post flow end to end:
/// IssueUploadTicket → background byte upload → CommitUpload → ResolveDelivery
/// → CreatePost(draft) → PublishPost, then the optimistic local insert.
public actor PostComposer: PostComposing {
    private let postClient: any Post_V1_PostServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let imagePipeline: ImagePipeline
    private let composedChannel: ComposedPostChannel
    private let encoder: MediaEncoder
    private let videoExporter: VideoExporter
    /// How a video's poster still is obtained.
    ///
    /// ⚠️ **INJECTED SEPARATELY FROM `videoExporter`, AND ONLY BECAUSE ITS
    /// FAILURE HAS TO BE EXERCISABLE.** The poster is best-effort: when it
    /// cannot be made, the clip must still publish. A real `VideoExporter`
    /// always succeeds on a file it has just written itself, so that branch is
    /// unreachable through the normal seam — and an unreachable fallback is one
    /// nobody has ever seen run.
    private let posterFrame: @Sendable (ExportedVideo) async -> UIImage?
    /// Where a published clip goes for the author's own playback (#898).
    private let publishedVideos: PublishedVideoFiles
    private let uploader: MediaAssetUploader
    private let now: @Sendable () -> Date
    /// The waits before a keyed CreatePost asks again while its first call
    /// is still in flight on the server (ABORTED, PST-1010).
    private let inFlightRetryDelays: [Duration]
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "compose")

    /// The signed-in account and every profile it holds — the set a post may be
    /// published as. Cached after the first read; refreshed once when asked to
    /// publish as a profile it does not contain (one created since).
    private var cachedAccount: (accountID: AccountID, profiles: [AuthorSummary])?
    /// Who is signed in and as which profile — the author a post takes when
    /// the screen names none. Shared with every repository (`ViewerSession`).
    private let viewer: any ViewerProviding

    public init(
        mediaClient: any Media_V1_MediaServiceClientInterface,
        postClient: any Post_V1_PostServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        viewer: (any ViewerProviding)? = nil,
        uploadTransport: any MediaUploadTransport,
        imagePipeline: ImagePipeline,
        composedChannel: ComposedPostChannel,
        encoder: MediaEncoder = MediaEncoder(),
        videoExporter: VideoExporter = VideoExporter(),
        posterFrame: @escaping @Sendable (ExportedVideo) async -> UIImage? = {
            await VideoExporter().posterImage(for: $0)
        },
        publishedVideos: PublishedVideoFiles = .shared,
        resolveMaxAttempts: Int = 6,
        resolvePollSeconds: Double = 1,
        now: @escaping @Sendable () -> Date = { Date() },
        inFlightRetryDelays: [Duration] = IdempotencyKey.inFlightRetryDelays
    ) {
        self.inFlightRetryDelays = inFlightRetryDelays
        self.postClient = postClient
        self.profileClient = profileClient
        self.authSession = authSession
        // Nil only outside the app (tests, previews): a session of its own,
        // resolving through this composer's profile client.
        self.viewer = viewer ?? ViewerSession(authSession: authSession) { [profileClient] account in
            try await AccountProfilesReader.profileIDs(ofAccount: account.rawValue, using: profileClient)
                .map { ProfileID($0) }
        }
        self.imagePipeline = imagePipeline
        self.composedChannel = composedChannel
        self.encoder = encoder
        self.videoExporter = videoExporter
        self.posterFrame = posterFrame
        self.publishedVideos = publishedVideos
        self.uploader = MediaAssetUploader(
            mediaClient: mediaClient, transport: uploadTransport,
            resolveMaxAttempts: resolveMaxAttempts, resolvePollSeconds: resolvePollSeconds
        )
        self.now = now
    }

    /// Keyless: no deduplication. The compose screens always send a key.
    @discardableResult
    public func publish(media: [ComposeMedia], caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
        try await publish(media: media, caption: caption, as: author, idempotencyKey: "")
    }

    @discardableResult
    public func publish(
        media: [ComposeMedia], caption: String, as author: AuthorSummary?, idempotencyKey: String
    ) async throws -> FeedEntry {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !media.isEmpty || !trimmedCaption.isEmpty else {
            throw ComposeError.emptyPost
        }
        let viewer = try await resolveViewer(as: author)

        // `server` is what CreatePost references (the delivery URL); `optimistic`
        // is what the feed renders right away — for video that's the local file
        // so the author's own clip plays instantly, before any network fetch.
        var serverAttachments: [MediaAttachment] = []
        var optimisticAttachments: [MediaAttachment] = []
        var imageSeeds: [(image: UIImage, url: URL)] = []
        // Each clip's export, by its index in the carousel: what the entry
        // plays once the post is out (`keepPublishedClips`).
        var exports: [Int: ExportedVideo] = [:]

        // ⚠️ **IN ORDER, AND ONE AT A TIME.** The array's order IS the carousel's
        // order — `post.v1` has no per-attachment index — so these cannot be
        // uploaded concurrently and collected as they finish. A `TaskGroup` here
        // would publish the viewer's pictures in whatever order the network
        // happened to return them.
        for item in media {
            switch item {
            case .image(let picked):
                let attachment = try await uploadImage(picked, ownerID: viewer.accountID)
                serverAttachments.append(attachment)
                optimisticAttachments.append(attachment)
                if let url = attachment.url { imageSeeds.append((picked.image, url)) }
            case .video(let picked):
                let uploaded = try await uploadVideo(picked, ownerID: viewer.accountID)
                exports[serverAttachments.count] = uploaded.exported
                serverAttachments.append(uploaded.server)
                optimisticAttachments.append(uploaded.server)
                // A video's face is seeded exactly like a photograph's, so the
                // author's own post draws its poster at once rather than after a
                // round trip.
                if let poster = uploaded.posterSeed { imageSeeds.append(poster) }
            }
        }

        let attachmentInputs = serverAttachments.map { makeAttachmentInput(from: $0) }
        let postID = try await createDraft(
            profileID: viewer.author.id,
            caption: trimmedCaption,
            attachments: attachmentInputs,
            hasMedia: !serverAttachments.isEmpty,
            idempotencyKey: idempotencyKey
        )
        try await publishDraft(postID: postID, profileID: viewer.author.id)
        keepPublishedClips(exports, in: &optimisticAttachments)

        let entry = FeedEntry(
            post: Post(
                id: postID,
                authorID: viewer.author.id,
                caption: trimmedCaption,
                attachments: optimisticAttachments,
                publishedAt: now()
            ),
            author: viewer.author,
            likeCount: 0
        )

        // Seed the just-picked images — and each video's poster — under their
        // CDN URLs so the feed renders them instantly, before any network fetch.
        // (The clip itself plays from the local file URL carried on the
        // optimistic attachment.)
        for seed in imageSeeds {
            imagePipeline.store(seed.image, for: seed.url)
        }
        await composedChannel.publish(entry)
        return entry
    }

    // MARK: - Steps

    private func uploadImage(_ picked: PickedImage, ownerID: AccountID) async throws -> MediaAttachment {
        let encoded = try encoder.encode(picked.image)
        let cdnURL = try await uploadAsset(
            ownerID: ownerID,
            mimeType: encoded.mimeType,
            sizeBytes: encoded.byteSize,
            sha256: encoded.sha256Hex,
            idempotencyKey: picked.uploadKey,
            payload: .data(encoded.data)
        )
        return MediaAttachment(
            url: cdnURL,
            thumbnailURL: cdnURL,
            mimeType: encoded.mimeType,
            pixelWidth: encoded.pixelWidth,
            pixelHeight: encoded.pixelHeight
        )
    }

    private func uploadVideo(
        _ picked: PickedVideo,
        ownerID: AccountID
    ) async throws -> (
        server: MediaAttachment, exported: ExportedVideo, posterSeed: (image: UIImage, url: URL)?
    ) {
        let exported: ExportedVideo
        do {
            exported = try await videoExporter.export(picked.plan)
        } catch {
            throw ComposeError.media("couldn't prepare the video: \(error)")
        }
        let cdnURL = try await uploadAsset(
            ownerID: ownerID,
            mimeType: exported.mimeType,
            sizeBytes: exported.byteSize,
            sha256: exported.sha256Hex,
            idempotencyKey: picked.uploadKey,
            payload: .file(exported.fileURL)
        )

        let poster = await uploadPoster(for: exported, key: picked.posterUploadKey, ownerID: ownerID)

        let server = MediaAttachment(
            url: cdnURL,
            thumbnailURL: poster?.url ?? cdnURL,
            mimeType: exported.mimeType,
            pixelWidth: exported.pixelWidth,
            pixelHeight: exported.pixelHeight
        )
        return (server, exported, poster)
    }

    /// The post is out: each clip's export becomes what the entry plays.
    ///
    /// The optimistic entry plays the exported file itself, so the author's
    /// clip starts at once, before any fetch, and wears the poster's CDN URL
    /// so the face it asks for is the one the seed puts in the pipeline (the
    /// image path's trick). ⚠️ **MOVED, NOT LEFT IN THE TEMPORARY DIRECTORY
    /// (#898).** The export used to stay in `tmp` for good; it now goes into
    /// the device cache (`PublishedVideoFiles`), and its temporary file is
    /// gone. A clip the cache cannot take (a nearly full disk) plays from its
    /// delivery URL, and the export is deleted with its last copy. A publish
    /// that fails never gets here: its exports are deleted on the way out,
    /// and a retry exports again.
    private func keepPublishedClips(_ exports: [Int: ExportedVideo], in attachments: inout [MediaAttachment]) {
        for (index, exported) in exports where attachments.indices.contains(index) {
            let server = attachments[index]
            guard let delivery = server.url, let kept = publishedVideos.keep(exported, for: delivery) else { continue }
            attachments[index] = MediaAttachment(
                url: kept,
                thumbnailURL: server.thumbnailURL == delivery ? kept : server.thumbnailURL,
                mimeType: server.mimeType,
                pixelWidth: server.pixelWidth,
                pixelHeight: server.pixelHeight
            )
        }
    }

    /// A still frame for `thumbnail_url`, uploaded as its own image asset.
    ///
    /// ⚠️ **WITHOUT THIS, `thumbnail_url` IS THE .mp4 — AND THAT IS NOT "NO
    /// PICTURE", IT IS A BLACK FEED.** Every surface resolves a thumbnail
    /// through `ImagePipeline.image(for:)`, whose FETCH of a video URL
    /// *succeeds* — 200 OK, real bytes — and whose decode then fails. So the
    /// scheme-routing fetcher's placeholder-colour rescue never fires (it
    /// catches fetch failures, and the decode is downstream), nothing
    /// negative-caches, and every re-bind downloads the whole clip again through
    /// the image path. Measured consequences: a black snap-feed media area, dark
    /// PostGrid tiles, an empty cover slot in the media toolbar, a blank
    /// map→feed hero flight, and — because both For You and the profile gallery
    /// gate autoplay on `hasCover` — a clip that is **never admitted as an
    /// autoplay candidate**.
    ///
    /// ⚠️ **AND MOCK MODE CANNOT SHOW ANY OF IT.** `MockSocialServices` never
    /// points a `thumbnail_url` at a video; it serves `mock://frame0/…`. The
    /// defect is invisible in the simulator and appears only against a fleet
    /// that really stores what it is given.
    ///
    /// Best-effort on purpose: a poster that cannot be made or uploaded must not
    /// lose the author's video. The caller falls back to today's behaviour,
    /// which is wrong in the ways above but still publishes the clip — and
    /// `PHASE3_VIDEO_BACKEND.md` §3 has the server generating a real poster
    /// rendition anyway, once that worker exists.
    private func uploadPoster(
        for exported: ExportedVideo, key: String, ownerID: AccountID
    ) async -> (image: UIImage, url: URL)? {
        guard let frame = await posterFrame(exported) else {
            logger.warning("no poster frame for the picked video; thumbnail falls back to the clip")
            return nil
        }
        do {
            let encoded = try encoder.encode(frame)
            let url = try await uploadAsset(
                ownerID: ownerID,
                mimeType: encoded.mimeType,
                sizeBytes: encoded.byteSize,
                sha256: encoded.sha256Hex,
                idempotencyKey: key,
                payload: .data(encoded.data)
            )
            return (frame, url)
        } catch {
            logger.warning("poster upload failed (\(String(describing: error))); publishing without one")
            return nil
        }
    }

    /// The shared media.v1 upload dance (`MediaAssetUploader`, shared with the
    /// Messages thread since #681). Returns the delivery URL.
    private func uploadAsset(
        ownerID: AccountID,
        mimeType: String,
        sizeBytes: UInt64,
        sha256: String,
        idempotencyKey: String,
        payload: MediaAssetUploader.Payload
    ) async throws -> URL {
        do {
            return try await uploader.upload(
                payload, ownerID: ownerID.rawValue, mimeType: mimeType, sizeBytes: sizeBytes, sha256: sha256,
                idempotencyKey: idempotencyKey
            ).url
        } catch let error as MediaAssetUploader.UploadError {
            throw ComposeError.media(error.message, failure: error.networkFailure)
        }
    }

    /// ⚠️ **UNDER THE SCREEN'S KEY, SO A RETRY IS THE SAME POST (#795).**
    /// The server mints the post id; without `idempotency_key` a retry after
    /// a lost CreatePost answer created a second post. With it, a repeat from
    /// the same profile within 24 hours is answered with the post the first
    /// call created. (PublishPost carries no key; see `publishDraft` for a
    /// repeat of it.)
    ///
    /// ⚠️ **THIS ABORTED IS "NOT YET", NOT "NO".** While the first call is
    /// still in flight a repeat fails ABORTED (PST-1010,
    /// `IdempotencyKey.isInFlight`; any other ABORTED fails): it waits and asks again
    /// under the same key (`inFlightRetryDelays`), and only after the last
    /// wait fails like any other.
    private func createDraft(
        profileID: ProfileID, caption: String, attachments: [Post_V1_MediaAttachmentInput], hasMedia: Bool,
        idempotencyKey: String
    ) async throws -> PostID {
        var request = Post_V1_CreatePostRequest()
        request.profileID = profileID.rawValue
        request.kind = hasMedia ? .carousel : .textOnly
        request.caption = caption
        request.attachments = attachments
        request.idempotencyKey = IdempotencyKey.wire(idempotencyKey)

        var waits = inFlightRetryDelays[...]
        while true {
            let response = await postClient.createPost(request: request, headers: [:])
            if IdempotencyKey.isInFlight(response.error, code: "PST-1010"), !request.idempotencyKey.isEmpty,
               let wait = waits.popFirst() {
                // A publish cancelled while it waits is a publish that failed,
                // in the feature's words.
                do { try await Task.sleep(for: wait) } catch {
                    throw ComposeError.transport("cancelled", failure: .cancelled)
                }
                continue
            }
            if (response.error?.message ?? "").contains("PST-1009") { throw ComposeError.mentionRefused }
            let body = try unwrapWrite(
                response.message, errorMessage: response.error?.message, exception: response.error?.exception,
                failure: response.error.flatMap { NetworkFailure.of($0) }
            )
            return PostID(body.postID)
        }
    }

    /// ⚠️ **"ALREADY PUBLISHED" IS A SUCCESS (#795).** PublishPost carries no
    /// key: after a lost PublishPost answer, the retry's CreatePost replays
    /// the same draft — now published — and post.v1 refuses to publish it
    /// again, ALREADY_EXISTS "post … is already published" (PST-1002). That
    /// refusal says the post is up, which is all the author asked for.
    /// ("Already deleted" is ALREADY_EXISTS too, and stays a failure.)
    private func publishDraft(postID: PostID, profileID: ProfileID) async throws {
        var request = Post_V1_PublishPostRequest()
        request.postID = postID.rawValue
        request.profileID = profileID.rawValue
        let response = await postClient.publishPost(request: request, headers: [:])
        if let error = response.error, error.code == .alreadyExists,
           let message = error.message, message.contains("PST-1002") || message.contains("already published") {
            return
        }
        _ = try unwrapWrite(
            response.message, errorMessage: response.error?.message, exception: response.error?.exception,
            failure: response.error.flatMap { NetworkFailure.of($0) }
        )
    }

    /// The profile a post is published as: `author` when the account holds it,
    /// otherwise — nil — the active profile (the account's first until a switch).
    ///
    /// An author the cached list does not contain (a profile created since) is
    /// looked for once more before being refused: publishing as a profile this
    /// account does not hold is exactly what the check exists to stop.
    private func resolveViewer(as author: AuthorSummary?) async throws -> (accountID: AccountID, author: AuthorSummary) {
        var account = try await resolveAccount(refresh: false)
        guard let author else {
            let active = try? await viewer.activeProfileID()
            guard let profile = account.profiles.first(where: { $0.id == active }) ?? account.profiles.first else {
                throw ComposeError.noViewerProfile
            }
            return (account.accountID, profile)
        }
        if !account.profiles.contains(where: { $0.id == author.id }) {
            account = try await resolveAccount(refresh: true)
        }
        guard account.profiles.contains(where: { $0.id == author.id }) else {
            throw ComposeError.noViewerProfile
        }
        // The screen's own rendering of its author, verbatim: the post arrives
        // wearing exactly the face it was written under.
        return (account.accountID, author)
    }

    private func resolveAccount(refresh: Bool) async throws -> (accountID: AccountID, profiles: [AuthorSummary]) {
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ComposeError.notAuthenticated
        }
        // Keyed by account: after a sign-out and another sign-in, the previous
        // account's profiles must never be offered as authors.
        if !refresh, let cachedAccount, cachedAccount.accountID == accountID {
            return cachedAccount
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        let body = try unwrap(
            response.message, errorMessage: response.error?.message,
            failure: response.error.flatMap { NetworkFailure.of($0) }
        )
        let profiles = body.profiles.map { profile in
            AuthorSummary(
                id: ProfileID(profile.profileID),
                handle: profile.handle,
                displayName: profile.displayName,
                avatarURL: URL(string: profile.avatarURL)
            )
        }
        let resolved = (accountID, profiles)
        cachedAccount = resolved
        return resolved
    }

    private func makeAttachmentInput(from attachment: MediaAttachment) -> Post_V1_MediaAttachmentInput {
        var input = Post_V1_MediaAttachmentInput()
        input.cdnURL = attachment.url?.absoluteString ?? ""
        input.mimeType = attachment.mimeType
        input.width = UInt32(attachment.pixelWidth)
        input.height = UInt32(attachment.pixelHeight)
        input.thumbnailURL = attachment.thumbnailURL?.absoluteString ?? ""
        return input
    }

    /// `unwrap` for CreatePost / PublishPost: a request that went out and
    /// never got its answer — timed out, or its connection dropped mid-way
    /// (`networkConnectionLost`, which `NetworkFailure` counts as offline) —
    /// is `unconfirmed`, not a failure to retry (#794, #795). Offline before
    /// the request left (`notConnectedToInternet`...) stays `transport`.
    private func unwrapWrite<T>(
        _ message: T?, errorMessage: String?, exception: (any Error)?, failure: NetworkFailure?
    ) throws -> T {
        if message == nil, failure == .timeout || (exception as? URLError)?.code == .networkConnectionLost {
            throw ComposeError.unconfirmed(errorMessage ?? "no answer", failure: failure)
        }
        return try unwrap(message, errorMessage: errorMessage, failure: failure)
    }

    /// The answer's body, or a `transport` failure that keeps why the call
    /// failed (#794).
    private func unwrap<T>(_ message: T?, errorMessage: String?, failure: NetworkFailure?) throws -> T {
        guard let message else {
            throw ComposeError.transport(errorMessage ?? "unknown error", failure: failure)
        }
        return message
    }
}
