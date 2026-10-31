import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1970), like `StackCloseGuardTests`: the window sees
/// every presentation come and go, but not a sheet changing height while it
/// stays up. An app sheet that can — more than one detent, or a detent
/// selected after it is presented — declares whether it covers
/// (`ScreenCovering`), so a new sheet over clips is a conscious choice.
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for a `detents = [` list of more than one detent, or a
/// `selectedDetentIdentifier =`. Such a file adopts `ScreenCovering`, or
/// names on the list below where the declaration lives, or why none is
/// needed.
///
/// CI only runs this in CoreNavigation's lane, which a change elsewhere does
/// not select: adding a sheet anywhere, run CoreNavigation's tests too.
struct ScreenCoveringGuardTests {
    /// File name → where its sheet declares itself, or why it need not.
    static let allowed: [String: String] = [
        "ContentFittingNavigationController.swift":
            "one detent per stack, chosen before it presents (#1908): the default reads it",
        "UploadFeatureBuilder+Send.swift": "one detent, large, selected before it presents",
        "FeedFeatureBuilder.swift": "the text post composer's detents: TextPostComposerViewController declares",
        "MediaEditorOverlayMode.swift": "the sticker picker's detents: MediaStickerPickerViewController declares",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CoreNavigationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CoreNavigation
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` sets up a sheet that can change height once up.
    static func changesHeight(_ text: String) -> Bool {
        if text.contains("selectedDetentIdentifier =") { return true }
        var rest = Substring(text)
        while let start = rest.range(of: "detents = [") {
            if detentCount(rest[start.upperBound...]) > 1 { return true }
            rest = rest[start.upperBound...]
        }
        return false
    }

    /// The entries of the list opening at `list` (just past its `[`): its
    /// commas at the list's own depth, plus one.
    static func detentCount(_ list: Substring) -> Int {
        var depth = 0
        var count = 1
        for character in list {
            switch character {
            case "[", "(", "{": depth += 1
            case "]" where depth == 0: return count
            case "]", ")", "}": depth -= 1
            case "," where depth == 0: count += 1
            default: break
            }
        }
        return count
    }

    @Test func theGuardCountsDetentsAtTheListsOwnDepth() {
        #expect(!Self.changesHeight("sheet.detents = [.large()]"))
        #expect(Self.changesHeight("sheet.detents = [.medium(), .large()]"))
        #expect(!Self.changesHeight("sheet.detents = [.custom(identifier: id) { [weak self] context in min(a, b) }]"))
        #expect(Self.changesHeight("sheet.detents = [small, large]"))
        #expect(Self.changesHeight("sheet.selectedDetentIdentifier = .large"))
    }

    @Test func everySheetThatChangesHeightDeclaresWhetherItCovers() {
        var found: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      Self.changesHeight(text), !text.contains("ScreenCovering") else { continue }
                if Self.allowed[url.lastPathComponent] == nil { found.append(url.lastPathComponent) }
            }
        }
        #expect(found.isEmpty, "sheets that change height without declaring a cover (ScreenCovering): \(found)")
    }
}
