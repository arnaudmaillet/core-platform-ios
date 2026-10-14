import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1124), like `ScaledFontTests` for fonts: a screen's
/// hue comes from the brand palette (`Palette`, `PointsSymbol`, `GemSymbol`,
/// `Warning`), never from a raw literal or a system hue picked on the spot.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for a raw colour (`UIColor(red:`, `UIColor(hue:`) or a system hue the
/// palette replaces (blue, orange, cyan, indigo, teal, pink, purple). A file
/// may keep one only with a reason on the list below — user inks, flag
/// colours, debug art, a convention. `systemRed` (destructive, and the heart
/// until #1128), `systemGreen` (success) and `systemYellow` (warnings, via
/// `Warning`) are the system's status colours and are not scanned.
///
/// CI only runs this in DesignSystem's lane, which a change elsewhere does
/// not select: touching colours anywhere, run DesignSystem's tests too.
struct RawHueGuardTests {
    /// File name → why its raw hue stays.
    static let allowed: [String: String] = [
        // The palette itself.
        "Palette.swift": "the tokens: hex literals and the heart's system stops",
        // User content and measured inks — not the theme (#1124, out of scope).
        "MediaTextStyleBar.swift": "the user's text inks drawn on media",
        "FlagPalette.swift": "colours read from a country's flag",
        "ShareQRCardView.swift": "the QR card is pinned light: its fixed grouped grey",
        // Debug and simulator art.
        "AppButtonGalleryViewController.swift": "the DEBUG button gallery's sample gradient",
        "MapIconDebugHUD.swift": "a DEBUG HUD",
        "AppCoordinator.swift": "a DEBUG stand-in picture",
        "SimulatedCaptureSource.swift": "the simulator camera's synthetic frames",
        "DebugMediaLibrary.swift": "the DEBUG media library's synthetic pictures",
        "ImageFetching.swift": "the placeholder fetcher's synthetic pictures",
        "VideoSource.swift": "the synthetic video source's frames",
        // Conventions the palette keeps on purpose.
        "PersonListCell.swift": "the verified seal stays blue (the platform convention)",
        "RelationshipListCell.swift": "the verified seal stays blue (the platform convention)",
        "AccountTypeViewController.swift": "the verified seal stays blue (the platform convention)",
        "ProfileHeaderView.swift": "the verified seal stays blue (the platform convention)",
        // White labels the dark tangerine would fail (#1124 step 4).
        "MutedAccountsViewController.swift": "a swipe action's ground under its white label",
        "FollowRequestsViewController.swift": "a swipe action's ground under its white label",
        "BlockedAccountsViewController.swift": "a swipe action's ground under its white label",
        "RestrictedAccountsViewController.swift": "a swipe action's ground under its white label",
        "RecentlyDeletedViewController.swift": "a swipe action's ground under its white label",
        // Not the brand's meaning, and not decided yet.
        "MediaPickerViewController.swift": "an album's count badge: information, not an action",
        "WalletClaimViews.swift": "the streak's flame: fire, not a warning",
    ]

    static let patterns = [
        "UIColor(red:", "UIColor(hue:", ".systemBlue", ".systemOrange", ".systemCyan",
        ".systemIndigo", ".systemTeal", ".systemPink", ".systemPurple",
        // `.link` as a COLOUR is the system blue (#1168). `olor` catches
        // `color:`, `textColor =`, `foregroundColor:`, and leaves
        // `dataDetectorTypes = .link` — a type, not a colour — alone.
        "UIColor.link", "olor: .link", "olor = .link",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` picks a raw hue.
    static func picksARawHue(_ text: String) -> Bool {
        patterns.contains { text.contains($0) }
    }

    @Test func everyHueComesFromThePalette() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.picksARawHue(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(!found.isEmpty, "the scan found no source at all: \(Self.root.path)")
        let unexplained = found.subtracting(Self.allowed.keys)
        #expect(unexplained.isEmpty, "read the hue from Palette (or argue the case here): \(unexplained.sorted())")
        let stale = Set(Self.allowed.keys).subtracting(found)
        #expect(stale.isEmpty, "these no longer pick a raw hue — drop them from the list: \(stale.sorted())")
    }

    /// The scan cannot pass by matching nothing.
    @Test func thePatternFindsTheShape() {
        #expect(Self.picksARawHue("label.textColor = .systemBlue"))
        #expect(Self.picksARawHue("UIColor(red: 1, green: 0, blue: 0, alpha: 1)"))
        #expect(!Self.picksARawHue("label.textColor = Palette.tint"))
        #expect(Self.picksARawHue("TextEntityStyle(color: .link)"))
        #expect(Self.picksARawHue("label.textColor = .link"))
        #expect(Self.picksARawHue("[.foregroundColor: UIColor.link]"))
        #expect(!Self.picksARawHue("textView.dataDetectorTypes = .link"), "a detector type is not a colour")
    }
}
