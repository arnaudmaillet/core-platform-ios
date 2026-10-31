import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1144): every pushed screen states how it is left —
/// it is a `StackScreen` (DesignSystem), or it inherits from one.
///
/// Whether a class is ever PUSHED cannot be read from its source: push sites
/// take values built elsewhere, and several classes are both a child page and
/// a pushed screen. So every view controller class under `App/` and
/// `Packages/` (tests excluded) declares its contract, or is named below with
/// the reason it is never pushed. A new screen fails here until it says one
/// or the other, and the failure lists it.
///
/// CI only runs this in CoreNavigation's lane, which a change elsewhere does
/// not select: adding a screen anywhere, run CoreNavigation's tests too.
struct StackScreenGuardTests {
    /// Class name → why it is never pushed.
    static let neverPushed: [String: String] = [
        // A tab's or the drawer's root.
        "MapsViewController": "Explore's root",
        "ForYouSectorViewController": "For You's root",
        "MessagesInboxViewController": "Messages' root",
        "GuestSignInViewController": "Messages' root for a guest",
        "NotificationsViewController": "the drawer's root",
        // A child page or a container, never on a stack of its own.
        "ForYouViewController": "a page of For You's sector",
        "ConversationListViewController": "a page of the inbox",
        "SuggestionsViewController": "a page of the inbox",
        "InboxSearchResultsViewController": "the inbox search's results controller",
        "SearchPeoplePage": "a page of search results",
        "SearchPendingSurfaceViewController": "a page of search results",
        "PostSetSurfaceViewController": "a page of search results and hashtags",
        "ProfileRelationshipListViewController": "a page of the relationship lists",
        "PostDetailViewController": "the feed's side panel",
        "SideDrawerContainerViewController": "the drawer's container",
        "LensLabPage": "a page of the DEBUG lens bench",
        // A sheet's or a modal's root: left by its own close or swipe-down.
        "WalletSheetViewController": "a sheet",
        "ToastMessageSheet": "a sheet",
        "CountryUnlockSheetViewController": "a sheet",
        "ProfileCardViewController": "a sheet",
        "SoundSheetViewController": "a sheet",
        "MapSubFilterSheetViewController": "a sheet",
        "SearchFilterSheetViewController": "a sheet",
        "AppealComposerViewController": "a sheet",
        "TextPostComposerViewController": "a sheet",
        "OverSheetFeedHost": "a sheet",
        "ShareSheetViewController": "a sheet",
        "ThreadPhotoViewerController": "a full-screen viewer",
        "MediaStickerPickerViewController": "a sheet",
        "ForYouPostPreviewViewController": "a context menu's preview",
        "AppLockViewController": "a full-screen cover",
        "ScreenTimeReminderViewController": "a sheet",
        "LaunchViewController": "the window's launch root",
        "SignInSheetContainer": "a sheet",
        "CaptureViewController": "the camera's root",
        "HapticCatalogViewController": "a DEBUG sheet",
        "AppButtonCatalogViewController": "a DEBUG sheet",
        "ToastOverlayRootController": "the toast window's root",
        // Neither.
        "HeroPageViewController": "a base class: its subclasses state theirs",
        "PendingScreenViewController": "shown nowhere",
    ]

    /// A view controller class declaration: its name, then its superclass.
    static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+\s+)*(?:(?:public|open|final|internal|fileprivate|private)\s+)*class\s+(\w+)\s*(?:<[^>]*>)?\s*:\s*([\w.]+)"#,
        options: .anchorsMatchLines
    )

    /// Whether a superclass makes the class a view controller (navigation
    /// controllers excluded: they hold screens).
    static func isScreen(superclass: String) -> Bool {
        superclass.hasSuffix("ViewController") && !superclass.hasSuffix("NavigationController")
    }

    /// Classes in `text`, by name → superclass, screens only.
    static func screens(in text: String) -> [String: String] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [String: String] = [:]
        for match in declaration.matches(in: text, range: range) {
            guard let name = Range(match.range(at: 1), in: text), let parent = Range(match.range(at: 2), in: text)
            else { continue }
            let superclass = String(text[parent])
            if isScreen(superclass: superclass) { found[String(text[name])] = superclass }
        }
        return found
    }

    /// Whether `text` makes `name` a `StackScreen`, in its declaration or an
    /// extension.
    static func declaresContract(_ name: String, in text: String) -> Bool {
        let pattern = #"(?:extension|class)\s+"# + name + #"\b[^{]*:\s*[^{]*\bStackScreen\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CoreNavigationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CoreNavigation
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Every source file's text, tests excluded.
    private static func sources() -> String {
        var texts: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                texts.append(text)
            }
        }
        return texts.joined(separator: "\n")
    }

    @Test func theGuardReadsDeclarationsAndContracts() {
        let text = """
        final class AScreen: UIViewController {}
        public final class AStep<Tab: Equatable>: AuthStepTableViewController {}
        final class AStack: UINavigationController {}
        extension AScreen: StackScreen {
        """
        #expect(Self.screens(in: text) == ["AScreen": "UIViewController", "AStep": "AuthStepTableViewController"])
        #expect(Self.declaresContract("AScreen", in: text))
        #expect(!Self.declaresContract("AStep", in: text))
        #expect(Self.declaresContract("B", in: "final class B: UIViewController, StackScreen {"))
    }

    @Test func everyScreenStatesHowItIsLeft() {
        let text = Self.sources()
        let screens = Self.screens(in: text)
        #expect(screens.count > 100, "found \(screens.count) screens: the scan is broken")
        var memo: [String: Bool] = [:]
        func states(_ name: String) -> Bool {
            if let known = memo[name] { return known }
            memo[name] = false
            let answer = Self.declaresContract(name, in: text) || screens[name].map(states) == true
            memo[name] = answer
            return answer
        }
        let missing = screens.keys.filter { !states($0) && Self.neverPushed[$0] == nil }.sorted()
        #expect(missing.isEmpty, "screens with no contract — declare `StackScreen` (how they are left) or name them in `neverPushed` with the reason: \(missing)")
        let stale = Self.neverPushed.keys.filter { screens[$0] == nil || states($0) }.sorted()
        #expect(stale.isEmpty, "`neverPushed` names classes that are gone or state a contract: \(stale)")
    }
}
