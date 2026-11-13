import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2145): the profile CARD opens only from a person
/// beside content, through the shared contract (`PersonOpening`, MediaCore),
/// whose `openCard` the screen's view model answers with `.profileCard`.
/// Every file under `App/` and `Packages/` (tests excluded) that routes
/// `.profileCard` is named below with the reason; a new one fails here
/// until it is the contract's or says why it is not.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct PersonOpeningGuardTests {
    /// File name → why it routes `.profileCard`.
    static let allowed: [String: String] = [
        "AppRoute.swift": "the route itself, and its resolution (`profileCardResolution`)",
        "FeedViewModel.swift": "the post page's author pill: `PersonOpening.openCard` → `didTapAuthorPill`",
        "ConversationViewModel.swift": "the conversation's correspondent pill: `PersonOpening.openCard` → `didTapIdentityPill`",
        "AppCoordinator.swift": "the DEBUG `-open-profile-card` launch argument",
        "ProfileViewModel.swift": "a History row's author (#2170): `PersonOpening.openCard` → `galleryAuthorCardTapped`",
        "ForYouViewController.swift": "a list card's or a shelf text card's author band (#2300): `PersonOpening.openCard` → `openAuthorCard`",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Feed
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    @Test func onlyTheContractsHostsRouteTheCard() {
        var routing: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(".profileCard(") { routing.insert(url.lastPathComponent) }
            }
        }
        #expect(routing.isSuperset(of: ["FeedViewModel.swift", "ConversationViewModel.swift"]), "the guard reads no source")
        let unexplained = routing.subtracting(Self.allowed.keys).sorted()
        #expect(unexplained.isEmpty, "routes .profileCard outside the contract: \(unexplained)")
    }
}
