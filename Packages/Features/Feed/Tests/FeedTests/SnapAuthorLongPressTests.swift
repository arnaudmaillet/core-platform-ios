import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The post's author pill (#1669): a tap opens the profile card, a hold
/// pushes the profile — opt-in, so the thread's and the composer's pills
/// take no hold.
@MainActor
struct SnapAuthorLongPressTests {
    @Test func aHoldIsOptIn() {
        let pill = SnapAuthorIdentityView()
        #expect(!pill.debugTakesLongPress, "a pill nobody asked takes a hold")
        pill.onAuthorLongPressed = { _ in }
        #expect(pill.debugTakesLongPress)
        pill.onAuthorLongPressed = nil
        #expect(!pill.debugTakesLongPress)
    }

    @Test func aHoldHandsOverTheShownAuthor() {
        let pill = SnapAuthorIdentityView()
        let ada = ProfileID("prof-ada")
        pill.setPerson(id: ada, name: "Ada", meta: "@ada", avatarURL: nil, pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        var held: [ProfileID] = []
        var tapped: [ProfileID] = []
        pill.onAuthorLongPressed = { held.append($0) }
        pill.onAuthorTapped = { tapped.append($0) }
        pill.debugLongPress()
        #expect(held == [ada])
        #expect(tapped.isEmpty, "the hold also tapped")
    }
}
