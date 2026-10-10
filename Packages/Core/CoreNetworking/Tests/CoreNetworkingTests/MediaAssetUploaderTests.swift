import Connect
import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import SwiftProtobuf
import Testing

/// The media.v1 upload dance the post composer and the Messages thread share
/// (#681), against the mock BFF.
struct MediaAssetUploaderTests {
    private struct Refused: Error {}

    private struct FailingTransport: MediaUploadTransport {
        func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String { throw Refused() }
    }

    /// Sits between the generated client and the mock BFF and reads the
    /// idempotency key off every IssueUploadTicket that crosses (#795).
    private final class Relay: HTTPClientInterface, @unchecked Sendable {
        private let bff: MockBFF
        private let lock = NSLock()
        private var keys: [String] = []

        init(_ bff: MockBFF) { self.bff = bff }

        var ticketKeys: [String] { lock.withLock { keys } }

        @discardableResult
        func unary(
            request: HTTPRequest<Data?>,
            onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
            onResponse: @escaping @Sendable (HTTPResponse) -> Void
        ) -> Cancelable {
            if request.url.path.hasSuffix("/IssueUploadTicket"),
               let ticket = try? Media_V1_IssueUploadTicketRequest(serializedBytes: request.message ?? Data()) {
                lock.withLock { keys.append(ticket.idempotencyKey) }
            }
            return bff.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }

        func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
            bff.stream(request: request, responseCallbacks: responseCallbacks)
        }
    }

    private func uploader(transport: (any MediaUploadTransport)? = nil) -> (MediaAssetUploader, MockBlobStore) {
        let (uploader, blobs, _) = relayedUploader(transport: transport)
        return (uploader, blobs)
    }

    private func relayedUploader(
        transport: (any MediaUploadTransport)? = nil
    ) -> (MediaAssetUploader, MockBlobStore, Relay) {
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockMediaService(store: blobs).register(on: bff)
        let relay = Relay(bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: relay)
        let uploader = MediaAssetUploader(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            transport: transport ?? MockMediaUploadTransport(store: blobs),
            resolveMaxAttempts: 3, resolvePollSeconds: 0.01
        )
        return (uploader, blobs, relay)
    }

    @Test func bytesGoUpAndComeBackAsADeliveryURL() async throws {
        let (uploader, _) = uploader()
        let bytes = Data(repeating: 7, count: 512)
        let asset = try await uploader.upload(
            .data(bytes), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
            sizeBytes: UInt64(bytes.count), sha256: String(repeating: "a", count: 64), idempotencyKey: "k-1"
        )
        #expect(!asset.assetID.isEmpty)
        #expect(asset.url.absoluteString.contains(asset.assetID))
    }

    @Test func aFailedByteUploadSaysWhere() async throws {
        let (uploader, _) = uploader(transport: FailingTransport())
        await #expect {
            _ = try await uploader.upload(
                .data(Data([1, 2, 3])), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
                sizeBytes: 3, sha256: String(repeating: "b", count: 64), idempotencyKey: "k-2"
            )
        } throws: { error in
            if case .upload = error as? MediaAssetUploader.UploadError { return true }
            return false
        }
    }

    /// ⚠️ THE TICKET CARRIES THE CALLER'S KEY, EVERY TIME (#795). It used to
    /// be minted inside `upload`, a new one per call — so no retry could ever
    /// be recognised as one. On the wire it is joined to the content's hash.
    @Test func everyAttemptAsksForItsTicketUnderTheKeyTheCallerHands() async throws {
        let (uploader, _, relay) = relayedUploader(transport: FailingTransport())
        for _ in 0..<2 {
            _ = try? await uploader.upload(
                .data(Data([1, 2, 3])), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
                sizeBytes: 3, sha256: String(repeating: "c", count: 64), idempotencyKey: "bubble-7"
            )
        }
        let expected = "bubble-7:" + String(repeating: "c", count: 16)
        #expect(relay.ticketKeys == [expected, expected])
    }

    /// ⚠️ ONE INTENT, OTHER BYTES, OTHER WIRE KEY (#795). A clip re-exported
    /// on a retry has a new SHA-256; under the bare intent key the server
    /// would refuse it, or answer with the old bytes.
    @Test func changedBytesForTheSameIntentAskUnderAnotherKey() async throws {
        let (uploader, blobs, relay) = relayedUploader()
        for fill in [UInt8(1), 2] {
            let bytes = Data(repeating: fill, count: 64)
            _ = try await uploader.upload(
                .data(bytes), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
                sizeBytes: 64, sha256: String(repeating: fill == 1 ? "e" : "f", count: 64),
                idempotencyKey: "clip-3"
            )
        }
        #expect(Set(relay.ticketKeys).count == 2, "keys: \(relay.ticketKeys)")
        #expect(blobs.assetCount == 2, "the second content was answered with the first asset")
    }
}
