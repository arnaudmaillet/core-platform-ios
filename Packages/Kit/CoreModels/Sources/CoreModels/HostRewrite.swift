import Foundation

/// Rewrites a URL host for reachability while preserving the original host in
/// the `Host` header — needed for presigned object-store URLs signed against a
/// host the client can't resolve (e.g. a Docker-internal `minio:9000` from a
/// local fleet). The presigned SigV4 signature covers the Host header, so the
/// original value must still be sent. Also used for reading back delivery URLs
/// hosted on the same internal host.
public struct HostRewrite: Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Returns (rewrittenURL, originalHostHeader) if `from` appears in the URL.
    public func apply(to url: URL) -> (url: URL, hostHeader: String?)? {
        guard let range = url.absoluteString.range(of: from) else { return nil }
        let hostHeader = url.host.map { $0 + (url.port.map { ":\($0)" } ?? "") }
        let rewritten = url.absoluteString.replacingCharacters(in: range, with: to)
        return (URL(string: rewritten) ?? url, hostHeader)
    }
}
