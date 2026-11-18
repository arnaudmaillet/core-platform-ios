// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2131).
#if DEBUG
import Foundation

/// The app's console — `print`, stdout and stderr — kept for the debug
/// dashboard's log viewer (#2132): most of the app logs with `print`, which
/// never reaches the unified log `OSLogStore` reads.
///
/// ⚠️ OFF THE MAIN THREAD, AND PASSED THROUGH. While on, stdout and stderr
/// write into pipes; a background read keeps the last lines in a capped ring
/// and writes every byte on to the original descriptors, so Xcode's console
/// shows exactly what it showed. A `print` costs a pipe write instead of a
/// terminal write; nothing runs on the main thread. Off, the descriptors are
/// put back.
public final class ConsoleCapture: @unchecked Sendable {
    public static let shared = ConsoleCapture()

    public struct Line: Sendable {
        public let date: Date
        public let isError: Bool
        public let text: String
    }

    private let lock = NSLock()
    private var lines: [Line] = []
    private var partial: [Int32: String] = [:]
    private var pipes: [(target: Int32, original: Int32, pipe: Pipe)] = []
    private static let capacity = 5000

    public var isOn: Bool { lock.withLock { !pipes.isEmpty } }

    /// The captured lines, oldest first.
    public var captured: [Line] { lock.withLock { lines } }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard pipes.isEmpty else { return }
        // Line-buffered: a pipe would otherwise make stdout fully buffered
        // and hold `print`s back.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        for target in [STDOUT_FILENO, STDERR_FILENO] {
            let original = dup(target)
            guard original >= 0 else { continue }
            let pipe = Pipe()
            dup2(pipe.fileHandleForWriting.fileDescriptor, target)
            let isError = target == STDERR_FILENO
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                // On to the original console first: Xcode shows it as before.
                data.withUnsafeBytes { bytes in
                    _ = write(original, bytes.baseAddress, bytes.count)
                }
                self?.append(String(decoding: data, as: UTF8.self), from: target, isError: isError)
            }
            pipes.append((target, original, pipe))
        }
    }

    public func stop() {
        lock.lock()
        let restoring = pipes
        pipes.removeAll()
        lock.unlock()
        fflush(stdout)
        for (target, original, pipe) in restoring {
            dup2(original, target)
            close(original)
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func append(_ chunk: String, from target: Int32, isError: Bool) {
        lock.withLock {
            let text = (partial[target] ?? "") + chunk
            var parts = text.components(separatedBy: "\n")
            partial[target] = parts.removeLast()
            let now = Date()
            lines.append(contentsOf: parts.filter { !$0.isEmpty }.map { Line(date: now, isError: isError, text: $0) })
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        }
    }
}
#endif
