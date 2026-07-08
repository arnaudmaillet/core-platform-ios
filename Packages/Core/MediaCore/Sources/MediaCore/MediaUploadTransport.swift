import Foundation

/// The bytes-to-storage half of the upload flow, isolated from the RPC layer:
/// takes a media.v1 `UploadTicket` (opaque URL + method + required headers)
/// and PUTs/POSTs the payload, returning the storage ETag that CommitUpload
/// needs.
public struct MediaUploadTicket: Sendable, Equatable {
    public let uploadURL: URL
    public let httpMethod: String
    public let requiredHeaders: [String: String]
    public let maxSizeBytes: UInt64

    public init(uploadURL: URL, httpMethod: String, requiredHeaders: [String: String], maxSizeBytes: UInt64) {
        self.uploadURL = uploadURL
        self.httpMethod = httpMethod
        self.requiredHeaders = requiredHeaders
        self.maxSizeBytes = maxSizeBytes
    }
}

public enum MediaUploadError: Error, Equatable {
    case payloadTooLarge(limit: UInt64)
    case badStatus(Int)
    case missingETag
    case transport(String)
}

public protocol MediaUploadTransport: Sendable {
    func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String
    /// Uploads the contents of a file. Video payloads are tens-to-hundreds of MB,
    /// so this streams from disk rather than buffering the whole clip in memory.
    func upload(fileURL: URL, using ticket: MediaUploadTicket) async throws -> String
}

public extension MediaUploadTransport {
    /// Default: read the file and reuse the in-memory path. Real transports
    /// override this to stream from disk (see `URLSessionMediaUploadTransport`).
    func upload(fileURL: URL, using ticket: MediaUploadTicket) async throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MediaUploadError.transport("could not read \(fileURL.lastPathComponent): \(error)")
        }
        return try await upload(data, using: ticket)
    }
}

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
    func apply(to url: URL) -> (url: URL, hostHeader: String?)? {
        guard let range = url.absoluteString.range(of: from) else { return nil }
        let hostHeader = url.host.map { $0 + (url.port.map { ":\($0)" } ?? "") }
        let rewritten = url.absoluteString.replacingCharacters(in: range, with: to)
        return (URL(string: rewritten) ?? url, hostHeader)
    }
}

/// Production transport: a `URLSession` uploading the payload to the ticket's
/// (typically presigned) URL. The ETag is read from the storage response.
public final class URLSessionMediaUploadTransport: NSObject, MediaUploadTransport, @unchecked Sendable {
    private let session: URLSession
    private let hostRewrite: HostRewrite?

    public init(hostRewrite: HostRewrite? = nil, session: URLSession = .shared) {
        self.session = session
        self.hostRewrite = hostRewrite
        super.init()
    }

    public func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String {
        guard data.count <= ticket.maxSizeBytes else {
            throw MediaUploadError.payloadTooLarge(limit: ticket.maxSizeBytes)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await send(fileURL: tempURL, using: ticket)
    }

    /// Streams the file straight to storage — no in-memory buffering — for
    /// large payloads (video).
    public func upload(fileURL: URL, using ticket: MediaUploadTicket) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? nil
        if let size, size > ticket.maxSizeBytes {
            throw MediaUploadError.payloadTooLarge(limit: ticket.maxSizeBytes)
        }
        return try await send(fileURL: fileURL, using: ticket)
    }

    private func send(fileURL: URL, using ticket: MediaUploadTicket) async throws -> String {
        var uploadURL = ticket.uploadURL
        var hostHeader: String?
        if let rewrite = hostRewrite?.apply(to: uploadURL) {
            uploadURL = rewrite.url
            hostHeader = rewrite.hostHeader
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = ticket.httpMethod
        if let hostHeader {
            request.setValue(hostHeader, forHTTPHeaderField: "Host")
        }
        for (field, value) in ticket.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw MediaUploadError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaUploadError.badStatus(http.statusCode)
        }
        // Object stores return the ETag in the response header; fall back to a
        // body-provided value for stores that echo it there.
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            return etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let bodyETag = String(data: responseData, encoding: .utf8), !bodyETag.isEmpty {
            return bodyETag
        }
        throw MediaUploadError.missingETag
    }
}
