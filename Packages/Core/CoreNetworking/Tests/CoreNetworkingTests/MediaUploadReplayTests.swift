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

    /// The commit landed and its answer did not: the retry finds the asset
    /// READY and is told so (`deduplicated`), uploading nothing again.
    @Test func aRetryAfterALostCommitAnswerReusesTheCommittedAsset() async throws {
        let (uploader, blobs) = uploader(losingOne: "/CommitUpload")

        await #expect(throws: MediaAssetUploader.UploadError.self) {
            _ = try await upload(uploader, key: "photo-1")
        }
        try #require(blobs.assetCount == 1, "guard: the first attempt reserved its asset")
        let retried = try await upload(uploader, key: "photo-1")

        #expect(blobs.assetCount == 1, "the retry reserved a second asset")
        #expect(retried.url.absoluteString.contains(retried.assetID))
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
