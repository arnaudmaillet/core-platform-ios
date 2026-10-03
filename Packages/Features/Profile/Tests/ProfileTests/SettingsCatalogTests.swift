import Testing
@testable import Profile

/// The shape of Settings: thirteen sections in three scopes, in the order of
/// `dev/ACCOUNT_SETTINGS_GAP_REPORT.md`, and the scope wording that tells the
/// viewer which profile a toggle belongs to.
@MainActor
struct SettingsCatalogTests {
    @Test func thirteenSectionsSplitFiveFiveThreeByScope() {
        #expect(SettingsSection.allCases.count == 13)
        #expect(SettingsSection.sections(in: .account) == [.account, .security, .familyAndTeens, .wallet, .adsAndData])
        #expect(SettingsSection.sections(in: .profile) == [.privacy, .safety, .notifications, .whatYouSee, .activity])
        #expect(SettingsSection.sections(in: .app) == [.appPreferences, .help, .legal])
    }

    /// Every section can stand in for itself before it is built: a title, an
    /// icon of its own and something to say on its coming-soon page.
    @Test func everySectionHasATitleAnIconAndPlannedItems() {
        for section in SettingsSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.plannedItems.isEmpty, "\(section) has nothing to announce")
        }
        let symbols = SettingsSection.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }

    /// The raw values are the `-open-settings <section>` QA vocabulary.
    @Test func rawValuesRoundTrip() {
        for section in SettingsSection.allCases {
            #expect(SettingsSection(rawValue: section.rawValue) == section)
        }
    }

    @Test func theProfileScopeNamesTheActiveProfile() {
        #expect(SettingsViewController.headerText(for: .profile, activeHandle: "@maya") == "Profile · @maya")
        #expect(SettingsViewController.footerText(for: .profile, activeHandle: "@maya")?.contains("@maya only") == true)
    }

    /// Before the active profile is known the header says "Profile", never a
    /// guessed name.
    @Test func theProfileScopeDoesNotGuessBeforeItKnows() {
        #expect(SettingsViewController.headerText(for: .profile, activeHandle: nil) == "Profile")
        #expect(SettingsViewController.footerText(for: .profile, activeHandle: nil) == "Applies to the active profile only.")
    }

    @Test func theAccountScopeSaysItFollowsEveryProfile() {
        #expect(SettingsViewController.headerText(for: .account, activeHandle: "@maya") == "Account-Wide")
        #expect(SettingsViewController.footerText(for: .account, activeHandle: "@maya") == "Applies to every profile on this account.")
        #expect(SettingsViewController.footerText(for: .app, activeHandle: nil) == nil)
    }
}
