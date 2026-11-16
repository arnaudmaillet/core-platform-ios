import Foundation

/// One launch argument, declared once next to the code that reads it (#2374).
///
/// A raw `ProcessInfo.processInfo.arguments.contains("-some-flag")` turns a
/// feature off without a word when the string has a typo, and nothing lists
/// the flags a package understands. A package declares its own instead:
///
///     extension LaunchArgument {
///         static let viewportShare = LaunchArgument("-viewport-share")
///     }
///
/// and reads it through `isPassed` or `value`. `LaunchArgumentReadGuardTests`
/// (RepoGuards) holds every package to a baseline of raw reads that may only
/// shrink.
public struct LaunchArgument: Sendable, Hashable, CustomStringConvertible {
    /// The argument as passed, `-viewport-share`.
    public let name: String

    public init(_ name: String) {
        precondition(name.hasPrefix("-"), "a launch argument starts with a dash: \(name)")
        self.name = name
    }

    public var description: String { name }

    /// Whether it was passed.
    public func isPassed(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(name)
    }

    /// The word passed after it (`-switch-tab 3` → `"3"`), or nil when it
    /// was not passed or nothing follows it.
    public func value(in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        value(at: 1, in: arguments)
    }

    /// The `position`-th word passed after it, from 1 (`value`):
    /// `-tile-card-close-demo 0.6 4` → `"4"` at 2. Nil when it was not
    /// passed or the words stop short: a flag's further values.
    public func value(at position: Int, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        precondition(position >= 1, "the first word after a flag is at 1")
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + position) else { return nil }
        return arguments[index + position]
    }

    /// `value`, read as an integer.
    public func intValue(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        value(in: arguments).flatMap { Int($0) }
    }

    /// `value`, read as a number.
    public func doubleValue(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Double? {
        value(in: arguments).flatMap { Double($0) }
    }
}
