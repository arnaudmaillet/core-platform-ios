import CoreContracts
import Foundation
import MediaCore

/// The media.v1 upload dance: IssueUploadTicket → byte upload (through a
/// `MediaUploadTransport`) → CommitUpload → ResolveDelivery. Shared by the
/// post composer and the Messages thread (#681), so a chat photo is uploaded
/// the way a post's is.
///
/// Encoding is the caller's: the uploader takes bytes (or a file) with the
/// declared mime type, size and SHA-256 the ticket needs.
public struct MediaAssetUploader: Sendable {
    /// What an upload produced: the asset's id and its delivery URL.
    public struct Asset: Sendable, Equatable {
        public let assetID: String
        public let url: URL

        public init(assetID: String, url: URL) {
            self.assetID = assetID
            self.url = url
        }
    }

    /// The bytes to send: in memory (a photo) or on disk (a video).
    public enum Payload: Sendable {
        case data(Data)
        case file(URL)
    }

    /// Where an upload failed, with the server's (or transport's) message.
    ///
    /// `failure` keeps WHY a step failed (#794), so a composer can say
    /// "You're offline" rather than "upload failed". Defaulted, so every
    /// `.upload("…")` still builds and every `case .upload:` still matches.
    public enum UploadError: Error, Equatable, Sendable, NetworkFailureCarrying {
        case ticket(String, failure: NetworkFailure? = nil)
        case upload(String, failure: NetworkFailure? = nil)
        case commit(String, failure: NetworkFailure? = nil)
        /// Processed too slowly: no rendition within the poll budget.
        case notReady(assetID: String)

        public var message: String {
            switch self {
            case .ticket(let message, _): "ticket: \(message)"
            case .upload(let message, _): "upload failed: \(message)"
            case .commit(let message, _): "commit: \(message)"
            case .notReady(let assetID): "media still processing (asset \(assetID) not ready)"
            }
        }

        public var networkFailure: NetworkFailure? {
            switch self {
            case .ticket(_, let failure), .upload(_, let failure), .commit(_, let failure): failure
            case .notReady: nil
            }
        }
    }

    private let mediaClient: any Media_V1_MediaServiceClientInterface
    private let transport: any MediaUploadTransport
    private let resolveMaxAttempts: Int
    private let resolvePollSeconds: Double

    public init(
        mediaClient: any Media_V1_MediaServiceClientInterface,
        transport: any MediaUploadTransport,
        resolveMaxAttempts: Int = 6,
        resolvePollSeconds: Double = 1
    ) {
        self.mediaClient = mediaClient
        self.transport = transport
        self.resolveMaxAttempts = resolveMaxAttempts
        self.resolvePollSeconds = resolvePollSeconds
    }

    /// Uploads `payload` for `ownerID` (an account id) and returns the asset
    /// once it has a delivery URL.
    ///
    /// `kind`: media.v1 has no video or chat kind yet, so everything goes as
    /// `.postImage`; the mock routes on `declaredMimeType`.
    ///
    /// ⚠️ **`idempotencyKey` BELONGS TO THE ASSET THE USER CHOSE, NOT TO THIS
    /// CALL (#795).** It used to be minted here, a fresh UUID per call — so a
    /// retry after a lost answer (the ticket issued, the bytes stored, the
    /// commit applied, and only the response gone) reserved a SECOND asset and
    /// uploaded everything again. The caller mints it once per picture or clip
    /// (a chat bubble, a carousel item) and hands the same key to every retry
    /// of it, so media.v1 can answer a replay with the asset it already has.
    /// No default on purpose: a default is exactly the per-call key this
    /// replaced.
    ///
    /// ⚠️ **WHAT GOES ON THE WIRE IS THE INTENT'S KEY AND THE CONTENT'S HASH
    /// (`wireKey`).** A retry can carry different BYTES for the same intent: a
    /// clip re-exported gets new timestamps (a new SHA-256), a library picture
    /// can come back degraded first and full later. One key over two contents
    /// would have the server refuse the commit — or answer with the OLD bytes.
    /// Keyed on both, identical bytes replay and changed bytes are a new asset.
    public func upload(
        _ payload: Payload,
        ownerID: String,
        mimeType: String,
        sizeBytes: UInt64,
        sha256: String,
        idempotencyKey: String,
        kind: Media_V1_MediaKind = .postImage
    ) async throws -> Asset {
        var ticketRequest = Media_V1_IssueUploadTicketRequest()
        ticketRequest.ownerID = ownerID
        ticketRequest.kind = kind
        ticketRequest.declaredMimeType = mimeType
        ticketRequest.declaredSizeBytes = sizeBytes
        ticketRequest.contentSha256 = sha256
        ticketRequest.idempotencyKey = Self.wireKey(idempotencyKey, sha256: sha256)

        let ticketResponse = await mediaClient.issueUploadTicket(request: ticketRequest, headers: [:])
        guard let ticketBody = ticketResponse.message else {
            throw UploadError.ticket(
                ticketResponse.error?.message ?? "unknown error", failure: ticketResponse.error.map { NetworkFailure($0) }
            )
        }
        let assetID = ticketBody.assetID

        // Bytes, then the commit — both skipped when the server deduplicated.
        if !ticketBody.deduplicated {
            guard let uploadURL = URL(string: ticketBody.ticket.uploadURL) else {
                throw UploadError.ticket("invalid upload URL")
            }
            let ticket = MediaUploadTicket(
                uploadURL: uploadURL,
                httpMethod: ticketBody.ticket.method,
                requiredHeaders: ticketBody.ticket.requiredHeaders,
                maxSizeBytes: ticketBody.ticket.maxSizeBytes
            )
            let etag: String
            do {
                switch payload {
                case .data(let data): etag = try await transport.upload(data, using: ticket)
                case .file(let url): etag = try await transport.upload(fileURL: url, using: ticket)
                }
            } catch {
                // The object-store PUT is a plain URLSession call: its
                // URLError says whether the device was offline.
                throw UploadError.upload(String(describing: error), failure: NetworkFailure.of(error))
            }

            var commitRequest = Media_V1_CommitUploadRequest()
            commitRequest.assetID = assetID
            commitRequest.etag = etag
            commitRequest.contentSha256 = sha256
            let commitResponse = await mediaClient.commitUpload(request: commitRequest, headers: [:])
            // ⚠️ A FAILED COMMIT ON AN ASSET ALREADY PAST PENDING IS A SUCCESS
            // (#795): the commit landed before — the answer was lost, or a
            // replayed ticket brought the bytes to an asset that was done —
            // and there is nothing left to finalise. Asked once, not polled.
            if commitResponse.message == nil, await delivery(of: assetID)?.state.isPastPending != true {
                throw UploadError.commit(
                    commitResponse.error?.message ?? "unknown error", failure: commitResponse.error.map { NetworkFailure($0) }
                )
            }
        }

        return Asset(assetID: assetID, url: try await resolveDeliveryURL(assetID: assetID))
    }

    /// The key a ticket carries for `intent` over content `sha256`: the
    /// intent's own key while the bytes are the same, a new one when they
    /// changed (see `upload`). Internal for tests.
    static func wireKey(_ intent: String, sha256: String) -> String {
        sha256.isEmpty ? intent : intent + ":" + String(sha256.prefix(16))
    }

    /// Polls ResolveDelivery until the asset has a rendition URL: processing
    /// is asynchronous server-side (PENDING → worker).
    private func resolveDeliveryURL(assetID: String) async throws -> URL {
        for attempt in 0..<resolveMaxAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(resolvePollSeconds))
            }
            if let urlString = await delivery(of: assetID)?.renditions.first(where: { !$0.url.isEmpty })?.url,
               let url = URL(string: urlString) {
                return url
            }
        }
        throw UploadError.notReady(assetID: assetID)
    }

    /// One ResolveDelivery answer, or nil when it failed.
    private func delivery(of assetID: String) async -> Media_V1_DeliveredMedia? {
        var request = Media_V1_ResolveDeliveryRequest()
        request.assetID = assetID
        request.preferred = .mediaRenditionKindLarge
        return await mediaClient.resolveDelivery(request: request, headers: [:]).message?.media
    }
}

private extension Media_V1_AssetState {
    /// Committed already: uploaded, processing, or ready.
    var isPastPending: Bool {
        self == .mediaAssetStateUploaded || self == .mediaAssetStateProcessing || self == .mediaAssetStateReady
    }
}
