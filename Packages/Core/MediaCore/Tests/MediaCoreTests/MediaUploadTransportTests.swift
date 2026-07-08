import Foundation
import Testing
@testable import MediaCore

/// Records the bytes handed to the in-memory path so we can assert the
/// file-based default forwards the file's contents unchanged.
private final class RecordingTransport: MediaUploadTransport, @unchecked Sendable {
    private(set) var received: Data?
    func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String {
        received = data
        return "etag-\(data.count)"
    }
    // Deliberately does NOT override upload(fileURL:) — exercises the default.
}

struct MediaUploadTransportTests {
    private func ticket() -> MediaUploadTicket {
        MediaUploadTicket(
            uploadURL: URL(string: "mock://upload/x")!,
            httpMethod: "PUT",
            requiredHeaders: [:],
            maxSizeBytes: 10_000_000
        )
    }

    @Test func fileBasedDefaultForwardsFileContents() async throws {
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID()).bin")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transport = RecordingTransport()
        let etag = try await transport.upload(fileURL: fileURL, using: ticket())

        #expect(transport.received == payload)
        #expect(etag == "etag-2048")
    }

    @Test func missingFileThrowsTransportError() async {
        let transport = RecordingTransport()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).bin")
        await #expect(throws: MediaUploadError.self) {
            _ = try await transport.upload(fileURL: missing, using: ticket())
        }
    }
}
