import Testing
import UIKit

@testable import Upload

/// The banner that sits above the grid when the viewer has shared only part of
/// their library.
@MainActor
struct MediaAccessNoticeTests {
    /// ⚠️ **THE ORDER IS THE PRODUCT DECISION, SO THE ORDER IS WHAT IS ASSERTED.**
    /// Adding photos through the system sheet never leaves the app; Settings
    /// drops the viewer out of it and asks them to find their way back. Both are
    /// offered because only Settings can widen the permission itself — but the
    /// one that keeps them here leads. A test that merely counted two entries
    /// would let someone swap them and stay green.
    @Test func theNoticeOffersTheNativeRouteBeforeSettings() {
        let notice = MediaAccessNoticeView()

        #expect(notice.debugMenuTitles == ["Select More Photos…", "Allow Access to All Photos"])
    }

    /// Each way out calls its OWN handler — the menu wires two actions to one
    /// button, which is exactly where a copy-paste swaps them.
    @Test func eachWayOutCallsOnlyItsOwnAction() {
        let notice = MediaAccessNoticeView()
        var selectedMore = 0
        var openedSettings = 0
        notice.onSelectMore = { selectedMore += 1 }
        notice.onOpenSettings = { openedSettings += 1 }

        notice.debugTapSelectMore()
        #expect(selectedMore == 1, "the native picker fired")
        #expect(openedSettings == 0, "and Settings did not")

        notice.debugTapOpenSettings()
        #expect(openedSettings == 1, "Settings fired on its own entry")
        #expect(selectedMore == 1, "and the native picker was not fired again")
    }

    /// The banner exists to SAY something; an empty line would be furniture over
    /// the grid for no reason.
    @Test func theNoticeSaysWhatTheViewerHasShared() throws {
        let notice = MediaAccessNoticeView()

        let text = try #require(notice.debugText)
        #expect(!text.isEmpty)
    }
}
