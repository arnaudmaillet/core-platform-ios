import DesignSystem
import FeedInterface
import Testing
import UIKit
import VoiceKit
import VoiceKitUI
@testable import Feed

/// #2308: ONE composer contract for a conversation and a post's comments.
/// Each host declares only what differs (`ComposerConfiguration`: its voice,
/// its attachments, its emote panel, its column); the row, the own bubble,
/// tap to type, hold to talk and the attachments' rule are the composer's.
/// The conversation's own declaration is tested beside its attachments
/// (`ConversationRowAttachmentsTests.theConversationDeclaresItsVoiceAndItsAttachments`).
@MainActor
struct ComposerContractTests {
    private static let step = CommentsInputBar.Metrics.controlSize + Spacing.sm

    private static func source(_ index: Int) -> ComposerAttachmentSource {
        ComposerAttachmentSource(id: "test.source.\(index)", symbol: "photo", accessibilityLabel: "Source \(index)") {}
    }

    /// A bar on a window's root view, laid out.
    private func hostedBar(
        _ configuration: ComposerConfiguration, railFace: CommentsInputBar.RailFace = .repost
    ) -> (CommentsInputBar, UIView, UIWindow) {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.isHidden = false
        let bar = CommentsInputBar()
        bar.configuration = configuration
        bar.railFace = railFace
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: screen.view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: screen.view.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: screen.view.bottomAnchor, constant: -40),
        ])
        screen.view.layoutIfNeeded()
        return (bar, screen.view, window)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: - The declarations

    /// What each kind of voice records for: a message's five minutes on the
    /// clock, a comment's and a post's minute in seconds — and none.
    @Test func eachVoiceCarriesItsLimitAndItsTimer() {
        #expect(!ComposerConfiguration.Voice.none.records)
        #expect(ComposerConfiguration.Voice.message.records)
        #expect(ComposerConfiguration.Voice.message.limit == VoiceRecorder.maximumDuration)
        #expect(ComposerConfiguration.Voice.message.timerStyle == .clock)
        #expect(ComposerConfiguration.Voice.comment.limit == 60)
        #expect(ComposerConfiguration.Voice.comment.timerStyle == .seconds)
        #expect(ComposerConfiguration.Voice.post.limit == TextPostVoice.maximumDuration)
        #expect(ComposerConfiguration.Voice.post.timerStyle == .seconds)
        #expect(VoiceComposer(for: .post, draftKey: nil).recorder.limit == TextPostVoice.maximumDuration)
        #expect(VoiceComposer(for: .message, draftKey: nil).recorder.limit == VoiceRecorder.maximumDuration)
    }

    /// A post's comments: a voice comment (#2309), no attachments (#2310 is
    /// on hold), the post's column; in the sheet, no column. A fresh
    /// composer is a post's comments.
    @Test func theCommentsDeclareAVoiceCommentAndNoAttachments() {
        for contract in [ComposerConfiguration.comments, .commentsSheet] {
            #expect(contract.voice == .comment)
            #expect(contract.attachments.isEmpty)
            #expect(contract.emote == .emotes)
        }
        #expect(ComposerConfiguration.comments.column == .post)
        #expect(ComposerConfiguration.commentsSheet.column == .none)
        #expect(CommentsInputBar().configuration.laysOutLike(.comments))
    }

    // MARK: - A post's comments

    /// On the post screens the comments composer is the one composer, from
    /// the comments' contract. From a source that carries no voice (#2309:
    /// `commentsVoice`) — this panel has none — no hold, no voice promised,
    /// and no waveform: the field holds the emote button alone, the own
    /// bubble the rest.
    @Test func thePostsComposerWithoutAVoiceSourceHasNoVoiceAndNoInlineWaveform() throws {
        let (controller, window) = SnapActionColumnLayoutTests.engagedPanel()
        defer { window.isHidden = true }
        let bar = controller.composeBar
        bar.onVoiceHold = { _ in }
        #expect(bar.configuration.column == .post && bar.configuration.attachments.isEmpty)
        #expect(bar.configuration.voice == .none, "a source with no voice records one")
        #expect(controller.voiceComposer == nil)
        #expect(!bar.speaksFromField)
        #expect(!bar.debugFieldHoldBegins, "a comment's field records")
        #expect(bar.debugPlaceholder != CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions == nil, "VoiceOver offers a voice")
        #expect(bar.debugAttachmentItems.isEmpty && bar.debugAttachmentBar == nil)
        let buttons = Self.descendants(of: bar).compactMap { $0 as? UIButton }
        #expect(!buttons.contains { $0.accessibilityLabel == "Record voice comment" }, "a voice that doesn't work")
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        #expect(Self.descendants(of: field).compactMap { $0 as? UIButton }.allSatisfy { $0 === bar.debugEmoteToggle },
                "a button in the field besides the emote button")
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.emoteSymbol)
        bar.draftText = "Nice one"
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.sendSymbol)
    }

    /// No input row — a showcase that takes no comments (#2216) — no own
    /// bubble either: it is the row's.
    @Test func withoutTheInputRowTheOwnBubbleGoesToo() {
        let bar = CommentsInputBar()
        #expect(bar.debugShowsRowAction)
        bar.takesComments = false
        #expect(!bar.debugShowsInputRow)
        #expect(!bar.debugShowsRowAction, "an own bubble beside no field")
        bar.takesComments = true
        #expect(bar.debugShowsRowAction)
    }

    /// The comments sheet (#2087) declares no column: no stake, no slot,
    /// whatever the page later asks, and the own bubble ends the row at the
    /// bar's edge.
    @Test func theSheetsComposerHasNoColumn() throws {
        let (controller, window) = SnapActionColumnLayoutTests.engagedPanel()
        defer { window.isHidden = true }
        controller.setComposerBare()
        let bar = controller.composeBar
        #expect(bar.configuration.column == .none && bar.configuration.attachments.isEmpty)
        // The sheet's voice is the page's (#2309): none from this source.
        #expect(bar.configuration.voice == controller.commentsVoice)
        #expect(!bar.showsStake && bar.railFace == .noSlot && !bar.showsPostActions)
        // A page's later asks do not bring the column back.
        bar.showsStake = true
        bar.railFace = .repost
        bar.showsPostActions = true
        #expect(!bar.showsStake && bar.railFace == .noSlot && !bar.showsPostActions)
        controller.view.layoutIfNeeded()
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton.frame
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar)).frame
        #expect(abs(bubble.maxX - bar.bounds.maxX) < 0.5, "the own bubble \(bubble) short of the bar's end")
        #expect(abs(bubble.minX - (field.maxX + Spacing.sm)) < 0.5)
        #expect(bar.debugRailButton.isHidden)
    }

    /// The own bubble stands between the field and a post's slot at rest,
    /// and rides the keyboard into the slot's room as the row clears the
    /// column — which never moves.
    @Test func theOwnBubbleRidesTheKeyboardBesideAStillColumn() throws {
        let (bar, host, window) = hostedBar(.comments)
        defer { window.isHidden = true }
        let rail = bar.debugRailButton
        let bubble = bar.debugRowActionButton
        let keyboard = SnapActionColumnLayoutTests.fakeKeyboard(in: host, for: bar, top: host.bounds.height + 80)
        host.layoutIfNeeded()
        let restRail = rail.convert(rail.bounds, to: host)
        #expect(abs(bubble.frame.maxX - (rail.frame.minX - Spacing.sm)) < 0.5, "own bubble \(bubble.frame), slot \(rail.frame)")
        #expect(abs(bubble.frame.maxY - rail.frame.maxY) < 0.5, "the own bubble is off the slot's line")

        keyboard.constant = bar.frame.minY - 200
        SnapActionColumnLayoutTests.relayout(host, bar)
        #expect(bar.riseProgress == 1)
        #expect(abs(bubble.frame.maxX - bar.bounds.maxX) < 0.5, "the risen bubble did not take the slot's room")
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        #expect(abs(bubble.frame.maxY - field.frame.maxY) < 0.5, "the bubble stayed under the keyboard")
        #expect(rail.convert(rail.bounds, to: host) == restRail, "the column moved")
    }

    // MARK: - The attachments, any number

    /// A list of ANY length — none, one, the conversation's two, more — is
    /// ONE capsule between the field and the own bubble (#2344): the
    /// toolbar's stock items in the list's order, a separator, then the
    /// anchor under the own bubble; the field ends `sm` short of the
    /// capsule's room. A draft folds the capsule into the own bubble — the
    /// anchor alone — and the field takes its room, the own bubble never
    /// moving. On a post's composer (with its column) as on a
    /// conversation's.
    @Test(arguments: [ComposerConfiguration.Column.post, .none])
    func anAttachmentListOfAnyLengthIsOneCapsuleThatFoldsWithADraft(column: ComposerConfiguration.Column) throws {
        for count in 0...4 {
            let contract = ComposerConfiguration(attachments: (0..<count).map(Self.source), column: column)
            let (bar, host, window) = hostedBar(contract)
            defer { window.isHidden = true }
            let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
            let items = bar.debugAttachmentItems
            #expect(items.count == count)
            #expect(items.map(\.identifier) == (0..<count).map { "test.source.\($0)" })
            #expect(items.map(\.accessibilityIdentifier) == (0..<count).map { "test.source.\($0)" })
            #expect(items.allSatisfy { $0.customView == nil && $0.primaryAction != nil }, "a capsule glyph that is not a stock item")
            let bubble = bar.debugRowActionButton.frame
            let capsule = count > 0 ? ComposerAttachmentToolbar.capsuleWidth(count: count) + Spacing.sm : 0
            #expect(abs(bubble.minX - (field.frame.maxX + Spacing.sm + capsule)) < 0.5,
                    "\(count) of \(column): the own bubble \(bubble) vs the field \(field.frame)")
            #expect(bar.debugShowsAttachments == (count > 0))
            if count == 0 {
                #expect(bar.debugAttachmentBar == nil, "a toolbar with nothing to hold")
                continue
            }
            let toolbar = try #require(bar.debugAttachmentBar)
            let rest = try #require(toolbar.items)
            #expect(rest.filter { $0.identifier != nil }.map(\.identifier)
                    == items.map(\.identifier) + [ComposerAttachmentToolbar.ownBubbleID])

            let fieldAtRest = field.frame.maxX
            bar.draftText = "Hello"
            SnapActionColumnLayoutTests.relayout(host, bar)
            #expect(!bar.debugShowsAttachments, "\(count): shown beside a draft")
            #expect(toolbar.items?.compactMap(\.identifier) == [ComposerAttachmentToolbar.ownBubbleID],
                    "\(count): the capsule did not fold into the own bubble")
            #expect(abs(field.frame.maxX - (fieldAtRest + capsule)) < 0.5, "\(count): the field did not take their room")
            #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "\(count): the own bubble moved")

            bar.draftText = ""
            SnapActionColumnLayoutTests.relayout(host, bar)
            #expect(bar.debugShowsAttachments, "\(count): an emptied field did not give them back")
            #expect(toolbar.items?.compactMap(\.identifier) == rest.compactMap(\.identifier))
            #expect(abs(field.frame.maxX - fieldAtRest) < 0.5)
        }
    }

    /// A host's new list — an entry added — rebuilds the capsule in place;
    /// the composer names no kind of media, it draws what the list says.
    @Test func aNewEntryIsOneMoreGlyphInTheCapsule() {
        let bar = CommentsInputBar()
        bar.configuration.attachments = [Self.source(0)]
        let first = bar.debugAttachmentItems.first
        bar.configuration.attachments = [Self.source(0), Self.source(1)]
        #expect(bar.debugAttachmentItems.count == 2)
        #expect(bar.debugAttachmentItems.first !== first, "an entry added rebuilds the capsule")
        #expect(bar.debugAttachmentItems.map(\.accessibilityLabel) == ["Source 0", "Source 1"])
        bar.configuration.attachments = []
        #expect(bar.debugAttachmentItems.isEmpty)
        #expect(bar.debugAttachmentBar == nil)
    }

    // MARK: - Voice, where a host declares it

    /// Turned on (a text post's draft records a voice post, #2209; a post's
    /// comments a voice comment, #2309): the field's hold begins over an empty field
    /// at rest, the field says so and VoiceOver offers it under the host's
    /// wording; turned off, all of it goes.
    @Test func aDeclaredVoiceTurnsTheHoldOnAndOff() {
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        bar.onVoiceHold = { _ in }
        bar.configuration.voice = .post
        bar.layoutIfNeeded()
        #expect(bar.speaksFromField)
        #expect(bar.debugFieldHoldBegins)
        #expect(bar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions?.map(\.name) == ["Record voice post"])
        #expect(bar.debugRowActionButton.accessibilityLabel == "Emotes", "the bubble at rest is the emote button")

        bar.configuration.voice = .none
        #expect(!bar.speaksFromField)
        #expect(!bar.debugFieldHoldBegins)
        #expect(bar.debugPlaceholder != CommentsInputBar.speakOrWritePlaceholder)
        #expect(bar.debugTextView.accessibilityCustomActions == nil)
    }
}
