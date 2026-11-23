import CoreModels
import Testing
import UIKit
@testable import PostGrid

/// The shared embed card (#2216), its channel case: the action and its words
/// per viewer state, each unavailable drawing, each size, VoiceOver, and the
/// writes through the seam its trait environment carries (#2506). Serialized
/// for `ChannelEmbedLocalState` and the cards' change notes, which are
/// process-wide.
@MainActor
@Suite(.serialized)
struct PostEmbedViewTests {
    /// A seam that answers what it is told and records what it was asked.
    @MainActor
    final class SpyActions: ChannelEmbedActing {
        var calls: [String] = []
        var answer: ChannelEmbed.ViewerState = .subscriber
        var fails = false

        func join(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("join \(id.rawValue)")
            if fails { throw CancellationError() }
            return answer
        }

        func requestToJoin(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("request \(id.rawValue)")
            if fails { throw CancellationError() }
            return answer
        }

        func cancelJoinRequest(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("cancel \(id.rawValue)")
            return answer
        }

        func open(_ id: ConversationID) { calls.append("open \(id.rawValue)") }
    }

    private func channel(
        _ state: ChannelEmbed.ViewerState, visibility: ChannelEmbed.Visibility = .public,
        availability: ChannelEmbed.Availability = .available, id: String = UUID().uuidString
    ) -> ChannelEmbed {
        ChannelEmbed(conversationID: ConversationID(id), name: "Harbour notes", description: "Boats in, boats out.",
                     subscriberCount: 12_400, visibility: visibility, viewerState: state, availability: availability,
                     lastMessagePreview: "The ferry's late again")
    }

    /// A card showing `channel`; with `actions`, carried by its own trait
    /// environment, as the app's window carries the app's (#2506).
    private func card(
        _ channel: ChannelEmbed, size: PostEmbeds.Size = .full, actions: SpyActions? = nil
    ) -> PostEmbedView {
        let view = PostEmbedView()
        if let actions { view.traitOverrides.channelEmbedActions = ChannelEmbedActionsSource(actions) }
        view.show(.channel(channel), size: size, pipeline: nil)
        return view
    }

    /// Runs `body` on a clean session record, and leaves it clean.
    private func withCleanSession(_ body: () async -> Void) async {
        ChannelEmbedLocalState.reset()
        await body()
        ChannelEmbedLocalState.reset()
    }

    // MARK: - The action per state

    @Test func theButtonFollowsTheViewersState() {
        #expect(card(channel(.none)).debugActionTitle == "Join")
        #expect(!card(channel(.none)).debugActionIsQuiet, "Join is the prominent action")
        #expect(card(channel(.none, visibility: .onRequest)).debugActionTitle == "Request to Join")
        let requested = card(channel(.requested, visibility: .onRequest))
        #expect(requested.debugActionTitle == "Requested")
        #expect(requested.debugActionIsQuiet)
        #expect(requested.debugActionOpensMenu, "Requested must offer the cancel")
        #expect(card(channel(.member)).debugActionTitle == "Open")
        #expect(card(channel(.subscriber)).debugActionTitle == "Open")
        #expect(!card(channel(.subscriber)).debugActionOpensMenu)
        #expect(card(channel(.banned)).debugActionTitle == nil, "a banned viewer got a button")
    }

    // MARK: - Unavailable

    @Test func eachUnavailableStateHasItsOwnDrawingAndNoAction() {
        let expected: [ChannelEmbed.Availability: String] = [
            .deleted: "This channel no longer exists",
            .private: "This channel is private",
            .blocked: "This channel isn't available",
        ]
        for (availability, text) in expected {
            for size in [PostEmbeds.Size.full, .compact] {
                let view = card(channel(.none, availability: availability), size: size)
                #expect(view.debugUnavailableText == text, "\(availability) \(size)")
                #expect(view.debugActionTitle == nil, "\(availability) offered an action")
                #expect(view.debugNameText == nil, "\(availability) showed the channel")
                #expect(view.debugCardLabel == text)
            }
            let mark = card(channel(.none, availability: availability), size: .mark)
            #expect(mark.debugUnavailableText == ChannelEmbedCopy.unavailableMark(availability))
        }
        let available = card(channel(.none))
        #expect(available.debugUnavailableText == nil)
    }

    // MARK: - Sizes

    @Test func fullShowsEverything() {
        let view = card(channel(.none), size: .full)
        #expect(view.debugNameText == "Harbour notes")
        #expect(view.debugCountText == "12.4K subscribers")
        #expect(view.debugDescriptionText == "Boats in, boats out.")
        #expect(view.debugLastMessageText == "The ferry's late again")
        #expect(view.debugActionTitle == "Join")
        #expect(!view.debugShowsBadge)
        #expect(view.isUserInteractionEnabled)
    }

    @Test func compactShowsPhotoNameCountAndTheAction() {
        let view = card(channel(.none), size: .compact)
        #expect(view.debugNameText == "Harbour notes")
        #expect(view.debugCountText == "12.4K subscribers")
        #expect(view.debugDescriptionText == nil)
        #expect(view.debugLastMessageText == nil)
        #expect(view.debugActionTitle == "Join")
    }

    @Test func markShowsThePhotoWithItsGlyphAndTheNameAndTakesNoTouch() {
        let view = card(channel(.none), size: .mark)
        #expect(view.debugNameText == "Harbour notes")
        #expect(view.debugShowsBadge)
        #expect(view.debugCountText == nil)
        #expect(view.debugDescriptionText == nil)
        #expect(view.debugActionTitle == nil, "a mark has no button")
        #expect(!view.isUserInteractionEnabled, "a mark took the tile's tap")
    }

    @Test func aViewShownAgainForgetsTheLastOne() {
        let view = card(channel(.none), size: .full)
        view.show(.channel(channel(.member)), size: .compact, pipeline: nil)
        #expect(view.size == .compact && view.debugActionTitle == "Open")
        view.clear()
        #expect(view.isHidden && view.embed == nil)
    }

    @Test func voiceOverReadsTheChannelAndItsCount() {
        #expect(card(channel(.none)).debugCardLabel == "Channel Harbour notes, 12.4K subscribers")
        #expect(ChannelEmbedCopy.subscriberCount(1) == "1 subscriber")
        #expect(ChannelEmbedCopy.subscriberCount(820) == "820 subscribers")
    }

    // MARK: - Taps

    @Test func joinWritesAndTheButtonTurnsToOpen() async {
        let spy = SpyActions()
        await withCleanSession {
            let view = card(channel(.none, id: "ch-harbour"), actions: spy)
            var told: PostEmbed?
            view.onEmbedChange = { told = $0 }
            view.performAction()
            await view.debugSettle()
            #expect(spy.calls == ["join ch-harbour"])
            #expect(view.debugActionTitle == "Open")
            #expect(view.embed?.channel?.viewerState == .subscriber)
            #expect(view.embed?.channel?.subscriberCount == 12_401)
            #expect(told?.channel?.viewerState == .subscriber)
            // Open opens.
            view.performAction()
            #expect(spy.calls.last == "open ch-harbour")
        }
    }

    /// SEEN ON THE SIMULATOR: the actions used to be registered when the
    /// Messages tab was built, so on a launch that opened a post first, Join
    /// did nothing. The app's source makes them on the first tap, once.
    @Test func theFirstTapMakesTheActionsOnce() async {
        let spy = SpyActions()
        var made = 0
        let source = ChannelEmbedActionsSource { made += 1; return spy }
        await withCleanSession {
            let view = PostEmbedView()
            view.traitOverrides.channelEmbedActions = source
            view.show(.channel(channel(.none, id: "ch-harbour")), size: .full, pipeline: nil)
            #expect(made == 0, "made before anyone tapped")
            view.performAction()
            await view.debugSettle()
            #expect(made == 1)
            #expect(spy.calls == ["join ch-harbour"])
            // Made once: the next tap uses them.
            view.performAction()
            #expect(made == 1)
            #expect(spy.calls.last == "open ch-harbour")
        }
    }

    /// The channels off: the source answers nothing, the tap does nothing,
    /// and it is asked again next time.
    @Test func aSourceWithNothingToActWithLeavesTheCardAlone() async {
        var asked = 0
        let source = ChannelEmbedActionsSource { asked += 1; return nil }
        await withCleanSession {
            let view = PostEmbedView()
            view.traitOverrides.channelEmbedActions = source
            view.show(.channel(channel(.none, id: "ch-off")), size: .full, pipeline: nil)
            view.performAction()
            #expect(view.debugActionTitle == "Join")
            #expect(view.embed?.channel?.viewerState == ChannelEmbed.ViewerState.none)
            view.performAction()
            #expect(asked == 2, "a nil answer was kept")
        }
    }

    /// The app's shape (#2506): the source is set on the window, and a card
    /// anywhere under it acts through it.
    @Test func aCardActsThroughTheSourceItsWindowCarries() async {
        let spy = SpyActions()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.traitOverrides.channelEmbedActions = ChannelEmbedActionsSource(spy)
        let page = UIView(frame: window.bounds)
        window.addSubview(page)
        await withCleanSession {
            let view = card(channel(.none, id: "ch-windowed"))
            page.addSubview(view)
            // What the layout pass before any finger lands does.
            window.updateTraitsIfNeeded()
            view.performAction()
            await view.debugSettle()
            #expect(spy.calls == ["join ch-windowed"], "the card did not read its window's actions")
        }
        page.removeFromSuperview()
    }

    @Test func requestThenCancel() async {
        let spy = SpyActions()
        await withCleanSession {
            let view = card(channel(.none, visibility: .onRequest, id: "ch-printroom"), actions: spy)
            spy.answer = .requested
            view.performAction()
            await view.debugSettle()
            #expect(view.debugActionTitle == "Requested")
            // A tap on Requested is its menu's, not a write.
            view.performAction()
            #expect(spy.calls == ["request ch-printroom"])
            spy.answer = .none
            view.cancelRequest()
            await view.debugSettle()
            #expect(spy.calls == ["request ch-printroom", "cancel ch-printroom"])
            #expect(view.debugActionTitle == "Request to Join")
        }
    }

    @Test func aRefusalLeavesTheCardAsItWas() async {
        let spy = SpyActions()
        spy.fails = true
        await withCleanSession {
            let view = card(channel(.none, id: "ch-refused"), actions: spy)
            view.performAction()
            await view.debugSettle()
            #expect(view.debugActionTitle == "Join")
            #expect(view.embed?.channel?.viewerState == ChannelEmbed.ViewerState.none)
        }
    }

    /// A card drawn again from a read made before the tap shows the answer;
    /// a read that moved on is believed.
    @Test func thisSessionsAnswerOutlivesTheCard() async {
        let spy = SpyActions()
        await withCleanSession {
            let stale = channel(.none, id: "ch-remembered")
            let first = card(stale, actions: spy)
            first.performAction()
            await first.debugSettle()
            #expect(card(stale).debugActionTitle == "Open", "a recycled card forgot the join")
            // The server says otherwise now (a leave elsewhere): believed.
            var left = stale
            left.viewerState = .banned
            #expect(card(left).debugActionTitle == nil)
            #expect(card(stale).debugActionTitle == "Join")
        }
    }

    // MARK: - The other taps keep their action

    /// The action button is the card's own touch; the rest of the card is
    /// the surface's (`keepsTouch`, read by the host's recognizer).
    @Test func onlyTheButtonIsTheCardsOwnTouch() {
        let view = card(channel(.none))
        #expect(PostEmbedView.ownsTouch(in: view.debugActionButton))
        #expect(!PostEmbedView.ownsTouch(in: view))
        #expect(!PostEmbedView.ownsTouch(in: UIView()))
    }

    // MARK: - The switch

    @Test func theSwitchOffShowsNoCard() {
        let embed = PostEmbed.channel(channel(.none))
        #expect(PostEmbeds.shown(embed, drawn: true) == embed)
        #expect(PostEmbeds.shown(embed, drawn: false) == nil)
    }
}
