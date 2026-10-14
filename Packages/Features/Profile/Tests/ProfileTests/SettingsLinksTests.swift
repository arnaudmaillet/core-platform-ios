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
        // The third-party licences (#1128), an app page, never "Coming Soon".
        let acknowledgements = try #require(try rows(of: screen).first { $0.title == "Acknowledgements" })
        #expect(acknowledgements.opensAcknowledgements && !acknowledgements.isComingSoon)
    }

    /// Every package the app ships carries its licence; Phosphor's MIT notice
    /// is there in full (the art behind the custom glyphs, #1128), and an
    /// Apache package shows its NOTICE before the licence.
    @Test func theAcknowledgementsCarryEveryLicence() throws {
        let acknowledgements = try #require(Acknowledgements.bundled)
        let names = acknowledgements.packages.map(\.name)
        for name in ["Phosphor Icons", "GRDB.swift", "Connect-Swift", "Lottie", "SwiftProtobuf", "SwiftNIO"] {
            #expect(names.contains(name), "\(name) is missing")
        }
        let phosphor = try #require(acknowledgements.packages.first { $0.name == "Phosphor Icons" })
        #expect(phosphor.license == "MIT")
        #expect(acknowledgements.licenseText(for: phosphor).contains("Copyright (c) 2023 Phosphor Icons"))
        #expect(acknowledgements.apache2.contains("Apache License"))
        let nio = try #require(acknowledgements.packages.first { $0.name == "SwiftNIO" })
        let text = acknowledgements.licenseText(for: nio)
        #expect(text.contains("Apache License"))
        #expect(try #require(nio.notice).isEmpty == false)
        let notice = Acknowledgements.reflowed(try #require(nio.notice))
        #expect(text.range(of: notice)!.lowerBound < text.range(of: "Apache License")!.lowerBound)
        // Reflowed: a paragraph is one line, not the file's 80 columns.
        #expect(Acknowledgements.reflowed("a\nb\n\nc") == "a b\n\nc")
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
