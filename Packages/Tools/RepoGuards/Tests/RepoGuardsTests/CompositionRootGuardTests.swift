import Foundation
import RepoGuards
import Testing

/// THE APP IMPORTS FEATURE INTERFACES ONLY, OUTSIDE ITS COMPOSITION ROOT
/// (#2375, epic #2366).
///
/// `App/Composition/` is the composition root: `AppContainer` and its
/// per-domain files, and the adapters that join one feature's contract to
/// another's. It is the one place in the app that names a feature's
/// implementation (`Packages/Features/*`), because it chooses and builds
/// them. Every other App file — the coordinators, the shell, the delegates —
/// reaches a feature through its interface package (`FeedInterface`,
/// `UploadInterface`…), so a feature's internals change without the shell
/// noticing, and no shell file builds a concrete feature type by hand.
///
/// ⚠️ A FAILURE HERE: put the API the file needs in the feature's interface,
/// or, when the code picks a concrete type or joins two features, move it
/// into `App/Composition/`.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct CompositionRootGuardTests {
    /// The composition root, under `App/`.
    static let compositionRoot = "Composition/"

    /// The feature implementations' modules: every package under
    /// `Packages/Features`, and every module its `Sources` holds.
    static func featureModules() throws -> Set<String> {
        let features = RepoRoot.url.appendingPathComponent("Packages/Features")
        var modules: Set<String> = []
        for package in try FileManager.default.contentsOfDirectory(atPath: features.path) {
            let manifest = features.appendingPathComponent(package).appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            modules.insert(package)
            let sources = features.appendingPathComponent(package).appendingPathComponent("Sources")
            for module in (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? [] {
                modules.insert(module)
            }
        }
        return modules
    }

    /// The modules `text` imports, with their lines — inside `#if` blocks
    /// too, and whatever attribute, access level or kind the import carries.
    static func imports(in text: String) -> [(line: Int, module: String)] {
        let pattern = /^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|typealias|func|let|var)\s+)?(\w+)/
        var found: [(Int, String)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let match = line.firstMatch(of: pattern) {
                found.append((index + 1, String(match.output.1)))
            }
        }
        return found
    }

    /// Every App source, as a path under `App/`.
    static func appFiles() throws -> [String] {
        let app = RepoRoot.url.appendingPathComponent("App")
        guard let enumerator = FileManager.default.enumerator(atPath: app.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: app.path])
        }
        return enumerator
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    @Test func appFilesOutsideTheCompositionRootImportNoFeature() throws {
        let features = try Self.featureModules()
        let app = RepoRoot.url.appendingPathComponent("App")
        var problems: [String] = []
        for file in try Self.appFiles() where !file.hasPrefix(Self.compositionRoot) {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for (line, module) in Self.imports(in: text) where features.contains(module) {
                problems.append("App/\(file):\(line) imports the feature \(module)")
            }
        }
        #expect(problems.isEmpty, "import its interface, or move the code into App/\(Self.compositionRoot):\n\(problems.joined(separator: "\n"))")
    }

    /// The scan can't pass by reading nothing.
    @Test func theScanReadsTheFeaturesAndTheApp() throws {
        let features = try Self.featureModules()
        #expect(features.isSuperset(of: ["Feed", "Upload", "Auth", "Wallet"]), "read \(features.sorted())")
        #expect(!features.contains { $0.hasSuffix("Interface") })
        let files = try Self.appFiles()
        #expect(files.filter { !$0.hasPrefix(Self.compositionRoot) }.count > 20, "read \(files.count) App files")
        // The root itself does name features: the folder is the right one.
        let container = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("App/\(Self.compositionRoot)AppContainer.swift"), encoding: .utf8
        )
        #expect(Self.imports(in: container).contains { features.contains($0.module) })
    }

    /// The import pattern.
    @Test func thePatternSeesEveryImport() {
        let text = """
        import UIKit
        #if DEBUG
        import Feed
        #endif
        @testable import Chat
        public import Maps
        import struct Upload.PostComposer
        // import Wallet
        let importance = 1
        """
        #expect(Self.imports(in: text).map(\.module) == ["UIKit", "Feed", "Chat", "Maps", "Upload"])
        #expect(Self.imports(in: text).map(\.line) == [1, 3, 5, 6, 7])
    }
}
