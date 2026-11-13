import Foundation
import RepoGuards
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2374): a launch argument is read through a declared
/// `LaunchArgument` (Kit/LaunchArguments), not with a raw
/// `arguments.contains("-…")` or `arguments.firstIndex(of: "-…")`. A typo
/// in a raw string turns a feature off without a word, and nothing lists
/// the flags a package understands.
///
/// 626 raw reads were left when the guard came in. Each package keeps a
/// budget, and a budget may only shrink:
/// - **More reads than the budget fails.** Declare the argument next to
///   its code (`extension LaunchArgument { static let … }`) and read it
///   through `isPassed` or `value`.
/// - **Fewer reads passes.** Lower the budget in the same change if you
///   can, so the slack can't be spent again. Nothing fails if you don't:
///   a change that only removes code shouldn't go red.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct LaunchArgumentReadGuardTests {
    /// Raw reads each package may still hold, as `Layer/Package` (or `App`).
    /// A package that is not listed may hold none: CoreStorage, MediaCore,
    /// HeroPage, ShareSheet, VoiceKit, Auth and Notifications declare
    /// theirs (#2374, 2).
    static let budget: [String: Int] = [
        "App": 84,
        "Core/CoreNavigation": 48,
        "Core/CoreNetworking": 25,
        "Core/DebugTools": 22,
        "Core/DesignSystem": 16,
        "Core/MediaPlayback": 15,
        "Core/PostGrid": 12,
        "Features/Chat": 13,
        "Features/Feed": 202,
        "Features/Maps": 74,
        "Features/Profile": 39,
        "Features/Search": 16,
        "Features/Upload": 27,
    ]

    /// How many raw reads `text` holds.
    static func rawReads(in text: String) -> Int {
        text.matches(of: /arguments\.contains\("-|arguments\.firstIndex\(of: "-/).count
    }

    /// Raw reads per package, tests and the registry itself excluded.
    static func counts() -> [String: Int] {
        let root = RepoRoot.url
        var found: [String: Int] = [:]
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      !path.contains("/Packages/Kit/LaunchArguments/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let reads = rawReads(in: text)
                guard reads > 0 else { continue }
                found[owner(of: path, rootName: root.lastPathComponent), default: 0] += reads
            }
        }
        return found
    }

    /// `App`, or the `Layer/Package` a path under `Packages/` belongs to.
    /// Cut at the LAST `/<repository folder>/`, not at the root's full path:
    /// the enumerator and `RepoRoot` don't spell `/tmp` (`/private/tmp`) the
    /// same way, and on CI the folder's name appears twice
    /// (`_work/core-platform-ios/core-platform-ios/`).
    static func owner(of path: String, rootName: String) -> String {
        guard let cut = path.range(of: "/\(rootName)/", options: .backwards) else { return "App" }
        let relative = path[cut.upperBound...].split(separator: "/")
        guard relative.first == "Packages", relative.count > 2 else { return "App" }
        return "\(relative[1])/\(relative[2])"
    }

    @Test func noPackageReadsMoreRawArgumentsThanItsBudget() {
        let counts = Self.counts()
        var over: [String] = []
        for (package, count) in counts.sorted(by: { $0.key < $1.key }) {
            let allowed = Self.budget[package] ?? 0
            if count > allowed { over.append("\(package): \(count) raw reads, budget \(allowed)") }
        }
        #expect(over.isEmpty, "read these through a declared LaunchArgument (Kit/LaunchArguments): \(over)")
    }

    @Test func thePatternSeesBothForms() {
        #expect(Self.rawReads(in: #"ProcessInfo.processInfo.arguments.contains("-flag")"#) == 1)
        #expect(Self.rawReads(in: #"let i = arguments.firstIndex(of: "-switch-tab")"#) == 1)
        #expect(Self.rawReads(in: #"LaunchArgument("-flag").isPassed()"#) == 0)
        #expect(Self.rawReads(in: #"arguments.contains(name)"#) == 0)
    }

    @Test func aReadIsChargedToItsPackage() {
        #expect(Self.owner(of: "/x/repo/Packages/Features/Feed/Sources/Feed/A.swift", rootName: "repo") == "Features/Feed")
        #expect(Self.owner(of: "/private/x/repo/App/Shell/B.swift", rootName: "repo") == "App")
        #expect(Self.owner(of: "/w/repo/repo/Packages/Core/PostGrid/Sources/C.swift", rootName: "repo") == "Core/PostGrid")
    }
}
