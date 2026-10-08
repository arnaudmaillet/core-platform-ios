import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings' player pool (#702): three notches named Less / Normal / More,
/// never a number, and a footer that says what it trades.
@MainActor
struct PlayerPoolSettingsTests {
    @Test func thePlaybackPageOffersThePlayerPool() {
        #expect(AppPreferencesViewController.sections(for: .playback) == [.playback, .players, .sounds])
    }

    @Test func theFooterSaysWhatItTradesWithoutANumber() {
        let footer = AppPreferencesViewController.footer(.players)
        #expect(footer.contains("performance"))
        #expect(footer.contains("battery"))
        #expect(!footer.contains { $0.isNumber }, "the footer names a number: \(footer)")
        #expect(MediaPlaybackPreferences.PlayerPool.allCases.map(AppPreferencesViewController.playerPoolTitle)
                == ["Less", "Normal", "More"])
    }

    @Test func theSliderRestsOnItsNotchesAndSaysWhenOneChanges() {
        let slider = NotchedSlider(notches: ["Less", "Normal", "More"], selected: 1)
        #expect(slider.debugNotchTitles == ["Less", "Normal", "More"])
        #expect(slider.selectedIndex == 1)
        var changes: [Int] = []
        slider.addAction(UIAction { _ in changes.append(slider.selectedIndex) }, for: .valueChanged)

        slider.select(2)
        slider.select(2)
        slider.select(5)
        slider.accessibilityDecrement()
        #expect(changes == [2, 1], "a notch that did not change was announced: \(changes)")
        #expect(slider.accessibilityValue == "Normal")
    }

    /// The playback footer says a post opened full screen always plays.
    @Test func thePlaybackFooterSaysTheFullScreenPostAlwaysPlays() {
        #expect(AppPreferencesViewController.footer(.playback).contains("full screen always plays"))
    }
}
