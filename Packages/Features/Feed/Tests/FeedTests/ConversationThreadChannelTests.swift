import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A channel's thread (#2215): every post signed by the channel — the
/// viewer's own too — the header its name and subscriber count; its owner
/// and admins get the composer, an outsider the reader bar with the way in.
/// A subscriber gets no bar (#2236): the way out is the ⋯ menu's, confirmed,
/// and the mute the bell's.
@MainActor
struct ConversationThreadChannelTests {
    private final class ChannelDriver: ConversationThreadDriving {
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
        private(set) var leaves = 0
        private(set) var withdrawals = 0
        private(set) var infoOpens = 0

        init(group: ConversationThreadGroup?) {
            self.group = group
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: nil, name: "", avatarURL: nil))
            onPhaseChange?(.content([
                ConversationThreadMessage(
                    id: "p1", senderID: ProfileID("owner"), body: "Tonight's light", sentAt: Date(), isMine: false, quote: nil
                ),
                ConversationThreadMessage(
                    id: "p2", senderID: ProfileID("me"), body: "New series Monday", sentAt: Date(), isMine: true, quote: nil
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
        func leave(from presenter: UIViewController) { leaves += 1 }
        func cancelJoinRequest() { withdrawals += 1 }
        func didTapGroupInfo(from presenter: UIViewController) { infoOpens += 1 }

        func change(to next: ConversationThreadGroup) {
            group = next
            onGroupChange?(next)
        }
    }

    private static func channel(_ standing: ConversationThreadReaderStanding?) -> ConversationThreadGroup {
        ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12.4K subscribers", members: [:],
            isChannel: true, readerStanding: standing
        )
    }

    private func makeScreen(_ group: ConversationThreadGroup?) -> (ConversationThreadViewController, ChannelDriver, UIWindow) {
        let driver = ChannelDriver(group: group)
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

    @Test func everyPostIsSignedByTheChannel() async {
        let (screen, _, window) = makeScreen(Self.channel(nil))
        defer { window.isHidden = true }
        await settle { screen.debugAuthorName(of: "p1") == "Daily light" }
        #expect(screen.debugAuthorName(of: "p1") == "Daily light")
        #expect(screen.debugAuthorName(of: "p2") == "Daily light", "the viewer's post is the channel's too")
        #expect(screen.debugPillName == "Daily light")
    }

    @Test func theOwnerGetsTheComposer() async {
        let (screen, _, window) = makeScreen(Self.channel(nil))
        defer { window.isHidden = true }
        await settle { screen.debugAuthorName(of: "p1") == "Daily light" }
        #expect(screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == nil)
    }

    /// #2236: in already, nothing takes a subscriber further in — no bar,
    /// and the footer is bare, the pill and the ⋯.
    @Test func aSubscriberGetsNeitherTheComposerNorABar() async {
        let (screen, _, window) = makeScreen(Self.channel(.subscribed))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(!screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == .subscribed)
        #expect(!screen.debugShowsReaderBar, "a subscriber still gets a bar")
        #expect(screen.debugFooterIsBare)
    }

    @Test func theBarFollowsTheStanding() async {
        let (screen, driver, window) = makeScreen(Self.channel(.canJoin))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding == .canJoin }
        #expect(screen.debugShowsReaderBar)
        // Joined: the bar leaves.
        driver.change(to: Self.channel(.subscribed))
        #expect(screen.debugReaderStanding == .subscribed)
        #expect(!screen.debugShowsReaderBar)
        // Left: Join comes back.
        driver.change(to: Self.channel(.canJoin))
        #expect(screen.debugShowsReaderBar)
        #expect(!screen.debugFooterIsBare)
        // Made an admin: the composer comes back.
        driver.change(to: Self.channel(nil))
        #expect(screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == nil)
        #expect(!screen.debugShowsReaderBar)
        #expect(!screen.debugFooterIsBare)
    }

    /// The bar per standing, per #2236's table: only ways in.
    @Test func eachStandingOffersItsWayIn() {
        typealias Bar = ConversationReaderBar
        #expect(Bar.spec(for: .subscribed).isEmpty, "a subscriber's bar came back")
        #expect(Bar.spec(for: .canJoin).primary?.title == "Join Channel")
        #expect(Bar.spec(for: .canJoin).primary?.action == .join)
        #expect(Bar.spec(for: .canRequest).primary?.title == "Request to Join")
        #expect(Bar.spec(for: .canRequest).primary?.action == .join)
        let requested = Bar.spec(for: .requested)
        #expect(requested.primary?.title == "Requested" && requested.primary?.action == .cancelRequest)
        #expect(requested.primaryIsQuiet)
        #expect(requested.secondary == nil)
        let banned = Bar.spec(for: .unavailable)
        #expect(banned.primary == nil && banned.note != nil)
        #expect(Bar.spec(for: .closed).isEmpty)
    }

    /// #2236: the bell is the one mute, and the way out is the menu's — the
    /// bar asks for neither.
    @Test func theBarHasNoMuteAndNoWayOut() {
        #expect(ConversationReaderBar.Action.allCases == [.join, .cancelRequest, .follow])
    }

    // MARK: - The ⋯ menu (#2236)

    @Test func theMenuOffersTheWayOutPerStanding() {
        #expect(ConversationReaderExit(standing: .subscribed) == .leaveChannel)
        #expect(ConversationReaderExit(standing: .requested) == .cancelRequest)
        #expect(ConversationReaderExit(standing: .following(isFull: false)) == .unfollow)
        #expect(ConversationReaderExit(standing: .following(isFull: true)) == .unfollow)
        #expect(ConversationReaderExit(standing: .canJoin) == nil)
        #expect(ConversationReaderExit(standing: .canRequest) == nil)
        #expect(ConversationReaderExit(standing: .unavailable) == nil)
        #expect(ConversationReaderExit(standing: .canJoinOrFollow(isFull: false)) == nil)
        #expect(ConversationReaderExit(standing: .closed) == nil)
        #expect(ConversationReaderExit(standing: nil) == nil, "an owner or an admin is offered a way out")
        #expect(ConversationReaderExit.leaveChannel.isDestructive)
        #expect(ConversationReaderExit.unfollow.isDestructive)
        #expect(ConversationReaderExit.leaveChannel.symbol == "rectangle.portrait.and.arrow.right")
    }

    @Test func aSubscribersMenuEndsWithLeaveChannel() async throws {
        let (screen, _, window) = makeScreen(Self.channel(.subscribed))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(screen.debugOverflowMenuTitles == ["Channel Info", "Leave Channel"])
        // The info first, the way out last, each a section of its own.
        let menu = try #require(screen.debugOverflowMenu)
        let sections = menu.children.compactMap { $0 as? UIMenu }
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { $0.options.contains(.displayInline) })
        let leave = try #require(sections.last?.children.first as? UIAction)
        #expect(leave.attributes.contains(.destructive))
    }

    @Test func theOwnersMenuHasNoLeave() async {
        let (screen, _, window) = makeScreen(Self.channel(nil))
        defer { window.isHidden = true }
        await settle { screen.debugAuthorName(of: "p1") == "Daily light" }
        #expect(screen.debugOverflowMenuTitles == ["Channel Info"])
    }

    @Test func aPendingRequestsMenuOffersCancelRequest() async {
        let (screen, _, window) = makeScreen(Self.channel(.requested))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(screen.debugOverflowMenuTitles == ["Channel Info", "Cancel Request"])
        #expect(screen.debugShowsReaderBar, "Requested left the bar")
    }

    @Test func anOutsidersMenuIsTheInfoAlone() async {
        let (screen, _, window) = makeScreen(Self.channel(.canJoin))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(screen.debugOverflowMenuTitles == ["Channel Info"])
    }

    @Test func theMenuFollowsTheStanding() async {
        let (screen, driver, window) = makeScreen(Self.channel(.canJoin))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding == .canJoin }
        driver.change(to: Self.channel(.subscribed))
        #expect(screen.debugOverflowMenuTitles == ["Channel Info", "Leave Channel"])
        driver.change(to: Self.channel(.canJoin))
        #expect(screen.debugOverflowMenuTitles == ["Channel Info"])
    }

    @Test func leaveAsksFirst() async {
        let (screen, driver, window) = makeScreen(Self.channel(.subscribed))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        var asked: [ConversationThreadViewController.ReaderConfirmation] = []
        screen.debugConfirmReader = { asked.append($0) }
        screen.debugReaderExit(.leaveChannel)
        #expect(asked.map(\.title) == ["Leave Daily light?"])
        #expect(asked.first?.button == "Leave")
        #expect(driver.leaves == 0, "left before the confirmation")
        asked.first?.confirm()
        #expect(driver.leaves == 1)
    }

    @Test func cancelRequestAsksFirst() async {
        let (screen, driver, window) = makeScreen(Self.channel(.requested))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        var asked: [ConversationThreadViewController.ReaderConfirmation] = []
        screen.debugConfirmReader = { asked.append($0) }
        screen.debugReaderExit(.cancelRequest)
        #expect(asked.map(\.title) == ["Withdraw your request?"])
        #expect(driver.withdrawals == 0)
        asked.first?.confirm()
        #expect(driver.withdrawals == 1)
        // The bar's Requested asks the same.
        screen.debugReaderAction(.cancelRequest)
        #expect(asked.count == 2)
    }

    // MARK: - The bottom inset (#2236)

    /// Without a bar the thread takes the height back: the inset clears the
    /// toolbar alone, and the bar brings its clearance back.
    @Test func theBottomInsetWithAndWithoutTheBar() async {
        let (screen, driver, window) = makeScreen(Self.channel(.canJoin))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding == .canJoin }
        window.layoutIfNeeded()
        screen.view.layoutIfNeeded()
        let withBar = screen.debugBottomInset

        driver.change(to: Self.channel(.subscribed))
        screen.view.layoutIfNeeded()
        let bare = screen.debugBottomInset
        #expect(abs(bare - ConversationThreadViewController.bareBottomInset) < 0.5, "bare: \(bare)")
        #expect(withBar > bare + 20, "the bar's clearance (\(withBar)) vs bare (\(bare))")

        driver.change(to: Self.channel(.canJoin))
        screen.view.layoutIfNeeded()
        #expect(abs(screen.debugBottomInset - withBar) < 0.5, "the bar came back without its clearance")
    }

    /// The descriptor's defaults keep a group a group, posting.
    @Test func aGroupStaysAGroup() {
        let group = ConversationThreadGroup(name: "Hike", photoURL: nil, subtitle: "5 members", members: [:])
        #expect(!group.isChannel && group.canPost)
    }
}
