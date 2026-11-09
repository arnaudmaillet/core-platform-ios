import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A channel's thread (#2215): every post signed by the channel — the
/// viewer's own too — the header its name and subscriber count; its owner
/// and admins get the composer, everyone else the reader bar, whose actions
/// follow where they stand.
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

    @Test func aSubscriberGetsTheReaderBarInstead() async {
        let (screen, _, window) = makeScreen(Self.channel(.subscribed))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding != nil }
        #expect(!screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == .subscribed)
    }

    @Test func theBarFollowsTheStanding() async {
        let (screen, driver, window) = makeScreen(Self.channel(.canJoin))
        defer { window.isHidden = true }
        await settle { screen.debugReaderStanding == .canJoin }
        driver.change(to: Self.channel(.subscribed))
        #expect(screen.debugReaderStanding == .subscribed)
        // Made an admin: the composer comes back.
        driver.change(to: Self.channel(nil))
        #expect(screen.debugShowsComposer)
        #expect(screen.debugReaderStanding == nil)
    }

    @Test func eachStandingOffersItsActions() {
        typealias Bar = ConversationReaderBar
        let subscribed = Bar.spec(for: .subscribed, isMuted: false)
        #expect(subscribed.primary?.title == "Mute" && subscribed.primary?.action == .toggleMute)
        #expect(subscribed.showsLeave)
        #expect(Bar.spec(for: .subscribed, isMuted: true).primary?.title == "Unmute")
        #expect(Bar.spec(for: .canJoin, isMuted: false).primary?.action == .join)
        #expect(Bar.spec(for: .canRequest, isMuted: false).primary?.title == "Request to Join")
        let requested = Bar.spec(for: .requested, isMuted: false)
        #expect(requested.primary?.title == "Requested" && requested.primary?.action == .cancelRequest)
        #expect(!requested.showsLeave)
        let banned = Bar.spec(for: .unavailable, isMuted: false)
        #expect(banned.primary == nil && banned.note != nil)
    }

    /// The descriptor's defaults keep a group a group, posting.
    @Test func aGroupStaysAGroup() {
        let group = ConversationThreadGroup(name: "Hike", photoURL: nil, subtitle: "5 members", members: [:])
        #expect(!group.isChannel && group.canPost)
    }
}
