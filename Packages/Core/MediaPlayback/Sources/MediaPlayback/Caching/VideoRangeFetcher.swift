import Foundation
import Synchronization

/// What a server said when a range fetch was answered.
struct VideoRangeResponse: Sendable, Equatable {
    /// The resource offset of the first body byte: the range's start for a
    /// `206`, zero for a `200` (a server that ignored the `Range` header).
    let offset: Int64
    /// The whole resource's length, when the server gave it.
    let totalLength: Int64?
    let mimeType: String?
}

/// Why a fetch ended without its whole range. Sendable, unlike the
/// `URLSession` error it is made from, so it crosses queues.
struct VideoRangeFetchFailure: Error, Sendable, Equatable {
    let reason: String

    init(_ error: any Error) {
        reason = String(describing: error)
    }
}

enum VideoRangeFetchError: Error, Equatable {
    /// Neither `200` nor `206`.
    case httpStatus(Int)
    /// The response gave no total length: nothing can be served by range.
    case unknownLength
    /// The body ended before the range it promised.
    case truncated
    /// The response is an HLS manifest, which a resource loader cannot serve
    /// (#895: HLS needs a local proxy).
    case notProgressive
}

/// The callbacks of one fetch, called in order (response, data..., finish)
/// on the fetcher's queue.
struct VideoRangeFetchEvents: Sendable {
    var response: @Sendable (VideoRangeResponse) -> Void
    var data: @Sendable (Data) -> Void
    /// `nil` when the body arrived in full. Not called after `cancel()`.
    var finish: @Sendable (VideoRangeFetchFailure?) -> Void
}

/// A fetch in flight.
protocol VideoRangeTask: AnyObject, Sendable {
    func cancel()
    /// A `URLSessionTask.priority`, changeable while it runs.
    func setPriority(_ priority: Float)
}

/// Fetches byte ranges of a progressive file. The URLSession one in the app;
/// a test serves from memory and records every range asked for.
protocol VideoRangeFetching: Sendable {
    /// Fetches `[offset, end)`, or from `offset` to the end of the resource
    /// when `end` is nil.
    ///
    /// - Parameter speculative: a P2 head preload: it stays off Low Data Mode
    ///   networks (`allowsConstrainedNetworkAccess = false`, WWDC19).
    func fetch(
        _ url: URL, from offset: Int64, to end: Int64?, speculative: Bool, priority: Float,
        events: VideoRangeFetchEvents
    ) -> any VideoRangeTask
}

/// Range fetches over `URLSession`, bypassing `URLCache`: the video cache IS
/// the cache, and a second copy of every range in `URLCache.shared` would
/// only double the flash writes.
final class URLSessionVideoRangeFetcher: NSObject, VideoRangeFetching, URLSessionDataDelegate, @unchecked Sendable {
    // `@unchecked`: the session is immutable after init and every mutable
    // byte lives behind `handlers`.

    private struct Handler {
        let events: VideoRangeFetchEvents
        var failure: (any Error)?
        var cancelled = false
    }

    private let handlers = Mutex<[Int: Handler]>([:])
    private let delegateQueue: OperationQueue
    private var session: URLSession!

    override init() {
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "MediaPlayback.VideoRangeFetcher"
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func fetch(
        _ url: URL, from offset: Int64, to end: Int64?, speculative: Bool, priority: Float,
        events: VideoRangeFetchEvents
    ) -> any VideoRangeTask {
        var request = URLRequest(url: url)
        request.setValue(Self.rangeHeader(from: offset, to: end), forHTTPHeaderField: "Range")
        request.networkServiceType = .avStreaming
        if speculative { request.allowsConstrainedNetworkAccess = false }
        let task = session.dataTask(with: request)
        task.priority = priority
        handlers.withLock { $0[task.taskIdentifier] = Handler(events: events) }
        let wrapped = SessionTask(task: task) { [weak self] identifier in
            self?.handlers.withLock { $0[identifier]?.cancelled = true }
        }
        task.resume()
        return wrapped
    }

    /// `bytes=a-b` (inclusive, as HTTP counts) or `bytes=a-`.
    static func rangeHeader(from offset: Int64, to end: Int64?) -> String {
        guard let end else { return "bytes=\(offset)-" }
        return "bytes=\(offset)-\(max(offset, end - 1))"
    }

    /// The offset and total of a `Content-Range: bytes a-b/total` header.
    static func parseContentRange(_ value: String?) -> (offset: Int64, total: Int64?)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard let range = parts.first, let dash = range.firstIndex(of: "-"),
              let offset = Int64(range[..<dash].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let total = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (offset, total)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let identifier = dataTask.taskIdentifier
        guard let handler = handlers.withLock({ $0[identifier] }), !handler.cancelled else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let mime = response.mimeType?.lowercased()
        var answer: VideoRangeResponse?
        var failure: (any Error)?
        if let mime, mime.contains("mpegurl") {
            failure = VideoRangeFetchError.notProgressive
        } else if status == 206, let range = Self.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range")) {
            answer = VideoRangeResponse(offset: range.offset, totalLength: range.total, mimeType: mime)
        } else if status == 200 {
            let length = response.expectedContentLength
            answer = VideoRangeResponse(offset: 0, totalLength: length > 0 ? length : nil, mimeType: mime)
        } else {
            failure = VideoRangeFetchError.httpStatus(status)
        }
        if let failure {
            handlers.withLock { $0[identifier]?.failure = failure }
            completionHandler(.cancel)
            return
        }
        if let answer { handler.events.response(answer) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let handler = handlers.withLock { $0[dataTask.taskIdentifier] }
        guard let handler, !handler.cancelled else { return }
        handler.events.data(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handler = handlers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }),
              !handler.cancelled else { return }
        handler.events.finish((handler.failure ?? error).map(VideoRangeFetchFailure.init))
    }

    private final class SessionTask: VideoRangeTask, @unchecked Sendable {
        // `@unchecked`: `URLSessionTask` is thread-safe; `onCancel` is immutable.
        private let task: URLSessionDataTask
        private let onCancel: @Sendable (Int) -> Void

        init(task: URLSessionDataTask, onCancel: @escaping @Sendable (Int) -> Void) {
            self.task = task
            self.onCancel = onCancel
        }

        func cancel() {
            onCancel(task.taskIdentifier)
            task.cancel()
        }

        func setPriority(_ priority: Float) {
            task.priority = priority
        }
    }
}
