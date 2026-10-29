import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Maps

/// A MAP FILTER IS A CHOICE (#1886): `tick` once per change, nothing for
/// the pill already chosen.
@MainActor
struct MapFilterHapticTests {
    @Test func aFilterChangeTicksAndTheSamePillAgainDoesNot() {
        let bar = MapFilterBarView()
        var changes: [MapFilter?] = []
        bar.onFilterChanged = { changes.append($0) }
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) {
            bar.debugTap(nil) // All, already chosen
            now += 1
            bar.debugTap(.friends)
            now += 1
            bar.debugTap(nil)
        }
        #expect(changes.count == 2)
        #expect(recorder.played == [.tick, .tick], "\(recorder.played)")
    }

    @Test func aSubFilterTapTicks() {
        let bar = MapSubFilterBarView()
        let played = HapticRecorder.recording { bar.debugTap(.followedPlaces) }
        #expect(played == [.tick])
    }
}
