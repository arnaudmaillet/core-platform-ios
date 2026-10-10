import Connect
import CoreContracts
import MediaCore
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
    /// The asset each (owner, idempotency key) reserved (#795).
    private var assetsByKey: [String: String] = [:]

    public init() {}

    /// How many assets have been reserved — what a test counts to tell a
    /// replayed upload from a second one (#795).
    public var assetCount: Int { lock.withLock { assets.count } }

    /// What a ticket request reserved (#795).
    enum Reservation {
        /// A new asset.
        case fresh(String)
        /// The asset an earlier ticket under the same key reserved.
        case replay(String)
        /// The key was used before for DIFFERENT content.
        case conflict
    }

    /// Reserves an asset — or, under an idempotency key an earlier ticket
    /// already used for this owner, answers with THAT asset, reserving
    /// nothing (#795).
    ///
    /// ⚠️ **ONE KEY, ONE CONTENT.** A key replayed with another SHA-256 is
    /// refused (`conflict`), never answered with the first asset: that would
    /// hand back the OLD bytes for a picture the caller has since changed.
    /// The client keys on the content too (`MediaAssetUploader.wireKey`), so
    /// this only fires for a caller that does not.
    ///
    /// ⚠️ **LOOKUP AND RESERVATION ARE ONE CRITICAL SECTION.** Two tickets
    /// racing under one key must not both miss and reserve two assets — the
    /// very duplicate the key exists to prevent.
    func reserve(
        ownerID: String, mimeType: String, size: UInt64, sha256: String, idempotencyKey: String
    ) -> Reservation {
        lock.withLock {
            let keyed = idempotencyKey.isEmpty ? nil : ownerID + "\u{1F}" + idempotencyKey
            if let keyed, let assetID = assetsByKey[keyed], let record = assets[assetID] {
                return record.sha256 == sha256 ? .replay(assetID) : .conflict
            }
            let assetID = "asset-\(UUID().uuidString.prefix(12))"
            assets[assetID] = AssetRecord(
                ownerID: ownerID, mimeType: mimeType, declaredSize: size,
                sha256: sha256, state: .mediaAssetStatePending, bytes: nil
            )
            if let keyed { assetsByKey[keyed] = assetID }
            return .fresh(assetID)
        }
    }

    /// Stages the bytes. The asset stays PENDING until its commit, as on the
    /// fleet; a finalised asset keeps the bytes it was committed with (a
    /// replayed ticket's second PUT changes nothing).
    func putBytes(_ data: Data, assetID: String) -> Bool {
        lock.withLock {
            guard let record = assets[assetID] else { return false }
            if record.state == .mediaAssetStatePending { assets[assetID]?.bytes = data }
            return true
        }
    }

    /// Idempotent like media.v1's (`commit_upload.rs`): an asset already
    /// past pending is returned unchanged.
    func commit(assetID: String) -> AssetRecord? {
        lock.withLock {
            guard var record = assets[assetID], record.bytes != nil else { return nil }
            guard record.state == .mediaAssetStatePending else { return record }
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
    private let faults: MockNetworkFaults?

    public init(store: MockBlobStore, faults: MockNetworkFaults? = nil) {
        self.store = store
        self.faults = faults
    }

    public func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String {
        // The PUT bypasses the BFF, so the fault switchboard is asked here too
        // (#790): offline, or a failed PUT at the configured rate.
        if faults?.isOffline == true {
            throw MediaUploadError.transport("The Internet connection appears to be offline.")
        }
        if faults?.failsUpload() == true {
            throw MediaUploadError.transport("simulated upload failure")
        }
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
        // ⚠️ A REPLAYED KEY GETS "THE SAME ASSET/TICKET RATHER THAN A NEW
        // ONE", in the proto's words (#795), and is NOT `deduplicated`: that
        // flag means a content-hash match onto an asset already READY, which
        // this mock never does (dedup is off by default on the fleet too). A
        // replay of a finished asset therefore gets its ticket back; the
        // second PUT changes nothing and the commit is idempotent. The fleet's
        // media.v1 accepts the key but does not honour it yet (its "Phase-4
        // cache adapter"); this is the behaviour the field promises.
        let assetID: String
        switch store.reserve(
            ownerID: request.ownerID,
            mimeType: request.declaredMimeType,
            size: request.declaredSizeBytes,
            sha256: request.contentSha256,
            idempotencyKey: request.idempotencyKey
        ) {
        case .fresh(let id), .replay(let id):
            assetID = id
        case .conflict:
            return .failure(ConnectError(
                code: .failedPrecondition, message: "idempotency_key already used for different content"
            ))
        }

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

    /// Renditions only for a finalised asset: a pending one answers with its
    /// state and nothing to play, as the fleet does before its worker runs.
    private func resolve(_ request: Media_V1_ResolveDeliveryRequest) -> Result<Media_V1_ResolveDeliveryResponse, ConnectError> {
        guard let record = store.record(for: request.assetID) else {
            return .failure(ConnectError(code: .notFound, message: "asset \(request.assetID) not found"))
        }
        var media = Media_V1_DeliveredMedia()
        media.assetID = request.assetID
        media.state = record.state
        if record.state == .mediaAssetStateReady {
            var rendition = Media_V1_DeliveredRendition()
            rendition.kind = .mediaRenditionKindLarge
            rendition.url = "mock://asset/\(request.assetID)"
            media.renditions = [rendition]
        }

        var response = Media_V1_ResolveDeliveryResponse()
        response.media = media
        return .success(response)
    }
}
