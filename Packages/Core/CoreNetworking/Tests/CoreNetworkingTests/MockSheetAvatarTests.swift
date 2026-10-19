import Foundation
import Testing
@testable import CoreNetworkingMocks

/// The mock's animated avatars (#1444): sheet-only — no photo — and a banner
/// of their own (the owner, 2026-10-19).
struct MockSheetAvatarTests {
    private let dataset = MockSocialDataset()

    @Test func animatedAuthorsHaveASheetAndNoPhoto() throws {
        let animated = dataset.authors.enumerated().filter { MockSocialDataset.hasSheetAvatar(index: $0.offset) }
        let still = dataset.authors.enumerated().filter {
            !MockSocialDataset.hasSheetAvatar(index: $0.offset) && MockSocialDataset.avatarShape(index: $0.offset) != nil
        }
        #expect(animated.count > dataset.authors.count / 5, "about half the faces animate: \(animated.count)")
        #expect(!still.isEmpty, "every face animates")
        for (index, author) in animated {
            let url = try #require(URL(string: author.avatarURL))
            #expect(url.fragment == MockSocialDataset.sheetAvatarFragment, "\(author.profileID) is not a sheet avatar")
            #expect(MockSocialDataset.sheetAvatarIndex(url) == index)
            #expect(author.bannerURL == MockSocialDataset.syntheticAvatarURL(index: index),
                    "\(author.profileID) lost the picture its banner showed")
        }
        for (_, author) in still {
            #expect(URL(string: author.avatarURL)?.fragment == nil, "\(author.profileID): a photo marked as a sheet")
            #expect(author.bannerURL.isEmpty)
        }
    }

    @Test func onlyASheetURLNamesAnAuthor() {
        #expect(MockSocialDataset.sheetAvatarIndex(URL(string: MockSocialDataset.sheetAvatarURL(index: 12))!) == 12)
        #expect(MockSocialDataset.sheetAvatarIndex(URL(string: "mock://avatar-sheet/12")!) == nil)
        #expect(MockSocialDataset.sheetAvatarIndex(URL(string: "https://cdn.example/12.jpg#avatar-sheet")!) == nil)
    }
}
