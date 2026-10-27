import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1770): a screen shows its skeleton through the
/// kit's timing — `SkeletonGate` or `ScreenLoadingHost` — never at t = 0 and
/// for good. Nothing for 0.15 s, the bones held 0.3 s once up, and "Taking
/// longer than usual" with Try Again after 10 s.
///
/// The scan reads each feature and app source for a skeleton type it uses
/// but does not define (`PersonListSkeletonView`, `PersonSkeletonCell`,
/// `SkeletonRowConfiguration`, a screen's own `…SkeletonView`…) and fails a
/// file that never names the gate. A bare `SkeletonBoneView` is a building
/// block — a picture slot's, a redaction's — not a screen's skeleton.
///
/// CI only runs this in DesignSystem's lane: adding a skeleton to a screen,
/// run DesignSystem's tests too.
struct ScreenSkeletonGateGuardTests {
    /// Files whose skeleton is not a screen's load, and why.
    static let allowed: [String: String] = [
        "FriendsStoriesRow.swift": "an avatar's bone: a picture slot, on the media ladder's timing",
        "PinCardView.swift": "an avatar's bone: a picture slot, on the media ladder's timing",
        "RestingCommentsPlaceholderView.swift": "the comments' shape during a hero flight, not a load",
        "SettingsSkeletonRowCell.swift": "the row skeleton itself, worn by the screens",
    ]

    /// Screens still showing their bones at t = 0, moved onto the gate one by
    /// one (#1770). Shrinks; a file that no longer needs its entry fails the
    /// guard until the entry goes.
    static let pending: Set<String> = [
        "PostDetailViewController.swift",
        "MediaAlbumPageView.swift", "MediaPickerViewController.swift",
        // Settings: section rows redacted while their values load.
        "AccountStatusViewController.swift", "AccountTypeViewController.swift",
        "ActivityDiscoveryViewController.swift",
        "ConsentsViewController.swift",
        "DataExportViewController.swift", "DecisionDetailViewController.swift",
        "DeleteAccountViewController.swift", "FamilyAndTeensViewController.swift",
        "HiddenWordsViewController.swift",
        "LimitInteractionsViewController.swift", "ListPrivacyViewController.swift",
        "LocationSharingViewController.swift",
        "NotificationSettingsViewController.swift",
        "SecurityCheckupViewController.swift",
        "SecuritySettingsViewController.swift", "StorageSettingsViewController.swift",
        "SupervisionDetailViewController.swift", "TwoStepViewController.swift",
        "WhatYouSeeViewController.swift", "YourReportsViewController.swift",
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

    /// Whether `text` shows a skeleton it does not define without naming the
    /// gate — comments left out.
    static func showsBonesUngated(_ text: String) -> Bool {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard !code.contains("SkeletonGate"), !code.contains("ScreenLoadingHost") else { return false }
        let skeletonType = /\b(?:[A-Z]\w*)?Skeleton\w*(View|Cell|Configuration)\b/
        let declaration = /(class|struct|enum)\s+(\w*Skeleton\w*)/
        let defined = Set(code.matches(of: declaration).map { String($0.output.2) })
        return code.matches(of: skeletonType).contains { match in
            let name = String(match.output.0)
            return name != "SkeletonBoneView" && !defined.contains(name)
        }
    }

    @Test func everyScreenSkeletonIsGated() {
        var found: Set<String> = []
        var stillPending: Set<String> = []
        var scanned = 0
        for folder in ["App", "Packages/Features"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                scanned += 1
                let name = url.lastPathComponent
                guard Self.allowed[name] == nil else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard Self.showsBonesUngated(text) else { continue }
                if Self.pending.contains(name) { stillPending.insert(name) } else { found.insert(name) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        #expect(found.isEmpty, "show the skeleton through SkeletonGate or ScreenLoadingHost: \(found.sorted())")
        let done = Self.pending.subtracting(stillPending)
        #expect(done.isEmpty, "gated now — take them off the pending list: \(done.sorted())")
    }

    @Test func theScanFindsTheShape() {
        #expect(Self.showsBonesUngated("private let skeleton = PersonListSkeletonView()"))
        #expect(!Self.showsBonesUngated("""
            private let skeleton = PersonListSkeletonView()
            private lazy var gate = SkeletonGate(clock: skeletonClock)
            """))
        #expect(!Self.showsBonesUngated("final class InboxSkeletonView: UIView { }"), "a definition is no use")
        #expect(!Self.showsBonesUngated("// a PersonListSkeletonView here"))
        #expect(Self.showsBonesUngated("cell.contentConfiguration = SkeletonRowConfiguration(sample: \"A\")"))
        #expect(!Self.showsBonesUngated("let bone = SkeletonBoneView()"), "a bone is a building block")
    }
}
