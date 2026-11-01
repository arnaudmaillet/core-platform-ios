import CoreModels
import Foundation
import MediaCore
import ProfileInterface
import Testing
import UIKit
@testable import Profile

/// Three profiles of one account: the active one first.
private struct ThreeProfiles: ProfileSwitching {
    func accountProfiles() async throws -> [AccountProfile] {
        ["prof-a", "prof-b", "prof-c"].map {
            AccountProfile(id: ProfileID($0), handle: $0, displayName: $0.uppercased(), avatarURL: nil)
        }
    }
    func activeProfileID() async -> ProfileID? { ProfileID("prof-a") }
    func setActiveProfile(_ id: ProfileID) async {}
}

/// Each profile's unread notifications in the switcher (#2034), and the
/// Profile tab's dot they light.
@MainActor
struct ProfileSwitcherUnreadTests {
    private func switcher(counts: [String: Int?]) -> ProfileSwitcherMenuFactory {
        ProfileSwitcherMenuFactory(
            switching: ThreeProfiles(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            unreadCount: { id in counts[id.rawValue] ?? nil }
        )
    }

    /// `reload` reads every profile's count with the avatars; a count that
    /// could not be read is left out, never a zero.
    @Test func reloadReadsEveryProfilesCount() async {
        let factory = switcher(counts: ["prof-a": 0, "prof-b": 128, "prof-c": nil])
        await factory.reload()
        #expect(factory.unreadCounts == [ProfileID("prof-a"): 0, ProfileID("prof-b"): 128])
        #expect(factory.hasUnreadNotifications, "another profile's unread does not light the dot")
    }

    /// The dot is out once every profile is read.
    @Test func noUnreadAnywhereKeepsTheDotOut() async {
        let factory = switcher(counts: ["prof-a": 0, "prof-b": 0, "prof-c": 0])
        await factory.reload()
        #expect(!factory.hasUnreadNotifications)
    }

    /// The tab's refresh reads the counts again, without a reload first too.
    @Test func theCountsReloadOnTheirOwn() async {
        var counts: [String: Int?] = ["prof-a": 2]
        let factory = ProfileSwitcherMenuFactory(
            switching: ThreeProfiles(),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            unreadCount: { id in counts[id.rawValue] ?? nil }
        )
        await factory.reloadUnreadCounts()
        #expect(factory.unreadCounts == [ProfileID("prof-a"): 2])
        counts = ["prof-a": 0, "prof-c": 5]
        await factory.reloadUnreadCounts()
        #expect(factory.unreadCounts == [ProfileID("prof-a"): 0, ProfileID("prof-c"): 5])
    }
}
