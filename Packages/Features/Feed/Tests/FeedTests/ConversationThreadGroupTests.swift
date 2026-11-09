import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// A group's thread (#2214): each row signed by its own sender — never
/// "Member" for someone the group lists — the header the group's, a tap on
/// it its info screen, and a system line drawn as one.
@MainActor
struct ConversationThreadGroupTests {
    private final class GroupDriver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?
        var onGroupChange: ((ConversationThreadGroup?) -> Void)?

        let group: ConversationThreadGroup?
        let messages: [ConversationThreadMessage]
        private(set) var infoTaps = 0
        private(set) var memberTaps: [ProfileID] = []

        init(group: ConversationThreadGroup?, messages: [ConversationThreadMessage]) {
            self.group = group
            self.messages = messages
        }

        func viewDidLoad() {
            // A group's title from the inbox, with no single peer.
            onPeerChange?(ConversationThreadPerson(id: nil, name: "Alice, Bob and Carla", avatarURL: nil))
            onPhaseChange?(.content(messages))
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
        func didTapGroupInfo(from presenter: UIViewController) { infoTaps += 1 }
        func didTapMember(_ profileID: ProfileID) { memberTaps.append(profileID) }
    }

    private static let alice = ProfileID("alice")
    private static let bob = ProfileID("bob")
    private static let carla = ProfileID("carla")

    private static func message(_ id: String, from sender: ProfileID, minute: Double, system: Bool = false)
        -> ConversationThreadMessage {
        ConversationThreadMessage(
            id: id, senderID: sender, body: system ? "You created the group" : "Message \(id)",
            sentAt: Calendar.current.startOfDay(for: Date()).addingTimeInterval(minute * 60),
            isMine: sender == ProfileID("me"), quote: nil, isSystem: system
        )
    }

    private static let transcript = [
        message("created", from: ProfileID(""), minute: 1, system: true),
        message("a1", from: alice, minute: 2),
        message("b1", from: bob, minute: 3),
        message("c1", from: carla, minute: 4),
        message("me1", from: ProfileID("me"), minute: 5),
        message("x1", from: ProfileID("left-the-group"), minute: 6),
    ]

    private static let group = ConversationThreadGroup(
        name: "Weekend hike", photoURL: nil, subtitle: "5 members",
        members: [
            alice: ConversationThreadPerson(id: alice, name: "Alice Martin", avatarURL: nil),
            bob: ConversationThreadPerson(id: bob, name: "Bob Ray", avatarURL: nil),
            carla: ConversationThreadPerson(id: carla, name: "Carla Diaz", avatarURL: nil),
        ]
    )

    private func makeScreen(group: ConversationThreadGroup?) -> (ConversationThreadViewController, GroupDriver, UIWindow) {
        let driver = GroupDriver(group: group, messages: Self.transcript)
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

    @Test func eachRowIsSignedByItsOwnSender() async {
        let (screen, _, window) = makeScreen(group: Self.group)
        defer { window.isHidden = true }
        await settle { screen.debugAuthorName(of: "a1") == "Alice Martin" }
        #expect(screen.debugAuthorName(of: "a1") == "Alice Martin")
        #expect(screen.debugAuthorName(of: "b1") == "Bob Ray")
        #expect(screen.debugAuthorName(of: "c1") == "Carla Diaz")
        #expect(screen.debugAuthorName(of: "me1") == "You")
        // Someone the group no longer lists.
        #expect(screen.debugAuthorName(of: "x1") == "Member")
    }

    @Test func theHeaderIsTheGroupsAndOpensItsInfo() async {
        let (screen, driver, window) = makeScreen(group: Self.group)
        defer { window.isHidden = true }
        await settle { screen.debugPillName == "Weekend hike" }
        #expect(screen.debugPillName == "Weekend hike", "the peer's joined names won over the group")
        screen.debugTapPill()
        #expect(driver.infoTaps == 1)
    }

    @Test func aSystemLineIsDrawnAsOne() async {
        let (screen, _, window) = makeScreen(group: Self.group)
        defer { window.isHidden = true }
        await settle { screen.debugIsSystemLine("created") }
        #expect(screen.debugIsSystemLine("created"))
        #expect(!screen.debugIsSystemLine("a1"))
    }

    /// No group descriptor: a group drawn the old way keeps "Member" — and a
    /// DM is untouched (the flag off).
    @Test func withoutTheDescriptorRowsStaySignedAsBefore() async {
        let (screen, driver, window) = makeScreen(group: nil)
        defer { window.isHidden = true }
        await settle { screen.debugAuthorName(of: "a1") != nil }
        #expect(screen.debugAuthorName(of: "a1") == "Member")
        screen.debugTapPill()
        #expect(driver.infoTaps == 0)
    }
}
