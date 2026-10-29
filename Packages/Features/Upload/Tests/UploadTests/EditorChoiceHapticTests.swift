import DesignSystem
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// THE EDITOR'S CHOICES TICK (#1887): one `tick` per changed choice, none
/// for the one already chosen; the tray's carry lifts and lands.
@MainActor
struct EditorChoiceHapticTests {
    /// What `body` played, a second between two taps so pacing hides none.
    private func played(_ body: (_ next: () -> Void) -> Void) -> [Haptic] {
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) { body { now += 1 } }
        return recorder.played
    }

    @Test func theFilterRowTicksPerChange() throws {
        let row = MediaFilterRowView()
        let other = try #require(MediaFilter.allCases.first { $0 != row.debugSelected })
        let ticks = played { next in
            row.debugTap(row.debugSelected)
            next()
            row.debugTap(other)
        }
        #expect(ticks == [.tick], "\(ticks)")
    }

    @Test func theSpeedRowTicksPerChange() {
        let row = MediaSpeedRowView()
        row.show(rate: 1)
        let ticks = played { next in
            row.debugTap(rate: 1)
            next()
            row.debugTap(rate: 2)
        }
        #expect(ticks == [.tick], "\(ticks)")
    }

    @Test func theTransitionLengthRowTicksPerChange() {
        let row = MediaTransitionDurationRowView()
        row.show(seconds: 0.5, longest: 2)
        let ticks = played { next in
            row.debugTap(seconds: 0.5)
            next()
            row.debugTap(seconds: 1)
        }
        #expect(ticks == [.tick], "\(ticks)")
    }

    @Test func theTransitionRowTicksPerChange() throws {
        let row = MediaTransitionRowView()
        let kind = try #require(VideoTransitionKind.allCases.first)
        let ticks = played { next in
            row.debugTap(nil)
            next()
            row.debugTap(kind)
        }
        #expect(ticks == [.tick], "\(ticks)")
    }

    @Test func theTextStyleBarTicksPerChange() throws {
        let bar = MediaTextStyleBar(frame: .zero)
        let current = bar.style.font
        let other = try #require(OverlayFont.allCases.first { $0 != current })
        let ticks = played { next in
            bar.choose(current)
            next()
            bar.choose(other)
        }
        #expect(ticks == [.tick], "\(ticks)")
    }

    /// The tray's carry lands: `drop` moved, nothing back in place.
    @Test func theTrayDropsOnlyInANewPlace() {
        let tray = SelectedMediaTrayView(thumbnailProvider: { _, _ in nil })
        let moved = HapticRecorder.recording { tray.debugLanded(moved: true) }
        #expect(moved == [.drop])
        let back = HapticRecorder.recording { tray.debugLanded(moved: false) }
        #expect(back.isEmpty)
    }
}
