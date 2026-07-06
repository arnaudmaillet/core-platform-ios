import Foundation

/// Transport abstraction every repository talks to. The URLSession-backed
/// implementation (auth interceptor, retry/backoff, request coalescing)
/// lands with the first feature; repositories and tests depend only on this.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
