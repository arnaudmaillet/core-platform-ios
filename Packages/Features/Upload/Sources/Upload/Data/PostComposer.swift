import AuthInterface
import CoreContracts
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
    public init(_ image: UIImage) { self.image = image }
}

/// A picked video (a local file URL from the photo library) ready to compose.
public struct PickedVideo: Sendable, Equatable {
    public let sourceURL: URL
    public init(sourceURL: URL) { self.sourceURL = sourceURL }
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
    case media(String)
    case transport(String)
}

/// What the compose screens drive.
public protocol PostComposing: Sendable {
    /// Runs the full media.v1 upload + post.v1 create/publish flow as `author`
    /// — one of the signed-in account's profiles; nil means its first — and,
    /// on success, publishes the new entry to the shared `ComposedPostChannel`
    /// so the feed prepends it. Returns that same entry, so a screen can show
    /// the post it just made without fetching it back. Throws on any failed
    /// step; nothing partial is broadcast.
    @discardableResult
    func publish(media: ComposeMedia?, caption: String, as author: AuthorSummary?) async throws -> FeedEntry
}

public extension PostComposing {
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
    private let mediaClient: any Media_V1_MediaServiceClientInterface
    private let postClient: any Post_V1_PostServiceClientInterface
    private let profileClient: any Profile_V1_ProfileServiceClientInterface
    private let authSession: any AuthSessionProviding
    private let uploadTransport: any MediaUploadTransport
    private let imagePipeline: ImagePipeline
    private let composedChannel: ComposedPostChannel
    private let encoder: MediaEncoder
    private let videoExporter: VideoExporter
    private let resolveMaxAttempts: Int
    private let resolvePollSeconds: Double
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "compose")

    /// The signed-in account and every profile it holds — the set a post may be
    /// published as. Cached after the first read; refreshed once when asked to
    /// publish as a profile it does not contain (one created since).
    private var cachedAccount: (accountID: AccountID, profiles: [AuthorSummary])?

    public init(
        mediaClient: any Media_V1_MediaServiceClientInterface,
        postClient: any Post_V1_PostServiceClientInterface,
        profileClient: any Profile_V1_ProfileServiceClientInterface,
        authSession: any AuthSessionProviding,
        uploadTransport: any MediaUploadTransport,
        imagePipeline: ImagePipeline,
        composedChannel: ComposedPostChannel,
        encoder: MediaEncoder = MediaEncoder(),
        videoExporter: VideoExporter = VideoExporter(),
        resolveMaxAttempts: Int = 6,
        resolvePollSeconds: Double = 1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.mediaClient = mediaClient
        self.postClient = postClient
        self.profileClient = profileClient
        self.authSession = authSession
        self.uploadTransport = uploadTransport
        self.imagePipeline = imagePipeline
        self.composedChannel = composedChannel
        self.encoder = encoder
        self.videoExporter = videoExporter
        self.resolveMaxAttempts = resolveMaxAttempts
        self.resolvePollSeconds = resolvePollSeconds
        self.now = now
    }

    @discardableResult
    public func publish(media: ComposeMedia?, caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard media != nil || !trimmedCaption.isEmpty else {
            throw ComposeError.emptyPost
        }
        let viewer = try await resolveViewer(as: author)

        // `server` is what CreatePost references (the delivery URL); `optimistic`
        // is what the feed renders right away — for video that's the local file
        // so the author's own clip plays instantly, before any network fetch.
        var serverAttachment: MediaAttachment?
        var optimisticAttachment: MediaAttachment?
        var imageSeed: (image: UIImage, url: URL)?

        switch media {
        case .image(let picked):
            let attachment = try await uploadImage(picked, ownerID: viewer.accountID)
            serverAttachment = attachment
            optimisticAttachment = attachment
            if let url = attachment.url { imageSeed = (picked.image, url) }
        case .video(let picked):
            let uploaded = try await uploadVideo(picked, ownerID: viewer.accountID)
            serverAttachment = uploaded.server
            optimisticAttachment = uploaded.optimistic
        case .none:
            break
        }

        let attachmentInputs = serverAttachment.map { [makeAttachmentInput(from: $0)] } ?? []
        let postID = try await createDraft(
            profileID: viewer.author.id,
            caption: trimmedCaption,
            attachments: attachmentInputs,
            hasMedia: serverAttachment != nil
        )
        try await publishDraft(postID: postID, profileID: viewer.author.id)

        let entry = FeedEntry(
            post: Post(
                id: postID,
                authorID: viewer.author.id,
                caption: trimmedCaption,
                attachments: optimisticAttachment.map { [$0] } ?? [],
                publishedAt: now()
            ),
            author: viewer.author,
            likeCount: 0
        )

        // Seed the just-picked image under its CDN URL so the feed renders it
        // instantly, before any network fetch of that URL. (Video plays from the
        // local file URL carried on the optimistic attachment instead.)
        if let imageSeed {
            await imagePipeline.store(imageSeed.image, for: imageSeed.url)
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
            sha256: encoded.sha256Hex
        ) { ticket in
            try await self.uploadTransport.upload(encoded.data, using: ticket)
        }
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
    ) async throws -> (server: MediaAttachment, optimistic: MediaAttachment) {
        let exported: ExportedVideo
        do {
            exported = try await videoExporter.export(picked.sourceURL)
        } catch {
            throw ComposeError.media("couldn't prepare the video: \(error)")
        }
        let cdnURL = try await uploadAsset(
            ownerID: ownerID,
            mimeType: exported.mimeType,
            sizeBytes: exported.byteSize,
            sha256: exported.sha256Hex
        ) { ticket in
            try await self.uploadTransport.upload(fileURL: exported.fileURL, using: ticket)
        }
        let server = MediaAttachment(
            url: cdnURL,
            thumbnailURL: cdnURL,
            mimeType: exported.mimeType,
            pixelWidth: exported.pixelWidth,
            pixelHeight: exported.pixelHeight
        )
        // Optimistic entry plays the exported local file directly.
        let optimistic = MediaAttachment(
            url: exported.fileURL,
            thumbnailURL: exported.fileURL,
            mimeType: exported.mimeType,
            pixelWidth: exported.pixelWidth,
            pixelHeight: exported.pixelHeight
        )
        return (server, optimistic)
    }

    /// The shared media.v1 upload dance: IssueUploadTicket → byte upload
    /// (delegated) → CommitUpload → ResolveDelivery. Returns the delivery URL.
    private func uploadAsset(
        ownerID: AccountID,
        mimeType: String,
        sizeBytes: UInt64,
        sha256: String,
        uploadBytes: (MediaUploadTicket) async throws -> String
    ) async throws -> URL {
        // 1. Ticket. NOTE: MediaKind has no video value yet — pass `.postImage`
        //    until the Phase 3 contract adds `MEDIA_KIND_POST_VIDEO`. The mock
        //    ignores `kind` and routes on `declaredMimeType`.
        var ticketRequest = Media_V1_IssueUploadTicketRequest()
        ticketRequest.ownerID = ownerID.rawValue
        ticketRequest.kind = .postImage
        ticketRequest.declaredMimeType = mimeType
        ticketRequest.declaredSizeBytes = sizeBytes
        ticketRequest.contentSha256 = sha256
        ticketRequest.idempotencyKey = UUID().uuidString

        let ticketResponse = await mediaClient.issueUploadTicket(request: ticketRequest, headers: [:])
        let ticketBody = try unwrap(ticketResponse.message, errorMessage: ticketResponse.error?.message, as: ComposeError.media)
        let assetID = ticketBody.assetID

        // 2. Upload bytes + 3. Commit (skipped when the server deduplicated).
        if !ticketBody.deduplicated {
            guard let uploadURL = URL(string: ticketBody.ticket.uploadURL) else {
                throw ComposeError.media("invalid upload URL")
            }
            let ticket = MediaUploadTicket(
                uploadURL: uploadURL,
                httpMethod: ticketBody.ticket.method,
                requiredHeaders: ticketBody.ticket.requiredHeaders,
                maxSizeBytes: ticketBody.ticket.maxSizeBytes
            )
            let etag: String
            do {
                etag = try await uploadBytes(ticket)
            } catch {
                throw ComposeError.media("upload failed: \(error)")
            }

            var commitRequest = Media_V1_CommitUploadRequest()
            commitRequest.assetID = assetID
            commitRequest.etag = etag
            commitRequest.contentSha256 = sha256
            let commitResponse = await mediaClient.commitUpload(request: commitRequest, headers: [:])
            _ = try unwrap(commitResponse.message, errorMessage: commitResponse.error?.message, as: ComposeError.media)
        }

        // 4. Resolve delivery. Processing is async server-side (PENDING →
        //    worker), so poll until a rendition URL is available.
        return try await resolveDeliveryURL(assetID: assetID)
    }

    /// Polls ResolveDelivery until the asset has a rendition URL, tolerating
    /// the async media pipeline. Throws a clear error if it never becomes
    /// deliverable within the budget.
    private func resolveDeliveryURL(assetID: String) async throws -> URL {
        for attempt in 0..<resolveMaxAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(resolvePollSeconds))
            }
            var request = Media_V1_ResolveDeliveryRequest()
            request.assetID = assetID
            request.preferred = .mediaRenditionKindLarge
            let response = await mediaClient.resolveDelivery(request: request, headers: [:])
            if let body = response.message,
               let urlString = body.media.renditions.first(where: { !$0.url.isEmpty })?.url,
               let url = URL(string: urlString) {
                return url
            }
        }
        throw ComposeError.media("media still processing (asset \(assetID) not ready)")
    }

    private func createDraft(profileID: ProfileID, caption: String, attachments: [Post_V1_MediaAttachmentInput], hasMedia: Bool) async throws -> PostID {
        var request = Post_V1_CreatePostRequest()
        request.profileID = profileID.rawValue
        request.kind = hasMedia ? .carousel : .textOnly
        request.caption = caption
        request.attachments = attachments

        let response = await postClient.createPost(request: request, headers: [:])
        let body = try unwrap(response.message, errorMessage: response.error?.message, as: ComposeError.transport)
        return PostID(body.postID)
    }

    private func publishDraft(postID: PostID, profileID: ProfileID) async throws {
        var request = Post_V1_PublishPostRequest()
        request.postID = postID.rawValue
        request.profileID = profileID.rawValue
        let response = await postClient.publishPost(request: request, headers: [:])
        _ = try unwrap(response.message, errorMessage: response.error?.message, as: ComposeError.transport)
    }

    /// The profile a post is published as: `author` when the account holds it,
    /// otherwise — nil — the account's first profile, the only answer there was
    /// before a screen could say who.
    ///
    /// An author the cached list does not contain (a profile created since) is
    /// looked for once more before being refused: publishing as a profile this
    /// account does not hold is exactly what the check exists to stop.
    private func resolveViewer(as author: AuthorSummary?) async throws -> (accountID: AccountID, author: AuthorSummary) {
        var account = try await resolveAccount(refresh: false)
        guard let author else {
            guard let first = account.profiles.first else { throw ComposeError.noViewerProfile }
            return (account.accountID, first)
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
        if !refresh, let cachedAccount {
            return cachedAccount
        }
        guard case .authenticated(let accountID) = await authSession.currentState() else {
            throw ComposeError.notAuthenticated
        }
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID.rawValue
        let response = await profileClient.listProfilesByAccount(request: request, headers: [:])
        let body = try unwrap(response.message, errorMessage: response.error?.message, as: ComposeError.transport)
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

    private func unwrap<T>(_ message: T?, errorMessage: String?, as wrap: (String) -> ComposeError) throws -> T {
        guard let message else {
            throw wrap(errorMessage ?? "unknown error")
        }
        return message
    }
}
