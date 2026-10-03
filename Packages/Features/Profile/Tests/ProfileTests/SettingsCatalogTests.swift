import Testing
@testable import Profile

/// The shape of Settings: seventeen sections in four scopes, in the order of
/// `dev/ACCOUNT_SETTINGS_GAP_REPORT.md`, and the scope wording that tells the
/// viewer which profile a toggle belongs to.
@MainActor
struct SettingsCatalogTests {
    @Test func seventeenSectionsSplitByScope() {
        #expect(SettingsSection.allCases.count == 17)
        #expect(SettingsSection.sections(in: .account) == [.account, .security, .familyAndTeens, .wallet, .adsAndData])
        #expect(SettingsSection.sections(in: .profile) == [.privacy, .safety, .notifications, .whatYouSee, .activity])
        #expect(SettingsSection.sections(in: .device) == [.playback, .display, .mediaComments, .language, .storage])
        #expect(SettingsSection.sections(in: .support) == [.help, .legal])
    }

    /// App and Device has its own group, out of "App and Legal" (#468), and
    /// says it follows the phone rather than the profile.
    @Test func theDeviceScopeHasItsOwnGroup() {
        #expect(SettingsViewController.headerText(for: .device, activeHandle: "@maya") == "App and Device")
        #expect(SettingsViewController.footerText(for: .device, activeHandle: "@maya")?.contains("this iPhone") == true)
        #expect(SettingsViewController.headerText(for: .support, activeHandle: nil) == "Support and Legal")
    }

    /// Each App and Device page shows its own sections and nothing else.
    @Test func eachDevicePageShowsItsSections() {
        #expect(AppPreferencesViewController.sections(for: .playback) == [.playback])
        #expect(AppPreferencesViewController.sections(for: .display) == [.appearance, .motion])
        #expect(AppPreferencesViewController.sections(for: .mediaComments) == [.band, .muted, .subtitles])
        #expect(AppPreferencesViewController.sections(for: .language) == [.language])
        #expect(AppPreferencesViewController.sections(for: .storage) == [.storage])
        for section in SettingsSection.sections(in: .device) {
            let page = AppPreferencesViewController(page: section)
            page.loadViewIfNeeded()
            #expect(page.title == section.title)
        }
    }

    @Test func theLanguageRowNamesTheAppLanguage() {
        #expect(!AppPreferencesViewController.currentLanguageName().isEmpty)
        #expect(AppPreferencesViewController.footer(.language).contains("English"))
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
        #expect(SettingsViewController.footerText(for: .support, activeHandle: nil) == nil)
    }
}
