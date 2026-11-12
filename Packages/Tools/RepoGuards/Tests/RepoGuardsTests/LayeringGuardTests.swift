import Foundation
import RepoGuards
import Testing

/// THE PACKAGE LAYERS (#2371, epic #2366), read from every `Package.swift`:
///
///     Kit ← Core ← FeatureInterfaces ← Features
///
/// - A package depends on its own layer or a lower one.
/// - A feature never depends on another feature, not even from its tests: it
///   reaches it through the other's interface.
/// - `Tools` (this package) sits outside the layers and depends on nothing.
///
/// The app (`App/`) is the composition root and may see everything.
///
/// ⚠️ A FAILURE HERE IS EITHER A NEW EDGE THAT BREAKS THE LAYERS — go through
/// an interface, or move the shared code down a layer — OR AN ALLOWED EDGE
/// THAT WENT AWAY: drop it from `allowed` in the same change, so the list
/// only shrinks.
struct LayeringGuardTests {
    /// The layers, lowest first, by folder under `Packages/`.
    static let layers = ["Kit", "Core", "FeatureInterfaces", "Features"]

    /// Today's exceptions, each with its issue. The list may only shrink.
    static let allowed: [String: String] = [
        // HeroPage reaches FeedInterface for `PostGridPage` alone (#2373).
        "Core/HeroPage -> FeatureInterfaces/FeedInterface": "#2373",
        // Profile's tests draw the profile on For You's real grid; the grid
        // moves to a Core package (#2379), then the edge goes (#2372).
        "Features/Profile -> Features/Feed": "#2372",
    ]

    /// Every local package dependency, as `Layer/Package -> Layer/Package`.
    static func edges() throws -> [(from: String, to: String)] {
        let packages = RepoRoot.url.appendingPathComponent("Packages")
        let declared = try Regex(#"\.package\(\s*path:\s*"([^"]+)""#)
        var found: [(String, String)] = []
        for layer in layers + ["Tools"] {
            let folder = packages.appendingPathComponent(layer)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
                let manifest = folder.appendingPathComponent(name).appendingPathComponent("Package.swift")
                guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
                for match in text.matches(of: declared) {
                    guard let path = match.output[1].substring.map(String.init) else { continue }
                    let target = folder.appendingPathComponent(name).appendingPathComponent(path).standardizedFileURL
                    let parts = target.pathComponents.suffix(2)
                    found.append(("\(layer)/\(name)", parts.joined(separator: "/")))
                }
            }
        }
        return found
    }

    /// Why `edge` breaks the layers, or nil when it keeps them.
    static func violation(from: String, to: String) -> String? {
        let fromLayer = String(from.split(separator: "/")[0])
        let toLayer = String(to.split(separator: "/")[0])
        if fromLayer == "Tools" { return "a tool depends on nothing" }
        guard let source = layers.firstIndex(of: fromLayer), let target = layers.firstIndex(of: toLayer) else {
            return "\(toLayer) is not a layer"
        }
        if target > source { return "\(fromLayer) may not depend on the higher \(toLayer)" }
        if fromLayer == "Features", toLayer == "Features" { return "a feature reaches another only through its interface" }
        return nil
    }

    @Test func everyPackageKeepsTheLayers() throws {
        var problems: [String] = []
        var seen: Set<String> = []
        for (from, to) in try Self.edges() {
            guard let why = Self.violation(from: from, to: to) else { continue }
            let key = "\(from) -> \(to)"
            seen.insert(key)
            if Self.allowed[key] == nil { problems.append("\(key): \(why)") }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        let stale = Set(Self.allowed.keys).subtracting(seen)
        #expect(stale.isEmpty, "these edges are gone — drop them from `allowed`: \(stale.sorted())")
    }

    /// The scan can't pass by reading nothing.
    @Test func theManifestsAreRead() throws {
        let edges = try Self.edges()
        #expect(edges.count > 50, "read \(edges.count) edges")
        #expect(edges.contains { $0.from == "Features/Feed" && $0.to == "FeatureInterfaces/FeedInterface" })
    }

    /// The rule itself.
    @Test func theRuleTellsTheEdgesApart() {
        #expect(Self.violation(from: "Features/Chat", to: "FeatureInterfaces/ChatInterface") == nil)
        #expect(Self.violation(from: "Core/PostGrid", to: "Core/DesignSystem") == nil)
        #expect(Self.violation(from: "Kit/CoreModels", to: "Kit/CoreContracts") == nil)
        #expect(Self.violation(from: "Features/Chat", to: "Features/Feed") != nil)
        #expect(Self.violation(from: "Core/HeroPage", to: "FeatureInterfaces/FeedInterface") != nil)
        #expect(Self.violation(from: "Kit/CoreModels", to: "Core/DesignSystem") != nil)
        #expect(Self.violation(from: "Tools/RepoGuards", to: "Kit/CoreModels") != nil)
    }
}
