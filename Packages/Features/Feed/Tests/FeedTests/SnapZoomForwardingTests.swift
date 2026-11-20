import Foundation
import Testing

/// ⚠️ THE SCREEN ANSWERS EVERY HERO REQUIREMENT ITSELF (#2387).
///
/// The hero's work lives in `SnapZoomDestination`, but the engine casts the
/// SCREEN (`as? any ZoomTransitionDestination`). Every requirement the screen
/// answers is therefore a one-line forward on `SnapFeedViewController`, and
/// a forward that goes missing does not fail to compile: the protocol
/// extension's default answers in its place, silently. A vertical grab that
/// claims every drag, a landing that never waits for a picture, a donated
/// surface nobody takes back — each is one deleted forward away.
///
/// A source scan, on both sides: the requirements are read off the
/// protocols' declarations, so a new requirement fails here until someone
/// decides whether the feed answers it.
struct SnapZoomForwardingTests {
    /// Requirements the screen answers on its own, not through the
    /// collaborator: a constant, and the flag whoever pushes the screen sets
    /// (`SnapFlightPhase`).
    static let answeredInPlace: Set<String> = ["concealsAppTabBar", "zoomOwnsInteractiveDismissal"]

    /// Requirements the screen leaves to the protocol's default. Empty: it
    /// answers every one. Adding a name here is a decision, not a fix.
    static let leftToDefault: Set<String> = []

    static var packages: URL {
        // …/Packages/Features/Feed/Tests/FeedTests/this file
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func lines(_ path: String) throws -> [String] {
        try String(contentsOf: packages.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
    }

    /// Each requirement of `protocol`, as its declaration (`func name(…) -> T`,
    /// `var name: T`), keyed by name.
    static func requirements(of protocolName: String, in path: String) throws -> [String: String] {
        let source = try Self.lines(path)
        guard let start = source.firstIndex(where: { $0.hasPrefix("public protocol \(protocolName)") }) else {
            Issue.record("no `public protocol \(protocolName)` in \(path)")
            return [:]
        }
        var found: [String: String] = [:]
        for line in source[(start + 1)...] {
            if line.hasPrefix("}") { break }
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("func ") || code.hasPrefix("var ") else { continue }
            let declaration = code.replacingOccurrences(of: #"\s*\{ get( set)? \}$"#, with: "", options: .regularExpression)
            let name = declaration
                .replacingOccurrences(of: #"^(func|var) "#, with: "", options: .regularExpression)
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            found[String(name)] = declaration
        }
        return found
    }

    static func allRequirements() throws -> [String: String] {
        var all = try requirements(
            of: "ZoomTransitionDestination", in: "Core/CoreNavigation/Sources/Transitions/ZoomTransition.swift"
        )
        try all.merge(
            requirements(of: "FlightDestination", in: "Core/CoreNavigation/Sources/CoreNavigation/FlightDestination.swift")
        ) { first, _ in first }
        return all
    }

    @Test func theProtocolsAreReadable() throws {
        let all = try Self.allRequirements()
        // A parse that finds nothing would pass every test below.
        #expect(all.count >= 20, "read \(all.count) requirements: \(all.keys.sorted())")
        #expect(all["zoomVerticalDismissalPermitted"] != nil)
        #expect(all["concealsAppTabBar"] != nil)
    }

    /// Every requirement is declared on the screen, `public`, with the
    /// protocol's own signature — a different label or type would be a new
    /// member, and the default would still answer.
    @Test func theScreenDeclaresEveryRequirement() throws {
        let screen = try Self.lines("Features/Feed/Sources/Feed/Snap/SnapFeedViewController.swift")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (name, declaration) in try Self.allRequirements() where !Self.leftToDefault.contains(name) {
            let expected = "public " + declaration
            #expect(screen.contains(where: { $0.hasPrefix(expected) }),
                    "`\(name)` is not declared on SnapFeedViewController as `\(expected)`: the protocol's default answers")
        }
    }

    /// …and every one not answered in place hands over to the collaborator.
    @Test func everyOtherRequirementForwards() throws {
        let screen = try Self.lines("Features/Feed/Sources/Feed/Snap/SnapFeedViewController.swift")
        for (name, declaration) in try Self.allRequirements()
        where !Self.answeredInPlace.contains(name) && !Self.leftToDefault.contains(name) {
            let expected = "public " + declaration
            guard let at = screen.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(expected) }) else {
                continue  // `theScreenDeclaresEveryRequirement` reports it
            }
            let body = screen[at..<min(at + 3, screen.count)].joined(separator: "\n")
            #expect(body.contains("zoomDestination.\(name)"),
                    "`\(name)` does not forward to `zoomDestination.\(name)`")
        }
    }
}
