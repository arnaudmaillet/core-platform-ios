import CoreStorage
import DesignSystem
import Foundation
import Testing
@testable import Profile

/// Care Mode and the reaction band (#482): on switches the band off; off
/// gives it back only if Care Mode took it.
@MainActor
@Suite(.serialized)
struct CareModeSettingsTests {
    private func fixtures() -> (MediaCommentPreferencesStore, UserDefaults) {
        let store = MediaCommentPreferencesStore(defaults: UserDefaults(suiteName: "care-band-\(UUID().uuidString)")!)
        let defaults = UserDefaults(suiteName: "care-flag-\(UUID().uuidString)")!
        return (store, defaults)
    }

    @Test func careModeTurnsTheBandOffAndBackOn() {
        let (store, defaults) = fixtures()
        defer { CareModePreference.set(false) }
        AppPreferencesViewController.applyCareMode(true, store: store, defaults: defaults)
        #expect(!store.preferences.showsReactionBand)
        AppPreferencesViewController.applyCareMode(false, store: store, defaults: defaults)
        #expect(store.preferences.showsReactionBand)
    }

    @Test func aBandTheViewerHadTurnedOffStaysOff() {
        let (store, defaults) = fixtures()
        defer { CareModePreference.set(false) }
        store.update { $0.showsReactionBand = false }
        AppPreferencesViewController.applyCareMode(true, store: store, defaults: defaults)
        AppPreferencesViewController.applyCareMode(false, store: store, defaults: defaults)
        #expect(!store.preferences.showsReactionBand)
    }

    @Test func theDisplayPageOffersCareMode() {
        #expect(AppPreferencesViewController.sections(for: .display) == [.appearance, .care, .motion])
    }
}
