import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import MediaCore
import Testing

/// The media.v1 upload dance the post composer and the Messages thread share
/// (#681), against the mock BFF.
struct MediaAssetUploaderTests {
    private struct Refused: Error {}

    private struct FailingTransport: MediaUploadTransport {
        func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String { throw Refused() }
    }

    private func uploader(transport: (any MediaUploadTransport)? = nil) -> (MediaAssetUploader, MockBlobStore) {
        let bff = MockBFF()
        let blobs = MockBlobStore()
        MockMediaService(store: blobs).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let uploader = MediaAssetUploader(
            mediaClient: Media_V1_MediaServiceClient(client: client),
            transport: transport ?? MockMediaUploadTransport(store: blobs),
            resolveMaxAttempts: 3, resolvePollSeconds: 0.01
        )
        return (uploader, blobs)
    }

    @Test func bytesGoUpAndComeBackAsADeliveryURL() async throws {
        let (uploader, _) = uploader()
        let bytes = Data(repeating: 7, count: 512)
        let asset = try await uploader.upload(
            .data(bytes), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
            sizeBytes: UInt64(bytes.count), sha256: String(repeating: "a", count: 64)
        )
        #expect(!asset.assetID.isEmpty)
        #expect(asset.url.absoluteString.contains(asset.assetID))
    }

    @Test func aFailedByteUploadSaysWhere() async throws {
        let (uploader, _) = uploader(transport: FailingTransport())
        await #expect {
            _ = try await uploader.upload(
                .data(Data([1, 2, 3])), ownerID: MockAuthService.accountID, mimeType: "image/jpeg",
                sizeBytes: 3, sha256: String(repeating: "b", count: 64)
            )
        } throws: { error in
            if case .upload = error as? MediaAssetUploader.UploadError { return true }
            return false
        }
    }
}
