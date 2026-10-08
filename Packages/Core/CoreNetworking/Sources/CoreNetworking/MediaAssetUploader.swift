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
    public enum UploadError: Error, Equatable, Sendable {
        case ticket(String)
        case upload(String)
        case commit(String)
        /// Processed too slowly: no rendition within the poll budget.
        case notReady(assetID: String)

        public var message: String {
            switch self {
            case .ticket(let message): "ticket: \(message)"
            case .upload(let message): "upload failed: \(message)"
            case .commit(let message): "commit: \(message)"
            case .notReady(let assetID): "media still processing (asset \(assetID) not ready)"
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
    public func upload(
        _ payload: Payload,
        ownerID: String,
        mimeType: String,
        sizeBytes: UInt64,
        sha256: String,
        kind: Media_V1_MediaKind = .postImage
    ) async throws -> Asset {
        var ticketRequest = Media_V1_IssueUploadTicketRequest()
        ticketRequest.ownerID = ownerID
        ticketRequest.kind = kind
        ticketRequest.declaredMimeType = mimeType
        ticketRequest.declaredSizeBytes = sizeBytes
        ticketRequest.contentSha256 = sha256
        ticketRequest.idempotencyKey = UUID().uuidString

        let ticketResponse = await mediaClient.issueUploadTicket(request: ticketRequest, headers: [:])
        guard let ticketBody = ticketResponse.message else {
            throw UploadError.ticket(ticketResponse.error?.message ?? "unknown error")
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
                throw UploadError.upload(String(describing: error))
            }

            var commitRequest = Media_V1_CommitUploadRequest()
            commitRequest.assetID = assetID
            commitRequest.etag = etag
            commitRequest.contentSha256 = sha256
            let commitResponse = await mediaClient.commitUpload(request: commitRequest, headers: [:])
            guard commitResponse.message != nil else {
                throw UploadError.commit(commitResponse.error?.message ?? "unknown error")
            }
        }

        return Asset(assetID: assetID, url: try await resolveDeliveryURL(assetID: assetID))
    }

    /// Polls ResolveDelivery until the asset has a rendition URL: processing
    /// is asynchronous server-side (PENDING → worker).
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
        throw UploadError.notReady(assetID: assetID)
    }
}
