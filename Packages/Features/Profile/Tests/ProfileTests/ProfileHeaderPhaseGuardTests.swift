import Foundation
import Testing

/// ONE MAPPING FROM A PROFILE'S PHASE TO ITS HEADER (#1757):
/// `ProfileHeaderView.render(_:profileKnown:switching:animated:)`. The
/// profile and the profile card each wrote their own, and the copies drifted:
/// the card never drew its loading state and opened on the header's blank
/// default. A screen that redacts, reveals or hides a profile header by hand
/// is writing that mapping again.
struct ProfileHeaderPhaseGuardTests {
    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProfileTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Profile
            .appendingPathComponent("Sources/Profile")
    }

    static func drivesTheHeaderByHand(_ text: String) -> Bool {
        text.contains("headerView.setRedacted(") || text.contains("headerView.isHidden =")
    }

    @Test func noScreenMapsTheProfilesPhaseByHand() {
        var found: [String] = []
        let enumerator = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "ProfileHeaderView.swift" else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if Self.drivesTheHeaderByHand(text) { found.append(url.lastPathComponent) }
        }
        #expect(found.isEmpty, "render the header through ProfileHeaderView.render(_:...): \(found.sorted())")
    }

    @Test func thePatternFindsTheShape() {
        #expect(Self.drivesTheHeaderByHand("headerView.setRedacted(true)"))
        #expect(!Self.drivesTheHeaderByHand("headerView.render(phase, profileKnown: true, animated: true)"))
    }
}
