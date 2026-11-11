import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The thread's header pill draws the GROUP (#2233): its members' faces —
/// the inbox row's own picture — never the initials of a name made of its
/// members ("SR", read as Sofía's avatar); its photo when it has one; and a
/// change of faces or photo updated in place.
@MainActor
struct ConversationThreadGroupAvatarTests {
    private final class Driver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?
        var onGroupChange: ((ConversationThreadGroup?) -> Void)?

        var group: ConversationThreadGroup?

        init(group: ConversationThreadGroup?) {
            self.group = group
        }

        func viewDidLoad() {
            // The inbox's title, before the group's details answer.
            onPeerChange?(ConversationThreadPerson(id: nil, name: "Sofía Reyes and Tom Okafor", avatarURL: nil))
            onPhaseChange?(.content([]))
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

        func change(to next: ConversationThreadGroup?) {
            group = next
            onGroupChange?(next)
        }
    }

    private static let sofia = GroupAvatarFace(name: "Sofía Reyes", avatarURL: URL(string: "https://example.com/sofia.jpg"))
    private static let tom = GroupAvatarFace(name: "Tom Okafor", avatarURL: URL(string: "https://example.com/tom.jpg"))
    private static let ana = GroupAvatarFace(name: "Ana Lima", avatarURL: nil)

    /// The owner's screenshot: Sofía, Tom and the viewer, no name, no photo.
    private static func studio(faces: [GroupAvatarFace] = [sofia, tom], memberCount: Int = 3, photo: URL? = nil)
        -> ConversationThreadGroup {
        ConversationThreadGroup(
            name: "Sofía Reyes and Tom Okafor", photoURL: photo, subtitle: "\(memberCount) members", members: [:],
            faces: faces, memberCount: memberCount
        )
    }

    private func makeScreen(_ group: ConversationThreadGroup?) -> (ConversationThreadViewController, Driver, UIWindow) {
        let driver = Driver(group: group)
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

    /// The bug: the pill shows Sofía's and Tom's faces — the inbox row's —
    /// not "SR" on one face.
    @Test func thePillShowsTheMembersFacesNotInitials() async {
        let group = Self.studio()
        let (screen, _, window) = makeScreen(group)
        defer { window.isHidden = true }
        await settle { screen.debugPillGroupAvatar != nil }
        #expect(screen.debugPillGroupAvatar == group.avatar)
        #expect(screen.debugPillGroupAvatar?.drawing == .stack([Self.sofia, Self.tom], more: 0))
        #expect(screen.debugPillGroupAvatarView?.drawnFaceCount == 2)
        #expect(screen.debugPillGroupAvatarView?.drawsSingleDisc == false, "one disc of initials")
    }

    /// The thread's group carries the faces, and the "+N" for a large one.
    @Test func theThreadsGroupCarriesTheFacesAndThePlus() {
        let large = Self.studio(faces: [Self.sofia, Self.tom, Self.ana, Self.sofia], memberCount: 40)
        #expect(large.avatar?.drawing == .stack([Self.sofia, Self.tom, Self.ana], more: 37))
        #expect(Self.studio().avatar?.drawing == .stack([Self.sofia, Self.tom], more: 0))
    }

    /// A member added, then a photo given: the pill follows, in place.
    @Test func aMemberAddedThenAPhotoUpdateThePill() async {
        let (screen, driver, window) = makeScreen(Self.studio())
        defer { window.isHidden = true }
        await settle { screen.debugPillGroupAvatarView?.drawnFaceCount == 2 }
        driver.change(to: Self.studio(faces: [Self.sofia, Self.tom, Self.ana], memberCount: 4))
        #expect(screen.debugPillGroupAvatarView?.drawnFaceCount == 3)
        let photo = URL(string: "https://example.com/studio.jpg")!
        driver.change(to: Self.studio(faces: [Self.sofia, Self.tom, Self.ana], memberCount: 4, photo: photo))
        #expect(screen.debugPillGroupAvatar?.drawing == .photo(photo))
        #expect(screen.debugPillGroupAvatarView?.drawsSingleDisc == true)
    }

    /// No face known yet: the group's initials, on the group's picture.
    @Test func noFaceYetDrawsTheGroupsInitials() async {
        let (screen, _, window) = makeScreen(Self.studio(faces: [], memberCount: 0))
        defer { window.isHidden = true }
        await settle { screen.debugPillGroupAvatar != nil }
        #expect(screen.debugPillGroupAvatar?.drawing == .initials("ST"))
    }

    /// A channel keeps its photo or initials on the face: no faces.
    @Test func aChannelKeepsItsFace() async {
        let channel = ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12.4K subscribers", members: [:], isChannel: true
        )
        #expect(channel.avatar == nil)
        let (screen, _, window) = makeScreen(channel)
        defer { window.isHidden = true }
        await settle { screen.debugPillName == "Daily light" }
        #expect(screen.debugPillGroupAvatar == nil)
    }

    /// The flag off — no group descriptor, a DM — draws the person's face
    /// as before; a group gone back to a DM gives the face back.
    @Test func withoutAGroupThePillIsThePersons() async {
        let (screen, driver, window) = makeScreen(nil)
        defer { window.isHidden = true }
        await settle { screen.debugPillName == "Sofía Reyes and Tom Okafor" }
        #expect(screen.debugPillGroupAvatar == nil)
        driver.change(to: Self.studio())
        await settle { screen.debugPillGroupAvatar != nil }
        driver.change(to: nil)
        await settle { screen.debugPillGroupAvatar == nil }
        #expect(screen.debugPillGroupAvatar == nil)
    }
}
