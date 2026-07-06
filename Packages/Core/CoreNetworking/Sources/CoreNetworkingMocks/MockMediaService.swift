import Connect
import CoreContracts
import CoreMedia
import Foundation

/// Shared store for in-flight and committed mock assets, plus the uploaded
/// bytes. The mock upload transport writes here; MockMediaService reads here
/// on commit/resolve — the same split the real system has between the object
/// store and the media service.
public final class MockBlobStore: @unchecked Sendable {
    struct AssetRecord {
        var ownerID: String
        var mimeType: String
        var declaredSize: UInt64
        var sha256: String
        var state: Media_V1_AssetState
        var bytes: Data?
    }

    private let lock = NSLock()
    private var assets: [String: AssetRecord] = [:]

    public init() {}

    func createPending(ownerID: String, mimeType: String, size: UInt64, sha256: String) -> String {
        let assetID = "asset-\(UUID().uuidString.prefix(12))"
        lock.withLock {
            assets[assetID] = AssetRecord(
                ownerID: ownerID, mimeType: mimeType, declaredSize: size,
                sha256: sha256, state: .mediaAssetStatePending, bytes: nil
            )
        }
        return assetID
    }

    func putBytes(_ data: Data, assetID: String) -> Bool {
        lock.withLock {
            guard assets[assetID] != nil else { return false }
            assets[assetID]?.bytes = data
            assets[assetID]?.state = .mediaAssetStateUploaded
            return true
        }
    }

    func commit(assetID: String) -> AssetRecord? {
        lock.withLock {
            guard var record = assets[assetID], record.bytes != nil else { return nil }
            record.state = .mediaAssetStateReady
            assets[assetID] = record
            return record
        }
    }

    func record(for assetID: String) -> AssetRecord? {
        lock.withLock { assets[assetID] }
    }
}

/// In-process upload transport: parses the asset id from the mock ticket URL
/// (`mock://upload/{asset_id}`) and deposits the bytes in the shared blob
/// store, returning a synthetic ETag — standing in for the object-store PUT.
public struct MockMediaUploadTransport: MediaUploadTransport {
    private let store: MockBlobStore

    public init(store: MockBlobStore) {
        self.store = store
    }

    public func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String {
        guard data.count <= ticket.maxSizeBytes else {
            throw MediaUploadError.payloadTooLarge(limit: ticket.maxSizeBytes)
        }
        let assetID = ticket.uploadURL.lastPathComponent
        guard store.putBytes(data, assetID: assetID) else {
            throw MediaUploadError.transport("unknown asset \(assetID)")
        }
        return "etag-\(assetID)"
    }
}

/// Fake of media.v1: the ticket → commit → resolve flow over the blob store.
public final class MockMediaService: @unchecked Sendable {
    private let store: MockBlobStore
    private let maxSizeBytes: UInt64

    public init(store: MockBlobStore, maxSizeBytes: UInt64 = 25 * 1024 * 1024) {
        self.store = store
        self.maxSizeBytes = maxSizeBytes
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/media.v1.MediaService/IssueUploadTicket") { [self] (request: Media_V1_IssueUploadTicketRequest) in
            issueTicket(request)
        }
        bff.register(path: "/media.v1.MediaService/CommitUpload") { [self] (request: Media_V1_CommitUploadRequest) in
            commit(request)
        }
        bff.register(path: "/media.v1.MediaService/ResolveDelivery") { [self] (request: Media_V1_ResolveDeliveryRequest) in
            resolve(request)
        }
    }

    private func issueTicket(_ request: Media_V1_IssueUploadTicketRequest) -> Result<Media_V1_IssueUploadTicketResponse, ConnectError> {
        guard !request.ownerID.isEmpty else {
            return .failure(ConnectError(code: .invalidArgument, message: "owner_id required"))
        }
        let assetID = store.createPending(
            ownerID: request.ownerID,
            mimeType: request.declaredMimeType,
            size: request.declaredSizeBytes,
            sha256: request.contentSha256
        )

        var ticket = Media_V1_UploadTicket()
        ticket.uploadURL = "mock://upload/\(assetID)"
        ticket.method = "PUT"
        ticket.requiredHeaders = ["Content-Type": request.declaredMimeType]
        ticket.maxSizeBytes = maxSizeBytes

        var response = Media_V1_IssueUploadTicketResponse()
        response.assetID = assetID
        response.ticket = ticket
        response.deduplicated = false
        return .success(response)
    }

    private func commit(_ request: Media_V1_CommitUploadRequest) -> Result<Media_V1_CommitUploadResponse, ConnectError> {
        guard let record = store.commit(assetID: request.assetID) else {
            return .failure(ConnectError(code: .failedPrecondition, message: "asset not uploaded"))
        }
        var asset = Media_V1_Asset()
        asset.id = request.assetID
        asset.ownerID = record.ownerID
        asset.kind = .postImage
        asset.state = record.state
        asset.mimeType = record.mimeType
        asset.byteSize = UInt64(record.bytes?.count ?? 0)

        var response = Media_V1_CommitUploadResponse()
        response.asset = asset
        return .success(response)
    }

    private func resolve(_ request: Media_V1_ResolveDeliveryRequest) -> Result<Media_V1_ResolveDeliveryResponse, ConnectError> {
        guard store.record(for: request.assetID) != nil else {
            return .failure(ConnectError(code: .notFound, message: "asset \(request.assetID) not found"))
        }
        var rendition = Media_V1_DeliveredRendition()
        rendition.kind = .mediaRenditionKindLarge
        rendition.url = "mock://asset/\(request.assetID)"

        var media = Media_V1_DeliveredMedia()
        media.assetID = request.assetID
        media.state = .mediaAssetStateReady
        media.renditions = [rendition]

        var response = Media_V1_ResolveDeliveryResponse()
        response.media = media
        return .success(response)
    }
}
