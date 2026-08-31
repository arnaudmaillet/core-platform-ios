import Foundation
import Testing
@testable import MediaCore

/// Routing is verified against stubs, never the network: the point of the type
/// is which fetcher gets called, and a real request would make this flaky.
struct SchemeRoutingImageFetcherTests {
    private actor Spy: ImageFetching {
        private(set) var urls: [URL] = []
        let payload: Data

        init(payload: Data) { self.payload = payload }

        func fetchImageData(for url: URL) async throws -> Data {
            urls.append(url)
            return payload
        }

        var callCount: Int { urls.count }
    }

    private func makeFetcher() -> (SchemeRoutingImageFetcher, remote: Spy, placeholder: Spy) {
        let remote = Spy(payload: Data("remote".utf8))
        let placeholder = Spy(payload: Data("placeholder".utf8))
        return (SchemeRoutingImageFetcher(remote: remote, placeholder: placeholder), remote, placeholder)
    }

    @Test func httpsGoesToTheRemoteFetcher() async throws {
        let (fetcher, remote, placeholder) = makeFetcher()
        let data = try await fetcher.fetchImageData(for: URL(string: "https://picsum.photos/id/1/10/10")!)
        #expect(data == Data("remote".utf8))
        #expect(await remote.callCount == 1)
        #expect(await placeholder.callCount == 0)
    }

    @Test func httpGoesToTheRemoteFetcher() async throws {
        let (fetcher, remote, _) = makeFetcher()
        _ = try await fetcher.fetchImageData(for: URL(string: "http://example.com/a.jpg")!)
        #expect(await remote.callCount == 1)
    }

    /// The synthetic seeds must keep rendering offline even when the container
    /// is wired for the mixed catalog.
    @Test func mockSchemeGoesToThePlaceholderFetcher() async throws {
        let (fetcher, remote, placeholder) = makeFetcher()
        let data = try await fetcher.fetchImageData(for: URL(string: "mock://media/3?w=10&h=10")!)
        #expect(data == Data("placeholder".utf8))
        #expect(await placeholder.callCount == 1)
        #expect(await remote.callCount == 0)
    }

    @Test func schemeMatchIsCaseInsensitive() async throws {
        let (fetcher, remote, _) = makeFetcher()
        _ = try await fetcher.fetchImageData(for: URL(string: "HTTPS://example.com/a.jpg")!)
        #expect(await remote.callCount == 1)
    }

    /// A `file://` URL is not remote; it must not be sent to URLSession.
    @Test func fileURLsGoToThePlaceholderFetcher() async throws {
        let (fetcher, remote, placeholder) = makeFetcher()
        _ = try await fetcher.fetchImageData(for: URL(fileURLWithPath: "/tmp/a.jpg"))
        #expect(await placeholder.callCount == 1)
        #expect(await remote.callCount == 0)
    }

    private actor FailingSpy: ImageFetching {
        private(set) var callCount = 0
        func fetchImageData(for url: URL) async throws -> Data {
            callCount += 1
            throw URLError(.timedOut)
        }
    }

    /// ⚠️ A dead fixture host degrades to the placeholder, never to a blank.
    ///
    /// Found live: picsum's edge completed TLS and then hung, and every photo
    /// of the `-rich-media` catalog — plus every clip's poster — became a
    /// 60-second wait ending in nothing, which reads as "media doesn't load".
    /// The rule is the video fixtures' own: a test-fixture convenience must
    /// never be the reason nothing shows.
    @Test func aDeadRemoteFallsBackToThePlaceholder() async throws {
        let remote = FailingSpy()
        let placeholder = Spy(payload: Data("placeholder".utf8))
        let fetcher = SchemeRoutingImageFetcher(remote: remote, placeholder: placeholder)

        let data = try await fetcher.fetchImageData(
            for: URL(string: "https://picsum.photos/id/1/10/10")!
        )

        #expect(data == Data("placeholder".utf8))
        #expect(await remote.callCount == 1, "the real asset was never even tried")
        #expect(await placeholder.callCount == 1)
    }

    /// The fallback is for REMOTE failures only: a placeholder that throws for
    /// a `mock://` URL is a genuine defect and must stay visible as one.
    @Test func aFailingPlaceholderIsNotRescued() async {
        let remote = Spy(payload: Data("remote".utf8))
        let placeholder = FailingSpy()
        let fetcher = SchemeRoutingImageFetcher(remote: remote, placeholder: placeholder)

        await #expect(throws: URLError.self) {
            _ = try await fetcher.fetchImageData(for: URL(string: "mock://media/3")!)
        }
        #expect(await placeholder.callCount == 1)
        #expect(await remote.callCount == 0, "a mock URL must never reach the network")
    }
}
