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
}

/// Production transport: a background-configured `URLSession` uploading from a
/// temp file so the transfer can proceed while the app is suspended. The ETag
/// is read from the storage response.
///
/// Cross-relaunch resumption (rehydrating tasks after the app is killed
/// mid-upload) is wired at the app layer via
/// `application(handleEventsForBackgroundURLSession:)`; this type covers the
/// in-session path.
public final class URLSessionMediaUploadTransport: NSObject, MediaUploadTransport, @unchecked Sendable {
    private let session: URLSession

    public init(identifier: String = "cn.wynn.core-platform-ios.upload") {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config)
        super.init()
    }

    public func upload(_ data: Data, using ticket: MediaUploadTicket) async throws -> String {
        guard data.count <= ticket.maxSizeBytes else {
            throw MediaUploadError.payloadTooLarge(limit: ticket.maxSizeBytes)
        }

        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = ticket.httpMethod
        for (field, value) in ticket.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (responseData, response) = try await session.upload(for: request, fromFile: tempURL)
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
