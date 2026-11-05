// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard's network log (#2133).
#if DEBUG
import Connect
import Foundation

/// Every BFF call, for the debug dashboard's network log (#2133): method,
/// start, duration, status, sizes, and the raw bodies (decoded only when one
/// is opened).
///
/// ⚠️ OFF BY DEFAULT, AND CHEAP WHEN ON. Off, the wrapping client
/// (`NetworkLogClient`) reads one flag per call and forwards. On, it copies
/// the call's metadata and bodies (capped) on the calling queue and hands
/// them to a background queue, into a ring of the last `capacity` calls.
/// Nothing runs on the main thread.
public final class NetworkLog: @unchecked Sendable {
    public static let shared = NetworkLog()

    public struct Call: Sendable, Identifiable {
        public let id: Int
        /// `/feed.v1.TimelineService/GetHomeFeed`.
        public let path: String
        public let started: Date
        public var duration: TimeInterval?
        public var code: Code?
        public var errorMessage: String?
        public let requestBytes: Int
        public var responseBytes: Int?
        public let requestBody: Data?
        public var responseBody: Data?

        /// `TimelineService`, from the path.
        public var service: String { path.split(separator: "/").first.map { String($0.split(separator: ".").last ?? $0) } ?? path }
        /// `GetHomeFeed`.
        public var method: String { path.split(separator: "/").last.map(String.init) ?? path }
        public var failed: Bool { code.map { $0 != .ok } ?? false }
    }

    public static let capacity = 500
    /// Bodies over this are cut: the log keeps a call's shape, not a feed's media.
    public static let bodyCap = 64 * 1024

    private let lock = NSLock()
    private var on = false
    private var calls: [Call] = []
    private var nextID = 0
    private let queue = DispatchQueue(label: "network-log", qos: .utility)

    public var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }

    /// The calls kept, oldest first.
    public var snapshot: [Call] { lock.withLock { calls } }

    public func clear() { lock.withLock { calls.removeAll() } }

    /// A call starts; its id, or nil while the log is off.
    func begin(path: String, body: Data?) -> Int? {
        lock.lock()
        guard on else {
            lock.unlock()
            return nil
        }
        nextID += 1
        let id = nextID
        lock.unlock()
        let started = Date()
        let capped = body.map { $0.prefix(Self.bodyCap) }
        queue.async { [self] in
            lock.withLock {
                calls.append(Call(id: id, path: path, started: started, duration: nil, code: nil, errorMessage: nil,
                                  requestBytes: body?.count ?? 0, responseBytes: nil, requestBody: capped,
                                  responseBody: nil))
                if calls.count > Self.capacity { calls.removeFirst(calls.count - Self.capacity) }
            }
        }
        return id
    }

    func end(_ id: Int, response: HTTPResponse) {
        let ended = Date()
        let body = response.message.map { $0.prefix(Self.bodyCap) }
        let bytes = response.message?.count ?? 0
        let message = response.error.map { "\($0)" }
        queue.async { [self] in
            lock.withLock {
                guard let index = calls.lastIndex(where: { $0.id == id }) else { return }
                calls[index].duration = ended.timeIntervalSince(calls[index].started)
                calls[index].code = response.code
                calls[index].errorMessage = message
                calls[index].responseBytes = bytes
                calls[index].responseBody = body
            }
        }
    }
}

/// The client every RPC goes through when the log may be wanted: forwards
/// to `inner`, and tells `NetworkLog` about unary calls while it is on.
/// Streams are forwarded untouched.
public struct NetworkLogClient: HTTPClientInterface {
    private let inner: any HTTPClientInterface
    private let log: NetworkLog

    public init(wrapping inner: any HTTPClientInterface, log: NetworkLog = .shared) {
        self.inner = inner
        self.log = log
    }

    @discardableResult
    public func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        guard let id = log.begin(path: request.url.path, body: request.message) else {
            return inner.unary(request: request, onMetrics: onMetrics, onResponse: onResponse)
        }
        let sink = log
        return inner.unary(request: request, onMetrics: onMetrics) { response in
            sink.end(id, response: response)
            onResponse(response)
        }
    }

    public func stream(request: HTTPRequest<Data?>, responseCallbacks: ResponseCallbacks) -> RequestCallbacks<Data> {
        inner.stream(request: request, responseCallbacks: responseCallbacks)
    }
}

/// A protobuf message's wire format, read without its schema: field numbers,
/// varints, fixed values, and length-delimited fields shown as text when they
/// read as text, as a nested message when they parse as one, as bytes
/// otherwise — enough to see what a call carried.
public enum ProtoWireDump {
    public static func dump(_ data: Data, depth: Int = 0, maxLines: Int = 400) -> String {
        var lines: [String] = []
        render(Array(data), depth: depth, into: &lines, maxLines: maxLines)
        return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
    }

    private static func render(_ bytes: [UInt8], depth: Int, into lines: inout [String], maxLines: Int) {
        var index = 0
        let pad = String(repeating: "  ", count: depth)
        while index < bytes.count, lines.count < maxLines {
            guard let key = varint(bytes, &index) else { return lines.append("\(pad)…unreadable") }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard let value = varint(bytes, &index) else { return }
                lines.append("\(pad)\(field): \(value)")
            case 1:
                guard index + 8 <= bytes.count else { return }
                let raw = bytes[index..<index + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                index += 8
                lines.append("\(pad)\(field): \(Double(bitPattern: raw)) (fixed64 \(raw))")
            case 2:
                guard let length = varint(bytes, &index), index + Int(length) <= bytes.count else { return }
                let chunk = Array(bytes[index..<index + Int(length)])
                index += Int(length)
                if let text = String(bytes: chunk, encoding: .utf8), !text.isEmpty,
                   text.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint && ($0.value >= 0x20 || $0 == "\n") }) {
                    lines.append("\(pad)\(field): \"\(text.prefix(200))\"")
                } else if parses(chunk) {
                    lines.append("\(pad)\(field) {")
                    render(chunk, depth: depth + 1, into: &lines, maxLines: maxLines)
                    lines.append("\(pad)}")
                } else {
                    lines.append("\(pad)\(field): <\(chunk.count) bytes>")
                }
            case 5:
                guard index + 4 <= bytes.count else { return }
                let raw = bytes[index..<index + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
                index += 4
                lines.append("\(pad)\(field): \(Float(bitPattern: raw)) (fixed32 \(raw))")
            default:
                return lines.append("\(pad)…unknown wire type")
            }
        }
    }

    /// Whether `bytes` reads as a whole message.
    private static func parses(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard let key = varint(bytes, &index), key >> 3 > 0 else { return false }
            switch key & 7 {
            case 0: guard varint(bytes, &index) != nil else { return false }
            case 1: index += 8
            case 2:
                guard let length = varint(bytes, &index) else { return false }
                index += Int(length)
            case 5: index += 4
            default: return false
            }
            if index > bytes.count { return false }
        }
        return true
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
#endif
