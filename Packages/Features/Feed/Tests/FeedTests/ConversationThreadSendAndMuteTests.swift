import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The thread's send states and bell (#719): a text on its way is drawn
/// faded with a spinner, a failed one with a red mark that retries on a tap,
/// and the bar's bell mutes the conversation through the driver.
@MainActor
struct ConversationThreadSendAndMuteTests {
    private final class Driver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onSendingChange: ((Bool) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onMutedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?

        var initial: ConversationThreadPhase
        /// What the inbox would say about the mute; nil is a draft.
        var muted: Bool?
        private(set) var retried: [String] = []
        private(set) var replies: [String] = []

        init(initial: ConversationThreadPhase, muted: Bool?) {
            self.initial = initial
            self.muted = muted
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onMutedChange?(muted)
            onPhaseChange?(initial)
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) { replies.append(messageID) }
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {}
        func retry(_ messageID: String) { retried.append(messageID) }
        func toggleMuted() {
            guard let muted else { return }
            self.muted = !muted
            onMutedChange?(self.muted)
        }
        private(set) var mutes: [(muted: Bool, until: Date?)] = []
        /// The server's answers not given yet, oldest first: a test answers
        /// them with `answerMute(_:)`.
        private var pendingMutes: [@MainActor (Bool) -> Void] = []
        func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (Bool) -> Void) {
            mutes.append((muted, until))
            let before = self.muted
            self.muted = muted
            onMutedChange?(muted)
            pendingMutes.append { [weak self] confirmed in
                if !confirmed, let self {
                    self.muted = before
                    self.onMutedChange?(before)
                }
                completion(confirmed)
            }
        }
        /// The server answers the oldest pending mute.
        func answerMute(_ confirmed: Bool) {
            guard !pendingMutes.isEmpty else { return }
            pendingMutes.removeFirst()(confirmed)
        }
    }

    private static func message(
        _ id: String, mine: Bool, minutes: Double, delivery: ConversationThreadDelivery = .sent
    ) -> ConversationThreadMessage {
        ConversationThreadMessage(
            id: id, senderID: ProfileID(mine ? "me" : "them"), body: "Message \(id)",
            sentAt: Calendar.current.startOfDay(for: Date()).addingTimeInterval(minutes * 60),
            isMine: mine, quote: nil, delivery: delivery
        )
    }

    private func makeScreen(
        phase: ConversationThreadPhase, muted: Bool? = false
    ) -> (ConversationThreadViewController, Driver, UIWindow) {
        let driver = Driver(initial: phase, muted: muted)
        let screen = ConversationThreadViewController(
            driver: driver, mode: .full, prefill: "",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, window)
    }

    private func bell(_ screen: ConversationThreadViewController) -> UIBarButtonItem? {
        screen.navigationItem.rightBarButtonItems?.first { $0.accessibilityLabel == "Notifications" }
    }

    private func cells(in view: UIView) -> [ThreadRowCell] {
        if let cell = view as? ThreadRowCell { return [cell] }
        return view.subviews.flatMap { cells(in: $0) }
    }

    private func cell(_ body: String, in screen: ConversationThreadViewController) -> ThreadRowCell? {
        cells(in: screen.view).first { $0.row.bodyTextLabel.text == body }
    }

    // MARK: - The bell

    /// The bell takes the bar's trailing corner and follows the mute,
    /// wherever it was changed; a tap goes to the driver.
    @Test func theBellMutesThroughTheDriver() throws {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        let item = try #require(bell(screen), "no bell in the bar")
        #expect(screen.navigationItem.rightBarButtonItems?.first === item, "the bell is not the trailing corner")
        #expect(item.image == UIImage(systemName: "bell"))
        #expect(item.accessibilityValue == "On")

        #expect(item.primaryAction != nil, "the bell does nothing")
        driver.toggleMuted()
        #expect(driver.muted == true)
        let muted = try #require(bell(screen))
        #expect(muted.image == UIImage(systemName: "bell.slash"))
        #expect(muted.accessibilityValue == "Muted")

        // Unmuted from elsewhere (the inbox's menu): the glyph follows.
        driver.onMutedChange?(false)
        #expect(bell(screen)?.image == UIImage(systemName: "bell"))
    }

    // MARK: - The header (#738)

    /// No points badge: the bell (and its spacer) is all that trails.
    @Test func theHeaderHasNoPointsBadge() {
        let (screen, _, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        let customViews = (screen.navigationItem.rightBarButtonItems ?? []).compactMap(\.customView)
        #expect(!customViews.contains { $0 is WalletBadgeButton }, "the points badge is still in the bar")
        #expect(screen.navigationItem.rightBarButtonItems?.filter { $0.customView != nil }.isEmpty == true)
    }

    /// No title in the centre (#750, over #738): the correspondent is the
    /// toolbar's pill. The screen keeps their name for VoiceOver.
    @Test func theHeaderShowsNoTitle() {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        #expect(screen.navigationItem.titleView == nil)
        #expect(screen.navigationItem.title == nil, "the bar draws a title")
        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava Moreau", avatarURL: nil))
        #expect(screen.navigationItem.title == nil, "the bar draws the correspondent")
        #expect(screen.view.accessibilityLabel == "Conversation with Ava Moreau", "VoiceOver lost the correspondent")
    }

    // MARK: - The bell's transition, durations and toast (#729)

    /// ⚠️ A STATE IS ITS OWN ITEM, WITH ITS OWN IDENTIFIER: one identifier
    /// for both swaps in a frame; two get the native glass morph.
    @Test func eachBellStateIsItsOwnItemForTheGlassMorph() throws {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        let on = try #require(bell(screen))
        driver.toggleMuted()
        let off = try #require(bell(screen))
        #expect(on !== off, "the bell was edited in place: no morph")
        #expect(on.identifier != off.identifier, "one identifier for both states: no morph")
        #expect(on.identifier == ConversationThreadViewController.bellID)
        #expect(off.identifier == ConversationThreadViewController.mutedBellID)
    }

    /// A long press offers the durations; each mutes until that time.
    @Test func theLongPressMenuOffersDurations() throws {
        let (screen, _, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        let menu = try #require(bell(screen)?.menu, "the bell has no long-press menu")
        let titles = Self.leafTitles(menu)
        #expect(titles == ConversationThreadViewController.muteDurations.map(\.title))
        #expect(ConversationThreadViewController.muteDurations.map(\.seconds) == [3_600, 28_800, 86_400, 604_800, nil])
    }

    /// Muted, the menu leads with Unmute.
    @Test func aMutedBellOffersUnmuteFirst() throws {
        let (screen, _, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]), muted: true)
        defer { window.isHidden = true }
        let menu = try #require(bell(screen)?.menu)
        #expect(Self.leafTitles(menu).first == "Unmute")
    }

    private static func leafTitles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { element -> [String] in
            if let sub = element as? UIMenu { return leafTitles(sub) }
            return [element.title]
        }
    }

    /// Muting says so at the foot of the screen, as signing in does — once
    /// the server has written it (#802), never on the tap.
    @Test func muteShowsAToastOnceTheServerAnswers() throws {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        #expect(bell(screen)?.primaryAction != nil)
        screen.debugTapBell()
        #expect(driver.mutes.last?.muted == true)
        #expect(driver.mutes.last?.until == nil, "a tap mutes until turned back on")
        #expect(Self.firstToast(in: screen.view) == nil, "the mute was confirmed before the server answered")
        driver.answerMute(true)
        let toast = try #require(Self.firstToast(in: screen.view), "no toast confirmed the mute")
        #expect(toast.style == .confirmation)

        // A duration mutes until that time.
        screen.debugPickMuteDuration(0)
        let until = try #require(driver.mutes.last?.until, "a duration muted for ever")
        #expect(abs(until.timeIntervalSinceNow - 3_600) < 5)
    }

    /// A message's Copy says so (#803): the pasteboard is off-screen.
    @Test func copyingAMessageShowsACopiedToast() throws {
        let (screen, _, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        #expect(Self.firstToast(in: screen.view) == nil)
        screen.confirmCopied()
        #expect(Self.firstToast(in: screen.view)?.style == .confirmation, "the copy said nothing")
    }

    /// A refused mute puts the bell back and says it failed (#802).
    @Test func aRefusedMuteRollsBackWithAFailureToast() throws {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        screen.debugTapBell()
        #expect(bell(screen)?.image == UIImage(systemName: "bell.slash"))
        driver.answerMute(false)
        #expect(bell(screen)?.image == UIImage(systemName: "bell"), "the refused mute stayed on")
        let toast = try #require(Self.firstToast(in: screen.view), "the refusal was silent")
        #expect(toast.style == .failure)
    }

    private static func firstToast(in view: UIView) -> ToastView? {
        if let toast = view as? ToastView { return toast }
        for subview in view.subviews {
            if let toast = firstToast(in: subview) { return toast }
        }
        return nil
    }

    /// A draft has nothing to mute: no bell until there is a conversation.
    @Test func aDraftHasNoBell() {
        let (screen, driver, window) = makeScreen(phase: .content([]), muted: nil)
        defer { window.isHidden = true }
        #expect(bell(screen) == nil)
        driver.onMutedChange?(false)
        #expect(bell(screen) != nil, "the resolved conversation got no bell")
    }

    // MARK: - Sending

    /// A text on its way is faded with a spinner; delivered, plain.
    @Test func aTextOnItsWayIsFadedWithASpinner() throws {
        let sending = Self.message("p1", mine: true, minutes: 2, delivery: .sending)
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1), sending]))
        defer { window.isHidden = true }
        let row = try #require(cell("Message p1", in: screen), "the pending text is not drawn")
        #expect(row.delivery == .sending)
        #expect(abs(row.row.alpha - ThreadRowCell.sendingAlpha) < 0.01)
        #expect(row.accessibilityValue == "Sending")

        let other = try #require(cell("Message m1", in: screen))
        #expect(other.delivery == nil, "someone else's message wears a delivery")

        driver.onPhaseChange?(.content([
            Self.message("m1", mine: false, minutes: 1),
            ConversationThreadMessage(
                id: "t1", senderID: ProfileID("me"), body: "Message p1", sentAt: sending.sentAt,
                isMine: true, quote: nil
            )
        ]))
        screen.view.layoutIfNeeded()
        let delivered = try #require(cell("Message p1", in: screen))
        #expect(delivered.delivery == nil)
        #expect(cells(in: screen.view).filter { $0.row.bodyTextLabel.text == "Message p1" }.count == 1)
    }

    /// A failed text says so, and a tap sends it again rather than answering it.
    @Test func aFailedTextRetriesOnATap() throws {
        let (screen, driver, window) = makeScreen(phase: .content([
            Self.message("p1", mine: true, minutes: 2, delivery: .failed)
        ]))
        defer { window.isHidden = true }
        let row = try #require(cell("Message p1", in: screen))
        #expect(row.delivery == .failed)
        #expect(row.row.alpha == 1)
        row.row.onReplyTap?()
        #expect(driver.retried == ["p1"])
        #expect(driver.replies.isEmpty, "a failed message was answered instead of retried")
    }

    // MARK: - No flicker (#725)

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// ⚠️ Sending re-draws the sent row and nothing else: the rest of the
    /// transcript used to be reconfigured on every render — avatars back to
    /// initials, emotes restarted — and the whole screen blinked.
    @Test func sendingRedrawsOnlyTheSentRow() async throws {
        let them = Self.message("m1", mine: false, minutes: 1)
        let mine = Self.message("m2", mine: true, minutes: 2)
        let (screen, driver, window) = makeScreen(phase: .content([them, mine]))
        defer { window.isHidden = true }
        screen.debugConfiguredIDs = []

        let pending = Self.message("p1", mine: true, minutes: 3, delivery: .sending)
        driver.onPhaseChange?(.content([them, mine, pending]))
        screen.view.layoutIfNeeded()
        #expect(cell("Message p1", in: screen) != nil)

        let delivered = ConversationThreadMessage(
            id: "t1", senderID: ProfileID("me"), body: "Message p1", sentAt: pending.sentAt, isMine: true, quote: nil
        )
        driver.onPhaseChange?(.content([them, mine, delivered]))
        #expect(await settle {
            screen.view.layoutIfNeeded()
            return screen.debugConfiguredIDs.contains("t1")
        }, "the delivered message never landed")
        #expect(Set(screen.debugConfiguredIDs).isSubset(of: ["p1", "t1"]),
                "sending re-drew other rows: \(screen.debugConfiguredIDs)")

        // A real change still reaches the rows it concerns: the peer's new
        // name re-signs their messages, not the viewer's.
        screen.debugConfiguredIDs = []
        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava M.", avatarURL: nil))
        screen.view.layoutIfNeeded()
        #expect(screen.debugConfiguredIDs.contains("m1"))
        #expect(!screen.debugConfiguredIDs.contains("m2"))
        #expect(!screen.debugConfiguredIDs.contains("t1"))
    }

    /// Delivered mid bounce-in: the spinner scales out at once, on the row
    /// still rising, and the delivered row then lands plainly in its place.
    @Test func aDeliveryMidBounceScalesTheSpinnerOutAtOnce() async throws {
        let them = Self.message("m1", mine: false, minutes: 1)
        let (screen, driver, window) = makeScreen(phase: .content([them]))
        defer { window.isHidden = true }
        let pending = Self.message("p1", mine: true, minutes: 3, delivery: .sending)
        driver.onPhaseChange?(.content([them, pending]))
        screen.view.layoutIfNeeded()
        let rising = try #require(cell("Message p1", in: screen))
        #expect(rising.isBouncingInSpinner)

        driver.onPhaseChange?(.content([them, ConversationThreadMessage(
            id: "t1", senderID: ProfileID("me"), body: "Message p1", sentAt: pending.sentAt, isMine: true, quote: nil
        )]))
        #expect(rising.isScalingOutSpinner, "the spinner waited for the rise before leaving")
        #expect(!rising.isBouncingInSpinner)
        #expect(rising.row.alpha == 1)

        screen.debugConfiguredIDs = []
        #expect(await settle {
            screen.view.layoutIfNeeded()
            return screen.debugConfiguredIDs.contains("t1")
        })
        // ⚠️ A SWAP, NOT A CHANGE (#756): animated, the pending row and its
        // delivered one cross-faded — the row and its avatar dimmed.
        #expect(screen.debugLastApplyAnimated == false, "the swap cross-faded")
        let landed = try #require(cell("Message p1", in: screen))
        #expect(!landed.isScalingOutSpinner, "the delivered row played the delivery twice")
        #expect(!landed.sendingSpinnerView.isAnimating)
        #expect(landed.row.alpha == 1)
    }

    /// While the message is on its way the spinner stands in its time's
    /// place (`You · ◌`), small; delivered, it scales out and the time takes
    /// the place back.
    @Test func theSpinnerStandsInTheTimesPlaceAndScalesOut() async throws {
        let pending = Self.message("p1", mine: true, minutes: 3, delivery: .sending)
        let (screen, driver, window) = makeScreen(phase: .content([pending]))
        defer { window.isHidden = true }
        let row = try #require(cell("Message p1", in: screen))
        row.layoutIfNeeded()
        let spinner = row.sendingSpinnerView
        #expect(spinner.isAnimating)
        #expect(row.isBouncingInSpinner, "the spinner did not bounce in")
        spinner.layer.removeAllAnimations()
        let header = row.row.headerTextLabel
        #expect(header.text == "You · ", "the time shows while the message is on its way: \(header.text ?? "-")")
        let headerFrame = header.convert(header.bounds, to: row.contentView)
        let prefixWidth = ("You · " as NSString).size(withAttributes: [.font: header.font as Any]).width
        let timeStart = headerFrame.minX + prefixWidth
        #expect(abs(spinner.frame.minX - timeStart) < 2, "the spinner is not where the time goes: \(spinner.frame) vs \(timeStart)")
        #expect(abs(spinner.center.y - headerFrame.midY) < 1, "\(spinner.center) vs \(headerFrame)")
        #expect(spinner.frame.width < 14, "the spinner is a control's size, not the time's")

        driver.onPhaseChange?(.content([ConversationThreadMessage(
            id: "t1", senderID: ProfileID("me"), body: "Message p1", sentAt: pending.sentAt, isMine: true, quote: nil
        )]))
        screen.view.layoutIfNeeded()
        let delivered = try #require(cell("Message p1", in: screen))
        #expect(delivered.isScalingOutSpinner, "the spinner did not scale out on delivery")
        #expect(delivered.isBouncingInTime, "the time did not bounce in with the spinner leaving")
        #expect(await settle { !delivered.isBouncingInTime })
        let time = try #require(delivered.row.headerTextLabel.text)
        #expect(time.hasPrefix("You · ") && time.count > "You · ".count, "the time did not come back: \(time)")
    }

    // MARK: - The correspondent's @handle (#752)

    /// The pill wears the @handle under the name once it is known, as a
    /// vertical post's author pill does; nothing under it before.
    @Test func thePeerPillShowsTheHandleUnderTheName() {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava Moreau", avatarURL: nil))
        window.layoutIfNeeded()
        #expect(screen.debugPeerPillLines == ["Ava Moreau"], "\(screen.debugPeerPillLines)")
        driver.onPeerChange?(ConversationThreadPerson(
            id: ProfileID("them"), name: "Ava Moreau", avatarURL: nil, handle: "ava.moreau"
        ))
        window.layoutIfNeeded()
        #expect(screen.debugPeerPillLines == ["Ava Moreau", "@ava.moreau"], "\(screen.debugPeerPillLines)")
    }

    /// Where the viewer stands with them, and the follows asked for.
    private final class Graph: SocialGraphReading, SocialGraphWriting, @unchecked Sendable {
        var relation: FollowRelation
        var refuses = false
        /// How long a read takes — a read still out when a follow lands.
        var readDelay: Duration = .zero
        private(set) var follows: [ProfileID] = []
        init(_ relation: FollowRelation) { self.relation = relation }
        func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
            let answer = relation
            if readDelay > .zero { try? await Task.sleep(for: readDelay) }
            return answer
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {
            if refuses { throw CancellationError() }
            if following { follows.append(profileID) }
        }
    }

    private func makeScreen(graph: Graph) -> (ConversationThreadViewController, Driver, UIWindow) {
        let driver = Driver(initial: .content([Self.message("m1", mine: false, minutes: 1)]), muted: false)
        let screen = ConversationThreadViewController(
            driver: driver, mode: .full, prefill: "",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            socialGraph: graph, followRelations: graph
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, window)
    }

    /// ⚠️ A READ SENT BEFORE A FOLLOW NEVER UNDOES IT (#752): the screen
    /// re-reads on every appearance, and its answer could land after the
    /// follow it predates.
    @Test func aStaleRelationAnswerNeverUndoesAFollow() async {
        let graph = Graph(.notFollowing)
        let (screen, driver, window) = makeScreen(graph: graph)
        defer { window.isHidden = true }
        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
        #expect(await settle { screen.debugPeerFollowBadge == .follow })

        graph.readDelay = .milliseconds(300)
        screen.resolvePeerRelation(refresh: true)
        screen.followPeer(ProfileID("them"))
        #expect(await settle { graph.follows == [ProfileID("them")] })
        try? await Task.sleep(for: .milliseconds(450))
        #expect(screen.debugPeerFollowBadge == .following, "the read from before the follow put the + back")
    }

    /// A refused follow puts the "+" back — and says so (#802).
    @Test func aRefusedFollowPutsThePlusBackAndSaysSo() async {
        let graph = Graph(.notFollowing)
        graph.refuses = true
        let (screen, driver, window) = makeScreen(graph: graph)
        defer { window.isHidden = true }
        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
        #expect(await settle { screen.debugPeerFollowBadge == .follow })
        screen.followPeer(ProfileID("them"))
        #expect(screen.debugPeerFollowBadge == .following, "no optimistic follow")
        #expect(await settle { screen.debugPeerFollowBadge == .follow }, "the refusal stuck")
        #expect(Self.firstToast(in: screen.view)?.style == .failure, "the refused follow was silent")
    }

    /// The pill draws the relation as a vertical post's author pill does —
    /// someone who follows the viewer gets "+", and a tap makes friends.
    @Test func thePeerPillDrawsTheRelationAndTheFollowFollows() async {
        let graph = Graph(.followedBy)
        let (screen, driver, window) = makeScreen(graph: graph)
        defer { window.isHidden = true }

        driver.onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
        #expect(await settle { screen.debugPeerFollowBadge == .follow }, "\(screen.debugPeerFollowBadge)")

        screen.followPeer(ProfileID("them"))
        #expect(screen.debugPeerFollowBadge == .friends, "following someone who follows back is a friend")
        #expect(await settle { graph.follows == [ProfileID("them")] })
    }

    /// The rule is the post pill's own: one mapping for both.
    @Test func theRelationMapsAsOnAPost() {
        typealias Badge = SnapAuthorIdentityView.FollowBadge
        #expect(Badge(.notFollowing) == .follow)
        #expect(Badge(.following) == .following)
        #expect(Badge(.mutual) == .friends)
        #expect(Badge(.viewer) == .none)
    }
}
