#if DEBUG
import CoreNavigation
import Testing
import UIKit
@testable import DebugTools

/// `-header-audit`'s expectations (#2475): where each surface's selector
/// belongs, read by the audit that walks the running app.
@MainActor
struct HeaderSelectorAuditTests {
    @Test func theProfilesSelectorIsExpectedInItsHeaderThenInTheBarNeverTheAccessory() {
        let profile = HeaderSelectorAudit.expectedHost[.profile]
        #expect(profile == [.header, .navigationBar], "the profile's selector is expected at \(String(describing: profile))")
        #expect(profile?.contains(.bottomAccessory) == false)
    }

    @Test func theInboxsSelectorStaysInTheBar() {
        #expect(HeaderSelectorAudit.expectedHost[.messages] == [.navigationBar])
    }
}
#endif
