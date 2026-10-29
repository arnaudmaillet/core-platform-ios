import Foundation
import Testing
import UIKit
@testable import Profile

/// **SETTINGS WEARS A LARGE TITLE, AND NOTHING IT PUSHES DOES (#1906).**
///
/// Settings states `.always`: its "Settings" draws large and collapses into
/// the bar as the list scrolls, UIKit's own, on the Profile tab's stack (the
/// one tab stack that prefers large titles). A screen left `.automatic`
/// inherits the mode of the screen it was pushed from, so every screen in
/// `Views/Settings/` states `.never`: one that forgets would grow the same
/// large title the moment Settings pushes it.
@MainActor
struct SettingsLargeTitleTests {
    private static var settingsSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProfileTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Profile
            .appendingPathComponent("Sources/Profile/Views/Settings")
    }

    @Test func settingsStatesALargeTitle() {
        let settings = SettingsViewController(switching: nil, switcher: nil, makeDestination: { _ in nil }, onLogout: {})
        settings.loadViewIfNeeded()
        #expect(settings.navigationItem.largeTitleDisplayMode == .always)
        #expect(settings.title == "Settings")
    }

    @Test func theGuestsSettingsStatesALargeTitleToo() {
        let settings = SettingsViewController(
            switching: nil, switcher: nil, makeDestination: { _ in nil }, onLogout: {}, onSignIn: {}
        )
        settings.loadViewIfNeeded()
        #expect(settings.navigationItem.largeTitleDisplayMode == .always)
    }

    @Test func theComingSoonPageStatesNoLargeTitle() {
        let page = SettingsComingSoonViewController(section: .wallet)
        page.loadViewIfNeeded()
        #expect(page.navigationItem.largeTitleDisplayMode == .never)
    }

    /// Every view controller declared under `Views/Settings/`, Settings aside,
    /// states `.never` in its own body. A new screen that forgets fails here.
    @Test func everyScreenSettingsCanPushStatesNoLargeTitle() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.settingsSources, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        try #require(files.count > 40, "guard: the Settings sources were found")
        let declaration = try Regex(#"(?m)^(?:\w+ )*class (\w+)\s*:\s*[^{\n]*ViewController\b"#)
        var forgot: [String] = []
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = text.matches(of: declaration)
            for (index, match) in matches.enumerated() {
                let name = String(text[match.output[1].range!])
                guard name != "SettingsViewController" else { continue }
                let end = index + 1 < matches.count ? matches[index + 1].range.lowerBound : text.endIndex
                checked += 1
                if !text[match.range.lowerBound..<end].contains("largeTitleDisplayMode = .never") {
                    forgot.append("\(file.lastPathComponent): \(name)")
                }
            }
        }
        try #require(checked > 40, "guard: the screens were found (\(checked))")
        #expect(forgot.isEmpty, "states no `.never`, so it would inherit Settings' large title: \(forgot)")
    }
}
