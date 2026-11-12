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
/// are ONE capsule (a standalone toolbar's platter) that folds into the own
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

    /// `[avatar][field][📷 🖼][☺]`: the camera and the library are ONE
    /// capsule — two stock items the toolbar joins in one platter — then a
    /// separator and the anchor, which stands exactly under the own bubble;
    /// the field ends `sm` short of the capsule's room.
    @Test func theCameraAndTheLibraryShareOneCapsuleBeforeTheOwnBubble() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.layoutIfNeeded()
        let toolbar = try #require(bar.debugAttachmentBar)
        #expect(bar.debugShowsAttachments)
        let items = try #require(toolbar.items)
        let camera = try #require(items.firstIndex { $0.identifier == ConversationThreadViewController.cameraID })
        let library = try #require(items.firstIndex { $0.identifier == ConversationThreadViewController.libraryID })
        let anchor = try #require(items.firstIndex { $0.identifier == ComposerAttachmentToolbar.ownBubbleID })
        // Neighbours, so the bar makes one platter of them; a separator — no
        // identifier, no view — keeps the anchor apart.
        #expect(library == camera + 1 && anchor == library + 2, "\(items.map { $0.identifier ?? "·" })")
        let gap = items[library + 1]
        #expect(gap.identifier == nil && gap.customView == nil && gap.primaryAction == nil)
        for item in [items[camera], items[library]] {
            #expect(item.customView == nil, "a capsule glyph that is not a stock item")
            #expect(item.primaryAction != nil)
        }
        #expect(items[camera].accessibilityLabel == "Camera")
        #expect(items[library].accessibilityLabel == "Photo Library")
        // The anchor: the own bubble's place, no bubble of the bar's around it.
        #expect(items[anchor].customView === toolbar.anchorView)
        #expect(items[anchor].hidesSharedBackground)
        #expect(!toolbar.anchorView.isAccessibilityElement)

        let own = bar.debugRowActionButton
        let field = bar.inputRowView.frame
        let capsule = ComposerAttachmentToolbar.capsuleWidth(count: 2)
        #expect(abs(bar.debugFieldTrailingInset - (Self.step + capsule + Spacing.sm)) < 0.5)
        #expect(abs(own.frame.minX - (field.maxX + capsule + 2 * Spacing.sm)) < 0.5, "own bubble \(own.frame), field \(field)")
        // The anchor under the own bubble, whatever the toolbar's margins —
        // read once both levels are laid out: the toolbar places its items
        // in its own pass, after the bar's, and the bar follows it.
        toolbar.layoutIfNeeded()
        bar.layoutIfNeeded()
        toolbar.layoutIfNeeded()
        let anchorView = toolbar.anchorView
        let anchorCentre = anchorView.convert(CGPoint(x: anchorView.bounds.midX, y: anchorView.bounds.midY), to: bar)
        // What the alignment did, oldest first: printed so a failing run
        // says whether it bailed (and why) or applied a correction.
        let trail = bar.debugAnchorAlignments.joined(separator: "\n  ")
        print("[#2344] anchor alignments:\n  \(trail)")
        #expect(bar.debugAnchorAlignments.contains { $0.hasPrefix("applied") },
                "the anchor was never aligned:\n  \(trail)")
        #expect(abs(anchorCentre.x - own.frame.midX) < 1 && abs(anchorCentre.y - own.frame.midY) < 1,
                "the anchor \(anchorCentre) is off the own bubble \(own.frame):\n  \(trail)")
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
        let toolbar = try #require(bar.debugAttachmentBar)
        try #require(bar.debugShowsAttachments)
        let rest = try #require(toolbar.items)

        bar.draftText = "On my way"
        bar.layoutIfNeeded()
        #expect(!bar.debugShowsAttachments, "a draft narrowed the field")
        #expect(toolbar.items?.compactMap(\.identifier) == [ComposerAttachmentToolbar.ownBubbleID],
                "writing left more than the own bubble")
        #expect(!toolbar.showsSources)
        #expect(abs(bar.debugFieldTrailingInset - Self.step) < 0.5, "the field did not take their room")
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")
        let tapPoint = CGPoint(x: bar.inputRowView.frame.maxX - 20, y: bar.inputRowView.frame.midY)
        #expect(toolbar.hitTest(bar.convert(tapPoint, to: toolbar), with: nil) == nil, "the folded toolbar took the field's touch")

        bar.draftText = ""
        bar.layoutIfNeeded()
        #expect(bar.debugShowsAttachments, "an emptied field at rest did not give them back")
        #expect(toolbar.items?.map(\.identifier) == rest.map(\.identifier))
        #expect(zip(toolbar.items ?? [], rest).allSatisfy { $0 === $1 }, "the capsule's items were rebuilt")
        #expect(abs(bar.debugFieldTrailingInset - (Self.step + ComposerAttachmentToolbar.capsuleWidth(count: 2) + Spacing.sm)) < 0.5)
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")
    }

    /// On screen, the capsule goes and comes by the toolbar's own fold;
    /// under Reduce Motion it cross-fades, the field at once.
    @Test func theFoldIsTheToolbarsAndReduceMotionCrossFades() throws {
        let previous = MotionPreference.appReducesMotion
        defer { MotionPreference.appReducesMotion = previous }
        for reduces in [false, true] {
            MotionPreference.appReducesMotion = reduces
            let (screen, window) = makeScreen()
            defer { window.isHidden = true }
            let bar = screen.debugComposeBar
            window.layoutIfNeeded()
            bar.layoutIfNeeded()
            let toolbar = try #require(bar.debugAttachmentBar)
            let motions = bar.debugAttachmentMotions
            bar.draftText = "Hi"
            #expect(bar.debugAttachmentMotions == motions + 1)
            let expected: ComposerAttachmentToolbar.Change = MotionPreference.reducesMotion ? .crossFaded : .folded
            #expect(toolbar.lastChange == expected, "reduces \(reduces): \(toolbar.lastChange)")
            if MotionPreference.reducesMotion {
                // The field at once: no spring left on its frame.
                #expect(abs(bar.debugFieldTrailingInset - Self.step) < 0.5)
            }
            bar.draftText = ""
            #expect(toolbar.lastChange == expected)
            #expect(toolbar.showsSources)
        }
    }

    /// The pure items per state: the capsule, the separator and the anchor
    /// at rest; the anchor alone while writing; the anchor alone without
    /// sources.
    @Test func theToolbarsItemsPerState() {
        let sources = [UIBarButtonItem(), UIBarButtonItem()]
        let separator = UIBarButtonItem.fixedSpace()
        let anchor = UIBarButtonItem()
        let flexible = UIBarButtonItem.flexibleSpace()
        let rest = ComposerAttachmentToolbar.items(
            sources: sources, separator: separator, anchor: anchor, flexible: flexible, showsSources: true
        )
        #expect(rest.count == 5)
        #expect(rest[0] === flexible && rest[1] === sources[0] && rest[2] === sources[1])
        #expect(rest[3] === separator && rest[4] === anchor)
        let writing = ComposerAttachmentToolbar.items(
            sources: sources, separator: separator, anchor: anchor, flexible: flexible, showsSources: false
        )
        #expect(writing.count == 2 && writing[0] === flexible && writing[1] === anchor)
        let none = ComposerAttachmentToolbar.items(
            sources: [], separator: separator, anchor: anchor, flexible: flexible, showsSources: true
        )
        #expect(none.count == 2 && none[1] === anchor)
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
        let items = screen.debugComposeBar.debugAttachmentItems
        items.last?.primaryAction?.performWithSender(nil, target: nil)
        items.first?.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.picked == [.library, .camera])
    }

    /// None where the footer offered none: a driver that sends no media, a
    /// channel's reader (#2215). A group the viewer posts in keeps them.
    @Test func noneForATextOnlyDriverOrAChannelsReader() {
        let (textOnly, textWindow) = makeScreen(Driver(sendsMedia: false))
        defer { textWindow.isHidden = true }
        #expect(textOnly.debugComposeBar.debugAttachmentItems.isEmpty)

        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12 members", members: [:], isChannel: false
        ))
        #expect(screen.debugComposeBar.debugAttachmentItems.count == 2, "a group's member lost the camera")
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12.4K subscribers", members: [:],
            isChannel: true, readerStanding: .subscribed
        ))
        #expect(screen.debugComposeBar.debugAttachmentItems.isEmpty, "a channel's reader can attach")
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
        #expect(post.debugAttachmentItems.isEmpty)
        #expect(!post.debugShowsAttachments)

        post.configuration.attachments = [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") {},
        ]
        #expect(post.debugAttachmentItems.count == 1)
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
        let item = bar.debugAttachmentItems.first
        bar.configuration = .conversation(voice: .none, attachments: [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") { taps.names.append("new") },
        ])
        #expect(bar.debugAttachmentItems.first === item, "the item was rebuilt for a new action")
        item?.primaryAction?.performWithSender(nil, target: nil)
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
