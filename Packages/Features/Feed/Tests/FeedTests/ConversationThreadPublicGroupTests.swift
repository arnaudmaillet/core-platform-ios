import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A public group's thread (#2217): an outsider reads with Join and Follow
/// in the composer's place, a follower with Join and Following, a full
/// group offers Follow only, a member writes — and a group turned private
/// under its reader drops the bar and the composer alike.
@MainActor
struct ConversationThreadPublicGroupTests {
    private final class GroupDriver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?
        var onGroupChange: ((ConversationThreadGroup?) -> Void)?

        var group: ConversationThreadGroup?
        private(set) var joins = 0
        private(set) var follows = 0
        private(set) var unfollows = 0

        init(group: ConversationThreadGroup?) {
            self.group = group
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: nil, name: "", avatarURL: nil))
            onPhaseChange?(.content([
                ConversationThreadMessage(
                    id: "m1", senderID: ProfileID("a"), body: "Next clean on Sunday", sentAt: Date(), isMine: false, quote: nil
                ),
            ]))
            onGroupChange?(group)
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) {}
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {}
        func join() { joins += 1 }
        func follow() { follows += 1 }
        func unfollow() { unfollows += 1 }

        func change(to next: ConversationThreadGroup) {
            group = next
            onGroupChange?(next)
        }
    }

    private static func group(_ standing: ConversationThreadReaderStanding?) -> ConversationThreadGroup {
        ConversationThreadGroup(
            name: "Coastal cleanup", photoURL: nil, subtitle: "40 members · 2.3K followers",
            members: [ProfileID("a"): ConversationThreadPerson(id: ProfileID("a"), name: "Alice", avatarURL: nil)],
            readerStanding: standing
        )
    }

    private func makeScreen(_ group: ConversationThreadGroup?) -> (ConversationThreadViewController, GroupDriver, UIWindow) {
        let driver = GroupDriver(group: group)
        let screen = ConversationThreadViewController(
            driver: driver, mode: .full, prefill: "", imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, window)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The bar's words

    @Test func anOutsiderIsOfferedJoinAndFollow() {
        let spec = ConversationReaderBar.spec(for: .canJoinOrFollow(isFull: false), isMuted: false)
        #expect(spec.primary?.title == "Join" && spec.primary?.action == .join)
        #expect(spec.secondary?.title == "Follow" && spec.secondary?.action == .follow)
        #expect(spec.note == nil)
        #expect(!spec.showsLeave)
    }

    @Test func aFullGroupOffersFollowOnly() {
        let outsider = ConversationReaderBar.spec(for: .canJoinOrFollow(isFull: true), isMuted: false)
        #expect(outsider.primary == nil, "Join offered past the cap")
        #expect(outsider.note == "This group is full")
        #expect(outsider.secondary?.action == .follow)
        let follower = ConversationReaderBar.spec(for: .following(isFull: true), isMuted: false)
        #expect(follower.primary == nil)
        #expect(follower.note == "This group is full")
        #expect(follower.secondary?.action == .unfollow)
    }

    @Test func aFollowerIsOfferedJoinAndFollowing() {
        let spec = ConversationReaderBar.spec(for: .following(isFull: false), isMuted: false)
        #expect(spec.primary?.action == .join)
        #expect(spec.secondary?.title == "Following" && spec.secondary?.action == .unfollow)
    }

    @Test func aClosedGroupOffersNothing() {
        #expect(ConversationReaderBar.spec(for: .closed, isMuted: false).isEmpty)
        #expect(!ConversationReaderBar.spec(for: .subscribed, isMuted: false).isEmpty)
        #expect(ConversationReaderBar.spec(for: .subscribed, isMuted: false).showsLeave, "a channel's Leave went")
    }

    // MARK: - The screen

    @Test func anOutsiderReadsWithoutTheComposer() async {
        let (screen, driver, window) = makeScreen(Self.group(.canJoinOrFollow(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(!screen.debugShowsComposer)
        #expect(screen.debugShowsReaderBar)
        #expect(screen.debugReaderStanding == .canJoinOrFollow(isFull: false))
        #expect(screen.debugPillName == "Coastal cleanup")

        screen.debugReaderAction(.follow)
        #expect(driver.follows == 1)
        // A second tap while the first is on its way is dropped.
        screen.debugReaderAction(.follow)
        #expect(driver.follows == 1)
        driver.change(to: Self.group(.following(isFull: false)))
        #expect(screen.debugReaderStanding == .following(isFull: false))
        screen.debugReaderAction(.join)
        #expect(driver.joins == 1)
    }

    @Test func aMemberWritesAndAFollowerWhoJoinsGetsTheComposer() async {
        let (screen, driver, window) = makeScreen(Self.group(.following(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(!screen.debugShowsComposer)
        driver.change(to: Self.group(nil))
        #expect(screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == nil)
        #expect(!screen.debugShowsReaderBar)
    }

    @Test func aGroupTurnedPrivateDropsTheBarAndTheComposer() async {
        let (screen, driver, window) = makeScreen(Self.group(.following(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        driver.change(to: Self.group(.closed))
        #expect(screen.debugReaderStanding == .closed)
        #expect(!screen.debugShowsReaderBar, "a closed group still offers its bar")
        #expect(!screen.debugShowsComposer, "a closed group offers the composer")
    }
}
