import Foundation
import Testing

/// THE BAR CONTRACT'S GUARD (#1679, `dev/BAR_CONTRACT.md`): no new screen
/// may build a bar item the old way. Scans the app and every package for the
/// shapes the contract retires, against a baseline of what is still to be
/// converted — a file may only go DOWN.
///
/// - A custom-view item (`UIBarButtonItem(customView:`) is made only by
///   `BarItems` (`stretched`, `container`): an icon is `BarItems.icon`, a
///   wide word `BarItems.stretched`, a complex container
///   `BarItems.container` — all with an identifier.
/// - `hidesSharedBackground = true` (a button drawing a glass of its own in
///   the bar) is the old wide pattern (R5).
/// - `SnapNavControls.make…` builds icon `UIButton`s for bars (R1).
/// - `morphNavigationBar(` cross-dissolves a bar by hand (R3).
///
/// ⚠️ A FAILURE HERE IS EITHER A NEW VIOLATION — build the item through
/// `BarItems` — OR A FILE THAT GOT BETTER: lower its count below (or remove
/// it) in the same change, so the baseline keeps shrinking to nothing.
struct BarContractGuardTests {
    /// Files still holding custom-view items made by hand, and how many.
    static let customViewDebt: [String: Int] = [
        "App/Shell/WalletBadgeInstaller.swift": 1,
        "App/Shell/WalletHistoryViewController.swift": 1,
        "App/Shell/WalletStakesViewController.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/NavigationBarToasts.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/SelectorToolbarItem.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ToastMessageSheet.swift": 1,
        "Packages/Features/Auth/Sources/Auth/LoginFlowCoordinator.swift": 1,
        "Packages/Features/Feed/Sources/Feed/ForYou/PushedScreenHeader.swift": 1,
        "Packages/Features/Feed/Sources/Feed/Snap/Sound/SoundSheetViewController.swift": 1,
        "Packages/Features/Maps/Sources/Maps/Countries/CountryShopViewController.swift": 1,
        "Packages/Features/Maps/Sources/Maps/Countries/CountryUnlockSheetViewController.swift": 1,
        "Packages/Features/Notifications/Sources/Notifications/Views/NotificationsViewController+Mute.swift": 1,
        "Packages/Features/Profile/Sources/Profile/Views/ProfileRelationshipsViewController.swift": 1,
        "Packages/Features/Profile/Sources/Profile/Views/ProfileViewController.swift": 1,
        "Packages/Features/Search/Sources/Search/Views/SearchResultsViewController.swift": 1,
        "Packages/Features/Upload/Sources/Upload/Capture/CaptureViewController.swift": 1,
        "Packages/Features/Upload/Sources/Upload/Views/MediaEditorViewController.swift": 1,
        "Packages/Features/Upload/Sources/Upload/Views/MediaPickerViewController.swift": 1,
    ]

    /// Files whose bar buttons still draw their own glass.
    static let ownGlassDebt: [String: Int] = [
        "App/Shell/WalletHistoryViewController.swift": 1,
        "App/Shell/WalletStakesViewController.swift": 1,
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/ToastMessageSheet.swift": 1,
        "Packages/Features/Feed/Sources/Feed/Snap/Sound/SoundSheetViewController.swift": 1,
        "Packages/Features/Maps/Sources/Maps/Countries/CountryUnlockSheetViewController.swift": 1,
        "Packages/Features/Notifications/Sources/Notifications/Views/NotificationsViewController+Mute.swift": 1,
    ]

    /// Files still building icon buttons for bars through `SnapNavControls`.
    static let iconButtonDebt: [String: Int] = [:]

    /// Files still cross-dissolving a bar by hand.
    static let barMorphDebt: [String: Int] = [
        "Packages/Core/DesignSystem/Sources/DesignSystem/Components/NavigationBarMorph.swift": 1,
        "Packages/Features/Chat/Sources/Chat/Inbox/MessagesInboxViewController.swift": 2,
        "Packages/Features/Profile/Sources/Profile/Views/ProfileRelationshipsViewController.swift": 2,
    ]

    /// Where custom-view items are MADE: the contract's own factory.
    static let factory = "Packages/Core/DesignSystem/Sources/DesignSystem/Components/BarItems.swift"

    @Test func noNewCustomViewBarItem() throws {
        try expectWithinDebt(#"UIBarButtonItem\(customView:"#, debt: Self.customViewDebt, exempt: [Self.factory])
    }

    @Test func noNewBarButtonDrawingItsOwnGlass() throws {
        try expectWithinDebt(#"hidesSharedBackground\s*=\s*true"#, debt: Self.ownGlassDebt)
    }

    @Test func noNewIconButtonForABar() throws {
        try expectWithinDebt(#"SnapNavControls\.make"#, debt: Self.iconButtonDebt)
    }

    @Test func noNewHandMadeBarMorph() throws {
        try expectWithinDebt(#"morphNavigationBar\("#, debt: Self.barMorphDebt)
    }

    // MARK: - The scan

    private func expectWithinDebt(_ pattern: String, debt: [String: Int], exempt: Set<String> = []) throws {
        let regex = try Regex(pattern)
        let found = try Self.counts(of: regex).filter { !exempt.contains($0.key) }
        var problems: [String] = []
        for (path, count) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = debt[path] ?? 0
            if count > allowed {
                problems.append("\(path): \(count) (allowed \(allowed)) — build the item through BarItems")
            } else if count < allowed {
                problems.append("\(path): \(count), baseline \(allowed) — lower the baseline")
            }
        }
        for (path, allowed) in debt where found[path] == nil {
            problems.append("\(path): 0, baseline \(allowed) — remove it from the baseline")
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every Swift source under `App/` and `Packages/` (tests left out), by
    /// repository-relative path, with how often `regex` occurs in it.
    private static func counts(of regex: Regex<AnyRegexOutput>) throws -> [String: Int] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .resolvingSymlinksInPath()
        var result: [String: Int] = [:]
        for folder in ["App", "Packages"] {
            let base = root.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = url.resolvingSymlinksInPath().path
                guard !path.contains("/Tests/"), !path.contains("/.build/") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let count = text.matches(of: regex).count
                guard count > 0 else { continue }
                guard path.hasPrefix(root.path + "/") else { continue }
                let relative = String(path.dropFirst(root.path.count + 1))
                result[relative] = count
            }
        }
        return result
    }
}
