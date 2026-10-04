import Foundation
import UIKit
import Testing
@testable import Profile

/// Help and Support / Legal and About (#391): every page App Review and the
/// DSA ask about has a row, and a page that isn't published says so.
@MainActor
struct SettingsLinksTests {
    @Test func noPageIsLiveYet() {
        // #424 tracks the real URLs; until then nothing may point at a page
        // that does not exist.
        #expect(SettingsLinks.current == SettingsLinks())
    }

    @Test func legalListsEveryRequiredPageAndTheVersion() throws {
        let screen = SettingsLinksViewController.legal(links: .current, version: "1.0 (42)")
        screen.loadViewIfNeeded()
        let titles = try rows(of: screen).map(\.title)
        #expect(titles.contains("Terms of Service"))
        #expect(titles.contains("Privacy Policy"))
        #expect(titles.contains("Community Guidelines"))
        #expect(titles.contains("Legal Notice"))
        #expect(titles.contains("Transparency Reports"))
        #expect(titles.last == "Version")
    }

    @Test func aRowWithoutAPageIsComingSoonAndOneWithAPageIsNot() {
        let missing = SettingsLinksViewController.Row.link("Terms", symbol: "doc", url: nil)
        #expect(missing.isComingSoon)
        let live = SettingsLinksViewController.Row.link("Terms", symbol: "doc", url: URL(string: "https://example.org/terms"))
        #expect(!live.isComingSoon)
        #expect(!SettingsLinksViewController.Row.info("Version", symbol: "info.circle", value: "1.0").isComingSoon)
    }

    @Test func helpOffersTheContactPoint() throws {
        let screen = SettingsLinksViewController.help(links: SettingsLinks(contactSupport: URL(string: "mailto:support@example.org")))
        screen.loadViewIfNeeded()
        let contact = try #require(try rows(of: screen).first { $0.title == "Contact Support" })
        #expect(!contact.isComingSoon)
    }

    @Test func theVersionReadsShortVersionAndBuild() {
        #expect(!SettingsLinksViewController.appVersion().isEmpty)
    }

    private func rows(of screen: SettingsLinksViewController) throws -> [SettingsLinksViewController.Row] {
        let list = try #require(screen.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let source = try #require(list.dataSource as? UICollectionViewDiffableDataSource<Int, SettingsLinksViewController.Row>)
        return source.snapshot().itemIdentifiers
    }
}
