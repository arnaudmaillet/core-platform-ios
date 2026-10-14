import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings' player pool (#702): three segments named Less / Normal / More,
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

    /// A segmented control, like Autoplay's (#1133): it shows the stored
    /// pool and says which one a segment picked.
    @Test func theControlShowsTheStoredPoolAndSaysWhichOneWasPicked() {
        var picked: [MediaPlaybackPreferences.PlayerPool] = []
        let control = AppPreferencesViewController.makePlayerPoolControl(selected: .more) { picked.append($0) }
        #expect((0..<control.numberOfSegments).map { control.titleForSegment(at: $0) } == ["Less", "Normal", "More"])
        #expect(control.selectedSegmentIndex == 2)
        #expect(control.accessibilityLabel == "Video Players")

        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        #expect(picked == [.less])
    }

    /// The playback footer says a post opened full screen always plays.
    @Test func thePlaybackFooterSaysTheFullScreenPostAlwaysPlays() {
        #expect(AppPreferencesViewController.footer(.playback).contains("full screen always plays"))
    }
}
