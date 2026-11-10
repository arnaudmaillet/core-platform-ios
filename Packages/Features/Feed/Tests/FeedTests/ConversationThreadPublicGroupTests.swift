import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A public group's thread (#2217): an outsider reads with Join and Follow
/// in the composer's place, a follower with Join alone — their Unfollow is
/// the ⋯ menu's, confirmed (#2236) — a full group offers Follow only, a
/// member writes, and a group turned private under its reader drops the bar
/// and the composer alike.
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
        func didTapGroupInfo(from presenter: UIViewController) {}
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
        let spec = ConversationReaderBar.spec(for: .canJoinOrFollow(isFull: false))
        #expect(spec.primary?.title == "Join" && spec.primary?.action == .join)
        #expect(spec.secondary?.title == "Follow" && spec.secondary?.action == .follow)
        #expect(spec.note == nil)
    }

    @Test func aFullGroupOffersFollowOnly() {
        let outsider = ConversationReaderBar.spec(for: .canJoinOrFollow(isFull: true))
        #expect(outsider.primary == nil, "Join offered past the cap")
        #expect(outsider.note == "This group is full")
        #expect(outsider.secondary?.action == .follow)
        // A full group's follower: the line alone (#2236), Unfollow is the menu's.
        let follower = ConversationReaderBar.spec(for: .following(isFull: true))
        #expect(follower.primary == nil)
        #expect(follower.note == "This group is full")
        #expect(follower.secondary == nil, "Following is still on the bar")
        #expect(!follower.isEmpty)
    }

    /// #2236: a follower's bar is the way further in alone.
    @Test func aFollowerIsOfferedJoinOnly() {
        let spec = ConversationReaderBar.spec(for: .following(isFull: false))
        #expect(spec.primary?.title == "Join" && spec.primary?.action == .join)
        #expect(spec.secondary == nil, "Following is still on the bar")
        #expect(spec.note == nil)
    }

    @Test func aClosedGroupOffersNothing() {
        #expect(ConversationReaderBar.spec(for: .closed).isEmpty)
        #expect(ConversationReaderBar.spec(for: .subscribed).isEmpty, "a channel's subscriber got a bar again")
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
        #expect(screen.debugShowsReaderBar, "a follower keeps Join")
        screen.debugReaderAction(.join)
        #expect(driver.joins == 1)
    }

    // MARK: - The ⋯ menu (#2236)

    @Test func anOutsidersMenuIsTheGroupInfoAlone() async {
        let (screen, _, window) = makeScreen(Self.group(.canJoinOrFollow(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(screen.debugOverflowMenuTitles == ["Group Info"])
    }

    @Test func aFollowersMenuEndsWithUnfollow() async throws {
        let (screen, _, window) = makeScreen(Self.group(.following(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(screen.debugOverflowMenuTitles == ["Group Info", "Unfollow"])
        let menu = try #require(screen.debugOverflowMenu)
        let unfollow = try #require((menu.children.last as? UIMenu)?.children.first as? UIAction)
        #expect(unfollow.attributes.contains(.destructive))
    }

    @Test func aMembersMenuHasNoWayOut() async {
        let (screen, _, window) = makeScreen(Self.group(nil))
        defer { window.isHidden = true }
        await settle { screen.debugPillName == "Coastal cleanup" }
        #expect(screen.debugOverflowMenuTitles == ["Group Info"], "a member leaves from the info screen")
    }

    @Test func unfollowAsksFirst() async {
        let (screen, driver, window) = makeScreen(Self.group(.following(isFull: false)))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        var asked: [ConversationThreadViewController.ReaderConfirmation] = []
        screen.debugConfirmReader = { asked.append($0) }
        screen.debugReaderExit(.unfollow)
        #expect(asked.map(\.title) == ["Unfollow Coastal cleanup?"])
        #expect(asked.first?.button == "Unfollow")
        #expect(driver.unfollows == 0, "unfollowed before the confirmation")
        asked.first?.confirm()
        #expect(driver.unfollows == 1)
        // Unfollowed: the outsider's menu, with no way out.
        driver.change(to: Self.group(.canJoinOrFollow(isFull: false)))
        #expect(screen.debugOverflowMenuTitles == ["Group Info"])
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
