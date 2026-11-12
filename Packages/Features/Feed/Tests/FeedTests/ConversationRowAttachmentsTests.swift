import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
import VoiceKit
@testable import Feed

/// #2305: on a conversation's screen the camera and the library stand in the
/// composer's row, between the field and the own bubble; the pin and the
/// bell left the top bar for the footer. #2344: the camera and the library
/// are ONE glass capsule (a horizontal `SnapGlassColumn`) that folds into the own
/// bubble while the reader writes, and the pin and the bell share one
/// platter, `[peer pill] … [pin · bell] [⋯]`.
@MainActor
struct ConversationRowAttachmentsTests {
    private final class Driver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onMutedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?
        var onGroupChange: ((ConversationThreadGroup?) -> Void)?

        let sendsMedia: Bool
        let sendsVoice: Bool
        /// Nil: a draft conversation, nothing to pin or mute yet.
        var pinned: Bool?
        var muted: Bool?
        private(set) var picked: [ConversationThreadMediaSource] = []
        private(set) var pinToggles = 0
        private(set) var mutes: [Bool] = []

        init(sendsMedia: Bool = true, sendsVoice: Bool = false, pinned: Bool? = false, muted: Bool? = false) {
            self.sendsMedia = sendsMedia
            self.sendsVoice = sendsVoice
            self.pinned = pinned
            self.muted = muted
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPinnedChange?(pinned)
            onMutedChange?(muted)
            onPhaseChange?(.content([
                ConversationThreadMessage(
                    id: "m1", senderID: ProfileID("them"), body: "Hi", sentAt: Date(), isMine: false, quote: nil
                ),
            ]))
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) {}
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {
            pinToggles += 1
            guard let pinned else { return }
            self.pinned = !pinned
            onPinnedChange?(self.pinned)
        }
        func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (Bool) -> Void) {
            mutes.append(muted)
            self.muted = muted
            onMutedChange?(muted)
            completion(true)
        }
        func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) {
            picked.append(source)
        }
    }

    private func makeScreen(
        _ driver: Driver = Driver(), mode: ConversationThreadMode = .full
    ) -> (ConversationThreadViewController, UIWindow) {
        let screen = ConversationThreadViewController(
            driver: driver, mode: mode, prefill: "", imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, window)
    }

    private static let step = CommentsInputBar.Metrics.controlSize + Spacing.sm

    // MARK: - The composer's row

    /// The capsule's glass and its glyphs, in the bar's space.
    private static func capsule(of bar: CommentsInputBar) throws -> (glass: CGRect, glyphs: [CGRect]) {
        let column = try #require(bar.debugAttachmentColumn)
        let glyphs = bar.debugAttachmentButtons.map { $0.convert($0.bounds, to: bar) }
        let shapes = column.debugShapes.map { column.convert($0, to: bar) }
        // The capsule is the shape holding the glyphs; the other is the
        // anchor, on the own bubble's place.
        let glass = try #require(shapes.first { shape in glyphs.allSatisfy { shape.insetBy(dx: -0.5, dy: -0.5).contains($0) } })
        return (glass, glyphs)
    }

    /// `[avatar][field][📷 🖼][☺]`, hosted as the screen hosts it: ONE glass
    /// capsule holding both glyphs — each a row-high square, a 45 pt target —
    /// that stays clear of the field and of its text, and ends `sm` short of
    /// the own bubble; the column's anchor stands on the own bubble, drawn as
    /// a point under it.
    @Test func theCameraAndTheLibraryShareOneCapsuleBeforeTheOwnBubble() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.layoutIfNeeded()
        #expect(bar.debugShowsAttachments)
        let buttons = bar.debugAttachmentButtons
        try #require(buttons.count == 2)
        #expect(buttons.map(\.accessibilityLabel) == ["Camera", "Photo Library"])
        #expect(buttons.allSatisfy { $0.isAccessibilityElement && $0.window != nil })
        let column = try #require(bar.debugAttachmentColumn)
        #expect(column.debugShapes.count == 2, "not one capsule and the anchor: \(column.debugShapes)")

        let (glass, glyphs) = try Self.capsule(of: bar)
        let side = CommentsInputBar.Metrics.controlSize
        let field = bar.inputRowView.frame
        let own = bar.debugRowActionButton.frame
        for glyph in glyphs {
            #expect(abs(glyph.width - side) < 0.5 && abs(glyph.height - side) < 0.5 && glyph.width >= 44, "\(glyph)")
        }
        #expect(abs(glyphs[1].minX - glyphs[0].maxX) < 0.5, "the glyphs are not one capsule's: \(glyphs)")
        #expect(abs(glass.width - 2 * side) < 0.5 && abs(glass.height - side) < 0.5, "the capsule \(glass)")
        // 1. Clear of the field.
        #expect(!glass.intersects(field.insetBy(dx: 0.5, dy: 0.5)), "the capsule \(glass) covers the field \(field)")
        #expect(abs(glass.minX - (field.maxX + Spacing.sm)) < 1, "the capsule \(glass), the field \(field)")
        // 2. `sm` short of the own bubble, on its line.
        #expect(abs(glass.maxX - (own.minX - Spacing.sm)) < 1, "the capsule \(glass), the own bubble \(own)")
        #expect(abs(glass.midY - own.midY) < 1, "the capsule \(glass) off the own bubble's line \(own)")
        // 3. The field's text untouched.
        let text = bar.debugTextView.convert(bar.debugTextView.bounds, to: bar)
        #expect(!glass.intersects(text.insetBy(dx: 0.5, dy: 0.5)), "the capsule \(glass) covers the text \(text)")
        // The anchor on the own bubble, drawn as a point inside it.
        let anchor = try #require(column.debugShapes.map { column.convert($0, to: bar) }.first { $0 != glass })
        #expect(abs(anchor.midX - own.midX) < 1 && abs(anchor.midY - own.midY) < 1, "the anchor \(anchor), the own bubble \(own)")
        let drawn = column.debugDrawnShapes.map { column.convert($0, to: bar) }
        #expect(drawn.contains { $0.width <= 2 && own.contains(CGPoint(x: $0.midX, y: $0.midY)) },
                "the anchor's glass is not a point under the own bubble: \(drawn)")
        #expect(abs(bar.debugFieldTrailingInset - (Self.step + 2 * side + Spacing.sm)) < 0.5)
    }

    /// A draft folds the capsule into the own bubble — the anchor alone —
    /// keyboard down or not, and the field takes its room; the own bubble
    /// never moves. Emptied, the capsule comes back out of it.
    @Test func aDraftFoldsTheCapsuleIntoTheOwnBubble() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton.frame
        let column = try #require(bar.debugAttachmentColumn)
        try #require(bar.debugShowsAttachments)
        let (rest, _) = try Self.capsule(of: bar)

        bar.draftText = "On my way"
        bar.layoutIfNeeded()
        #expect(!bar.debugShowsAttachments, "a draft narrowed the field")
        #expect(column.debugShapes.count == 1, "writing left more than the own bubble's anchor: \(column.debugShapes)")
        #expect(bar.debugAttachmentButtons.allSatisfy { !$0.isAccessibilityElement }, "hidden, still VoiceOver elements")
        #expect(abs(bar.debugFieldTrailingInset - Self.step) < 0.5, "the field did not take their room")
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")
        let tapPoint = CGPoint(x: rest.midX, y: rest.midY)
        #expect(column.hitTest(bar.convert(tapPoint, to: column), with: nil) == nil, "the folded capsule took the field's touch")

        bar.draftText = ""
        bar.layoutIfNeeded()
        #expect(bar.debugShowsAttachments, "an emptied field at rest did not give them back")
        #expect(column.debugShapes.count == 2)
        #expect(bar.debugAttachmentButtons.allSatisfy { $0.isAccessibilityElement })
        #expect(abs(bar.debugFieldTrailingInset - (Self.step + 2 * CommentsInputBar.Metrics.controlSize + Spacing.sm)) < 0.5)
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")
    }

    /// On screen, the capsule goes and comes by the glass column's fold;
    /// under Reduce Motion it cross-fades, the field at once.
    @Test func theFoldIsTheGlassColumnsAndReduceMotionCrossFades() throws {
        let previous = MotionPreference.appReducesMotion
        defer { MotionPreference.appReducesMotion = previous }
        for reduces in [false, true] {
            MotionPreference.appReducesMotion = reduces
            let (screen, window) = makeScreen()
            defer { window.isHidden = true }
            let bar = screen.debugComposeBar
            window.layoutIfNeeded()
            bar.layoutIfNeeded()
            let motions = bar.debugAttachmentMotions
            bar.draftText = "Hi"
            #expect(bar.debugAttachmentMotions == motions + 1)
            let expected: CommentsInputBar.AttachmentChange = MotionPreference.reducesMotion ? .crossFaded : .folded
            #expect(bar.debugAttachmentChange == expected, "reduces \(reduces): \(bar.debugAttachmentChange)")
            if MotionPreference.reducesMotion {
                // The field at once: no spring left on its frame.
                #expect(abs(bar.debugFieldTrailingInset - Self.step) < 0.5)
            }
            bar.draftText = ""
            #expect(bar.debugAttachmentChange == expected)
            #expect(bar.debugShowsAttachments)
        }
    }

    /// The column's shapes per state: the capsule `sm` before the anchor and
    /// the anchor on the own bubble's place at rest; the anchor alone while
    /// writing or without sources; mirrored right to left.
    @Test func theCapsulesShapesPerState() {
        let side: CGFloat = 45
        let width = CommentsInputBar.attachmentColumnWidth(count: 2)
        #expect(width == 2 * side + Spacing.sm + side)
        let rest = CommentsInputBar.attachmentShapes(
            ids: ["a", "b"], shows: true, width: width, side: side, gap: Spacing.sm, rightToLeft: false
        )
        #expect(rest.map { $0.map(\.id) } == [["a", "b"], [CommentsInputBar.ownBubbleAnchorID]])
        #expect(rest[0].map(\.frame) == [
            CGRect(x: 0, y: 0, width: side, height: side), CGRect(x: side, y: 0, width: side, height: side),
        ])
        #expect(rest[1][0].frame == CGRect(x: width - side, y: 0, width: side, height: side))
        let writing = CommentsInputBar.attachmentShapes(
            ids: ["a", "b"], shows: false, width: width, side: side, gap: Spacing.sm, rightToLeft: false
        )
        #expect(writing.map { $0.map(\.id) } == [[CommentsInputBar.ownBubbleAnchorID]])
        let none = CommentsInputBar.attachmentShapes(
            ids: [], shows: true, width: width, side: side, gap: Spacing.sm, rightToLeft: false
        )
        #expect(none.count == 1)
        let mirrored = CommentsInputBar.attachmentShapes(
            ids: ["a", "b"], shows: true, width: width, side: side, gap: Spacing.sm, rightToLeft: true
        )
        #expect(mirrored[1][0].frame.minX == 0)
        #expect(mirrored[0].map(\.frame.minX) == [side + Spacing.sm + side, side + Spacing.sm], "b is the own bubble's neighbour")
    }

    /// A voice take is the row's: they go while it shows, and come back
    /// after it.
    @Test func aVoiceTakeHidesThem() {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.showVoiceOverlay(VoiceRecordingStrip())
        #expect(!bar.debugShowsAttachments, "the attachments stood beside a take")
        bar.showVoiceOverlay(nil)
        #expect(bar.debugShowsAttachments)
    }

    /// Messenger's rule, the contract's one for every host's list (#2308):
    /// shown only while the reader is not writing — not while the field is
    /// edited, nor while the draft holds anything (text, a voice take, later
    /// an attachment), and never without sources.
    @Test func theRuleHidesThemWhileTheReaderWrites() {
        let rule = CommentsInputBar.showsAttachments
        #expect(rule(true, false, []))
        #expect(!rule(true, true, []), "shown while the field is edited")
        #expect(!rule(true, false, .text), "shown beside a draft")
        #expect(!rule(true, false, .voiceTake), "shown beside a voice take")
        #expect(!rule(true, false, .attachments), "shown beside a picked attachment")
        #expect(!rule(true, false, [.text, .attachments]))
        #expect(!rule(false, false, []), "shown with no sources")
    }

    /// Each hands its own source to the driver, ending editing first.
    @Test func eachPicksItsSourceThroughTheDriver() {
        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let buttons = screen.debugComposeBar.debugAttachmentButtons
        buttons.last?.sendActions(for: .primaryActionTriggered)
        buttons.first?.sendActions(for: .primaryActionTriggered)
        #expect(driver.picked == [.library, .camera])
    }

    /// None where the footer offered none: a driver that sends no media, a
    /// channel's reader (#2215). A group the viewer posts in keeps them.
    @Test func noneForATextOnlyDriverOrAChannelsReader() {
        let (textOnly, textWindow) = makeScreen(Driver(sendsMedia: false))
        defer { textWindow.isHidden = true }
        #expect(textOnly.debugComposeBar.debugAttachmentButtons.isEmpty)

        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12 members", members: [:], isChannel: false
        ))
        #expect(screen.debugComposeBar.debugAttachmentButtons.count == 2, "a group's member lost the camera")
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12.4K subscribers", members: [:],
            isChannel: true, readerStanding: .subscribed
        ))
        #expect(screen.debugComposeBar.debugAttachmentButtons.isEmpty, "a channel's reader can attach")
    }

    /// A preview has no composer, so nothing to attach from.
    @Test func aPreviewHasNoAttachments() {
        let (screen, window) = makeScreen(mode: .preview)
        defer { window.isHidden = true }
        #expect(screen.toolbarItems?.isEmpty ?? true)
        #expect(!Self.contains(CommentsInputBar.self, in: screen.view))
    }

    /// The post's composer declares none (#2308: `ComposerConfiguration
    /// .comments`). The same list declared by comments later (#2310) shows
    /// with no change to the composer — the column stays.
    @Test func thePostsComposerHasNoAttachments() {
        let post = CommentsInputBar()
        #expect(post.configuration.attachments.isEmpty)
        #expect(post.debugAttachmentButtons.isEmpty)
        #expect(!post.debugShowsAttachments)

        post.configuration.attachments = [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") {},
        ]
        #expect(post.debugAttachmentButtons.count == 1)
        #expect(post.debugShowsAttachments)
        #expect(post.configuration.column == .post)
    }

    /// The same entries with new actions keep their bubbles; a tap runs the
    /// newest action.
    @Test func newActionsKeepTheBubbles() {
        let bar = CommentsInputBar()
        let taps = Taps()
        bar.configuration = .conversation(voice: .none, attachments: [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") { taps.names.append("old") },
        ])
        let button = bar.debugAttachmentButtons.first
        bar.configuration = .conversation(voice: .none, attachments: [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") { taps.names.append("new") },
        ])
        #expect(bar.debugAttachmentButtons.first === button, "the glyph was rebuilt for a new action")
        button?.sendActions(for: .primaryActionTriggered)
        #expect(taps.names == ["new"])
    }

    // MARK: - The contract (#2308)

    /// A conversation builds the one composer from its contract: a message's
    /// voice (five minutes) where its driver sends voice, `[camera, library]`,
    /// no column — and its recorder takes the declared limit.
    @Test func theConversationDeclaresItsVoiceAndItsAttachments() {
        let (screen, window) = makeScreen(Driver(sendsVoice: true))
        defer { window.isHidden = true }
        let contract = screen.debugComposeBar.configuration
        #expect(contract.voice == .message)
        #expect(contract.voice.limit == VoiceRecorder.maximumDuration)
        #expect(contract.voice.limit == 5 * 60)
        #expect(contract.attachments.map(\.id) == [ConversationThreadViewController.cameraID, ConversationThreadViewController.libraryID])
        #expect(contract.column == .none)
        #expect(contract.emote == .emotes)
        #expect(screen.debugComposeBar.speaksFromField)
        #expect(screen.debugComposeBar.debugPlaceholder == CommentsInputBar.speakOrWritePlaceholder)
        #expect(screen.voiceComposer?.recorder.limit == VoiceRecorder.maximumDuration)

        // A driver that sends no voice: the field does not record, and
        // nothing says it does.
        let (quiet, quietWindow) = makeScreen(Driver(sendsVoice: false))
        defer { quietWindow.isHidden = true }
        #expect(quiet.debugComposeBar.configuration.voice == .none)
        #expect(!quiet.debugComposeBar.speaksFromField)
        #expect(quiet.voiceComposer == nil)
        #expect(quiet.debugComposeBar.debugPlaceholder != CommentsInputBar.speakOrWritePlaceholder)
    }

    // MARK: - The footer

    /// `[peer pill] … [pin · bell] [⋯]` (#2344): the pin and the bell are
    /// neighbours — no separator, so the bar makes one platter of them — and
    /// ⋯ keeps its own bubble behind a separator; the top bar holds neither
    /// the pin nor the bell.
    @Test func thePinAndTheBellShareOnePlatterOnTheFooter() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        #expect(items.compactMap(\.identifier) == [
            "conversation.peer-pill", "conversation.pin", ConversationThreadViewController.bellID, SnapFooterToolbar.ID.more,
        ])
        let pin = try #require(items.firstIndex { $0.identifier == "conversation.pin" })
        let bell = try #require(items.firstIndex { $0.identifier == ConversationThreadViewController.bellID })
        let more = try #require(items.firstIndex { $0.identifier == SnapFooterToolbar.ID.more })
        // No separator between the pin and the bell; one — no identifier, no
        // view — before ⋯.
        #expect(bell == pin + 1 && more == bell + 2, "\(items.map { $0.identifier ?? "·" })")
        let gap = items[bell + 1]
        #expect(gap.identifier == nil && gap.customView == nil && gap.primaryAction == nil)
        #expect(items[pin].image == UIImage(systemName: "pin"))
        #expect(items[bell].image == UIImage(systemName: "bell"))
        #expect(items[pin].accessibilityLabel == "Pin conversation")
        #expect(items[bell].accessibilityLabel == "Notifications")

        let top = screen.navigationItem.rightBarButtonItems ?? []
        #expect(!top.contains { $0.identifier == "conversation.pin" || $0.identifier == ConversationThreadViewController.bellID })
        #expect(screen.debugMuteItem === items[bell])
    }

    /// A draft conversation: the pin drawn, disabled; no bell until there is
    /// a conversation to mute.
    @Test func aDraftsFooterHasAQuietPinAndNoBell() throws {
        let driver = Driver(pinned: nil, muted: nil)
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        #expect(items.compactMap(\.identifier) == ["conversation.peer-pill", "conversation.pin", SnapFooterToolbar.ID.more])
        #expect(screen.debugPinItem.isEnabled == false)
        #expect(screen.debugMuteItem == nil)

        driver.onPinnedChange?(false)
        driver.onMutedChange?(false)
        #expect(screen.debugPinItem.isEnabled)
        #expect(screen.debugMuteItem != nil, "the resolved conversation got no bell")
    }

    /// Pin and Mute from the footer go to the same driver actions as from
    /// the top bar; the glyphs follow — the bell's in place, one item.
    @Test func pinAndMuteFromTheFooterCallTheDriver() throws {
        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        let pin = try #require(items.first { $0.identifier == "conversation.pin" })
        let bell = try #require(items.first { $0.identifier == ConversationThreadViewController.bellID })

        pin.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.pinToggles == 1)
        #expect(pin.image == UIImage(systemName: "pin.fill"))
        #expect(pin.accessibilityLabel == "Unpin conversation")

        bell.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.mutes == [true])
        let after = try #require(screen.toolbarItems?.first { $0.identifier == ConversationThreadViewController.bellID })
        #expect(after === bell, "a new item per state")
        #expect(after.image == UIImage(systemName: "bell.slash"))
        #expect(after.accessibilityValue == "Muted")
    }

    @MainActor private final class Taps {
        var names: [String] = []
    }

    private static func contains<T: UIView>(_ type: T.Type, in view: UIView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { contains(type, in: $0) }
    }
}
