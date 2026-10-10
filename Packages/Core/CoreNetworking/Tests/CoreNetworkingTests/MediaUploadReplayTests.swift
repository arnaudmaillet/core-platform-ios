import Connect
import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import Testing

/// ⚠️ **A LOST ANSWER IS NOT A LOST WRITE (#795).** media.v1 can reserve the
/// asset, store the bytes and commit them, and only the answer go missing:
/// the client sees a failure and retries. Under the key it first used, the
/// retry is answered with the asset that already exists — one asset, not two.
struct MediaUploadReplayTests {
    /// Hands every call to the mock BFF — so the write is applied — and, while
    /// `losses` lasts, swaps the answer of a call on `path` for a transport
    /// failure: the server did it, the client never heard.
    private final class AckLosingRelay: HTTPClientInterface, @unchecked Sendable {
        private let bff: MockBFF
        private let path: String
        private let lock = NSLock()
        private var losses: Int

        init(_ bff: MockBFF, losing losses: Int, on path: String) {
            self.bff = bff
            self.path = path
            self.losses = losses
        }

        @discardableResult
        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            let loses = request.url.path.hasSuffix(path) && lock.withLock {
                guard losses > 0 else { return false }
                losses -= 1
                return true
            }
            guard loses else { return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse) }
            return bff.unary(request: request, onMetrics: onMetrics) { _ in
                let lost = ConnectError(code: .unavailable, message: "the answer was lost")
                onResponse(HTTPResponse(
                    code: lost.code, headers: [:], message: nil, trailers: [:], error: lost, tracingInfo: nil
                ))
            }
        }

        func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
            bff.stream(request: request, responseCallbacks: responseCallbacks)
        }
    }

    private func uploader(losingOne path: String) -> (MediaAssetUploader, MockBlobStore) {
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockMediaService(store: blobs).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(
            host: "https://mock.bff.local", httpClient: AckLosingRelay(bff, losing: 1, on: path)
        )
        let uploader = MediaAssetUploader(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            transport: MockMediaUploadTransport(store: blobs),
            resolveMaxAttempts: 3, resolvePollSeconds: 0.01
        )
        return (uploader, blobs)
    }

    private func upload(_ uploader: MediaAssetUploader, key: String) async throws -> MediaAssetUploader.Asset {
        let bytes = Data(repeating: 9, count: 256)
        return try await uploader.upload(
            .data(bytes), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
            sizeBytes: UInt64(bytes.count), sha256: String(repeating: "d", count: 64), idempotencyKey: key
        )
    }

    /// The commit landed and its answer did not: a failed commit on an asset
    /// already past pending is a success — the upload completes on the asset
    /// it made, with no retry and no second asset.
    @Test func aLostCommitAnswerOnACommittedAssetIsASuccess() async throws {
        let (uploader, blobs) = uploader(losingOne: "/CommitUpload")

        let asset = try await upload(uploader, key: "photo-1")

        #expect(blobs.assetCount == 1)
        #expect(asset.url.absoluteString.contains(asset.assetID))
    }

    /// A retried upload of a finished asset — same intent, same bytes — is the
    /// same asset: its ticket comes back, the second PUT and commit change
    /// nothing.
    @Test func aRetryOfAFinishedUploadIsTheSameAsset() async throws {
        let (uploader, blobs) = uploader(losingOne: "/none")

        let first = try await upload(uploader, key: "photo-2")
        let again = try await upload(uploader, key: "photo-2")

        #expect(again.assetID == first.assetID)
        #expect(blobs.assetCount == 1)
    }

    /// ⚠️ THE MOCK SPEAKS media.v1's WORDS: a replayed key returns the same
    /// asset AND ITS TICKET, never `deduplicated` — that flag is a
    /// content-hash match onto a READY asset. And one key over other bytes is
    /// refused, not answered with the first asset's old bytes.
    @Test func aReplayedTicketIsTheSameAssetAndTicketAndOtherBytesAreRefused() async throws {
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockMediaService(store: blobs).register(on: bff)
        let client = Media_V1_MediaServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        var request = Media_V1_IssueUploadTicketRequest()
        request.ownerID = MockAuthService.accountID
        request.declaredMimeType = "image/jpeg"
        request.declaredSizeBytes = 4
        request.contentSha256 = String(repeating: "1", count: 64)
        request.idempotencyKey = "wire-key"

        let firstAnswer = await client.issueUploadTicket(request: request, headers: [:])
        let first = try #require(firstAnswer.message)
        let uploadURL = try #require(URL(string: first.ticket.uploadURL))
        _ = try await MockMediaUploadTransport(store: blobs).upload(
            Data([1, 2, 3, 4]),
            using: MediaUploadTicket(uploadURL: uploadURL, httpMethod: "PUT", requiredHeaders: [:], maxSizeBytes: 64)
        )
        var commit = Media_V1_CommitUploadRequest()
        commit.assetID = first.assetID
        let committed = await client.commitUpload(request: commit, headers: [:])
        try #require(committed.message != nil, "guard: the first commit lands")

        let replayAnswer = await client.issueUploadTicket(request: request, headers: [:])
        let replay = try #require(replayAnswer.message)
        #expect(replay.assetID == first.assetID)
        #expect(replay.deduplicated == false, "a key replay is not a content-hash dedup")
        #expect(replay.ticket.uploadURL == first.ticket.uploadURL)
        let recommitted = await client.commitUpload(request: commit, headers: [:])
        #expect(recommitted.message?.asset.state == .mediaAssetStateReady,
                "a second commit on a ready asset is not idempotent")

        request.contentSha256 = String(repeating: "2", count: 64)
        let other = await client.issueUploadTicket(request: request, headers: [:])
        #expect(other.message == nil && other.error?.code == .failedPrecondition)
        #expect(blobs.assetCount == 1)
    }

    /// The ticket was issued and its answer lost: the retry is handed a
    /// ticket to the SAME asset, and the upload completes on it.
    @Test func aRetryAfterALostTicketAnswerUploadsToTheSameAsset() async throws {
        let (uploader, blobs) = uploader(losingOne: "/IssueUploadTicket")

        await #expect(throws: MediaAssetUploader.UploadError.self) {
            _ = try await upload(uploader, key: "clip-1")
        }
        _ = try await upload(uploader, key: "clip-1")

        #expect(blobs.assetCount == 1, "the retry reserved a second asset")
    }

    /// The other half: another key is another asset. Without this, a mock
    /// that answered every ticket with the first asset would pass above.
    @Test func anotherKeyIsAnotherAsset() async throws {
        let (uploader, blobs) = uploader(losingOne: "/none")

        let first = try await upload(uploader, key: "a")
        let second = try await upload(uploader, key: "b")

        #expect(first.assetID != second.assetID)
        #expect(blobs.assetCount == 2)
    }
}
