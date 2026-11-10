import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The thread's bell and a group's or a channel's info screen share one
/// menu (#2237, `MuteMenu`): a duration added once shows on every bell.
@MainActor
struct SharedBellMenuTests {
    @Test func theThreadsBellReadsTheSharedDurations() {
        let thread = ConversationThreadViewController.muteDurations
        #expect(thread.map(\.title) == MuteMenu.durations.map(\.title))
        #expect(thread.map(\.toast) == MuteMenu.durations.map(\.toast))
        #expect(thread.map(\.seconds) == MuteMenu.durations.map(\.seconds))
    }

    @Test func theSharedMenuOffersUnmuteOnlyOnceMuted() throws {
        let on = MuteMenu.make(muted: false, onMute: { _ in }, onUnmute: {})
        let mute = try #require(on.children.first as? UIMenu)
        #expect(on.children.count == 1)
        #expect(mute.title == "Mute Notifications")
        #expect(mute.children.map(\.title) == MuteMenu.durations.map(\.title))

        let muted = MuteMenu.make(muted: true, onMute: { _ in }, onUnmute: {})
        #expect(muted.children.first?.title == "Unmute")
        #expect((muted.children.last as? UIMenu)?.title == "Mute Again")
        #expect(MuteMenu.symbol(muted: true) == "bell.slash")
        #expect(MuteMenu.durations.last?.end() == nil, "until turned back on: no end")
    }
}
