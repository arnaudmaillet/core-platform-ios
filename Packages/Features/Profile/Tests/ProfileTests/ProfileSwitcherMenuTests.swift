import CoreModels
import Foundation
import MediaCore
import ProfileInterface
import Testing
import UIKit
@testable import Profile

/// The account's three profiles, the second active.
private struct ActiveSecond: ProfileSwitching {
    func accountProfiles() async throws -> [AccountProfile] {
        ["prof-a", "prof-b", "prof-c"].map {
            AccountProfile(id: ProfileID($0), handle: $0, displayName: $0.uppercased(), avatarURL: nil)
        }
    }
    func activeProfileID() async -> ProfileID? { ProfileID("prof-b") }
    func setActiveProfile(_ id: ProfileID) async {}
}

/// THE ONE SWITCHER (#2034): one order, one look, each row's count.
@MainActor
struct ProfileSwitcherMenuTests {
    private func factory(_ counts: [String: Int?] = [:]) async -> ProfileSwitcherMenuFactory {
        let factory = ProfileSwitcherMenuFactory(
            switching: ActiveSecond(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            unreadCount: { id in counts[id.rawValue] ?? nil }
        )
        await factory.reload()
        return factory
    }

    /// The other profiles, then the active one and "Add Profile" — the one
    /// order, whatever the source.
    @Test func theOrderIsFixed() async {
        let sections = await factory().sections(includesAddProfile: true)
        #expect(sections.map { $0.map(\.title) } == [["PROF-A", "PROF-C"], ["PROF-B", "Add Profile"]])
        #expect(sections[1].first?.kind == .profile(ProfileID("prof-b"), isActive: true))
        #expect(sections[1].last?.kind == .addProfile)
    }

    /// A switch-only surface has no "Add Profile".
    @Test func switchOnlyDropsAddProfile() async {
        let sections = await factory().sections(includesAddProfile: false)
        #expect(!sections.joined().contains { $0.kind == .addProfile })
    }

    /// Each row carries its profile's count, the active one's too; "99+"
    /// past 99, no badge at zero or unknown.
    @Test func eachRowCarriesItsCount() async {
        let sections = await factory(["prof-a": 3, "prof-b": 128, "prof-c": 0]).sections(includesAddProfile: true)
        let counts = Dictionary(uniqueKeysWithValues: sections.joined().map { ($0.title, $0.count) })
        #expect(counts["PROF-A"] == 3)
        #expect(counts["PROF-B"] == 128)
        #expect(counts["PROF-C"] == 0)
        #expect(ProfileSwitcherCountBadge.text(for: 3) == "3")
        #expect(ProfileSwitcherCountBadge.text(for: 99) == "99")
        #expect(ProfileSwitcherCountBadge.text(for: 100) == "99+")
        #expect(ProfileSwitcherCountBadge.text(for: 0) == nil)
        #expect(ProfileSwitcherCountBadge.text(for: nil) == nil)
    }

    /// The drawn rows: the badge where there is a count, none at zero.
    @Test func theDrawnRowsWearTheirBadges() async {
        let sections = await factory(["prof-a": 0, "prof-b": 128, "prof-c": 2]).sections(includesAddProfile: true)
        let menu = ProfileSwitcherMenuController(sections: sections, sourceRect: { nil }, onPick: { _ in })
        menu.loadViewIfNeeded()
        let rows = menu.debugRows
        #expect(rows.map(\.title) == ["PROF-A", "PROF-C", "PROF-B", "Add Profile"])
        #expect(rows.map(\.badge) == [nil, "2", "99+", nil])
    }

    /// VoiceOver reads the name and the count as one element.
    @Test func voiceOverReadsTheCount() {
        let item = ProfileSwitcherItem(kind: .profile(ProfileID("a"), isActive: false), title: "Ava Moreau", image: nil, count: 3)
        #expect(item.accessibilityLabel == "Ava Moreau, 3 new notifications")
        let one = ProfileSwitcherItem(kind: .profile(ProfileID("a"), isActive: false), title: "Ava", image: nil, count: 1)
        #expect(one.accessibilityLabel == "Ava, 1 new notification")
        let none = ProfileSwitcherItem(kind: .profile(ProfileID("a"), isActive: false), title: "Ava", image: nil, count: 0)
        #expect(none.accessibilityLabel == "Ava")
    }

    /// Below a source in the upper half, above one in the lower half; kept
    /// inside the screen.
    @Test func itOpensAwayFromItsSource() {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let size = CGSize(width: 250, height: 220)
        let top = ProfileSwitcherMenuController.panelFrame(size: size, source: CGRect(x: 280, y: 60, width: 44, height: 44), in: bounds)
        #expect(top.minY == 104 + ProfileSwitcherMenuController.gap)
        #expect(top.maxX <= bounds.maxX - ProfileSwitcherMenuController.margin)
        let bottom = ProfileSwitcherMenuController.panelFrame(size: size, source: CGRect(x: 240, y: 800, width: 60, height: 50), in: bounds)
        #expect(bottom.maxY == 800 - ProfileSwitcherMenuController.gap)
    }

    /// Hold, slide, release: the row under the lift is picked; a lift on no
    /// row picks nothing and leaves it open.
    @Test func holdSlideReleasePicksTheRowUnderTheFinger() async throws {
        let sections = await factory().sections(includesAddProfile: true)
        var picked: ProfileSwitcherItem.Kind?
        let menu = ProfileSwitcherMenuController(sections: sections, sourceRect: { nil }, onPick: { picked = $0.kind })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = menu
        window.isHidden = false
        menu.view.layoutIfNeeded()
        menu.move(to: CGPoint(x: 1, y: 1))
        menu.end()
        #expect(picked == nil)
        let row = try #require(menu.rows.first)
        let centre = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        menu.move(to: centre)
        #expect(row.isHighlighted)
        // The pick lands after the close, which `dismiss` reports; the window
        // root dismisses nothing, so the highlight is what is checked here.
        window.isHidden = true
    }
}
