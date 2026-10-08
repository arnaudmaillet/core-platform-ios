import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **The action column holds still across layouts.**
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ [♥]          ———————————————————— [♥]
///   caption…                 [⇄]          ———————————————————— [⇄]
///                                         [◉][field…    ☺ 〰/↑]
/// ```
///
/// The like anchor and the repost bubble are constraints inside the page's
/// chrome; the composer's stake and rail slot are constraints inside the
/// comments panel, resting on a line computed from the column's numbers. The
/// two never see each other — so the only proof they agree is to lay both out
/// at one screen size and compare the frames. Equal frames are what "switching
/// layouts, the bubbles don't move" means.
///
/// And the composer's INPUT ROW rests on the toolbar — `glassGap` above its
/// glass — while the column keeps its place on the media layout's bubbles,
/// keyboard up or down: only the row rises with a keyboard, widening into the
/// column's width as it clears it.
@MainActor
struct SnapActionColumnLayoutTests {
    static let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
    /// A notched phone's nav-bar top and its home indicator + floating
    /// toolbar — the feed's safe area while its footer is up.
    static let insets = UIEdgeInsets(top: 103, left: 0, bottom: 83, right: 0)

    // MARK: - Fixtures

    static func mediaModel(mediaURL: URL? = URL(string: "mock://media/1")) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana · 3m", avatarURL: nil,
            caption: "A caption long enough to fill both of its lines beside the reserved floor.",
            mediaURL: mediaURL, mediaKind: .image, thumbnailURL: nil, audioText: nil
        )
    }

    /// The media layout at full screen, as a page lays it out (the chrome IS
    /// the page's overlay, edge to edge — its coordinates are the screen's).
    static func chrome(
        insets: UIEdgeInsets = insets, mediaURL: URL? = URL(string: "mock://media/1")
    ) -> SnapChromeView {
        let chrome = SnapChromeView(frame: screen)
        chrome.setFixedInsets(insets)
        chrome.configure(with: mediaModel(mediaURL: mediaURL))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The media layout's two bubbles, in screen coordinates.
    static func mediaColumn(insets: UIEdgeInsets = insets) -> (like: CGRect, repost: CGRect) {
        let chrome = chrome(insets: insets)
        return (chrome.debugBoostButton.frame, chrome.debugRepostButton.frame)
    }

    /// The composer's column in `space`: the stake (nil when the bar shows
    /// none), and the rail slot — the rail button, laid out on its station
    /// whatever it wears.
    static func composerColumn(
        in root: UIView, space: UICoordinateSpace
    ) throws -> (stake: CGRect?, rail: CGRect, field: CGRect, bar: CommentsInputBar) {
        let bar = try #require(firstView(CommentsInputBar.self, in: root))
        // The snap panel's stake bubble wears the like face (#668).
        let stake = button(bar, "Like").flatMap { $0.isHidden ? nil : $0 }
        let rail = bar.debugRailButton
        let field = try #require(fieldView(in: bar))
        return (
            stake.map { $0.convert($0.bounds, to: space) },
            rail.convert(rail.bounds, to: space),
            field.convert(field.bounds, to: space),
            bar
        )
    }

    static func button(_ bar: UIView, _ label: String) -> UIButton? {
        bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
    }

    /// The field: the bar's effect view that holds the text view.
    static func fieldView(in bar: CommentsInputBar) -> UIVisualEffectView? {
        bar.subviews.compactMap { $0 as? UIVisualEffectView }.first { firstView(UITextView.self, in: $0) != nil }
    }

    static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// A stand-in KEYBOARD for `bar`, in `root`: a guide whose top is the
    /// returned constraint's constant below `root`'s top — what the host's
    /// `keyboardLayoutGuide` is to the bar, which the package test host can
    /// never raise. Starts at `top`.
    static func fakeKeyboard(in root: UIView, for bar: CommentsInputBar, top: CGFloat) -> NSLayoutConstraint {
        let keyboard = UILayoutGuide()
        root.addLayoutGuide(keyboard)
        let edge = keyboard.topAnchor.constraint(equalTo: root.topAnchor, constant: top)
        NSLayoutConstraint.activate([
            edge,
            keyboard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            keyboard.heightAnchor.constraint(equalToConstant: 1),
        ])
        bar.riseWithKeyboard(of: keyboard)
        return edge
    }

    /// Lays out `host`, then `bar`. ⚠️ A WINDOWLESS host: moving a guide the
    /// bar's FIELD (a grandchild) is constrained to does not mark the bar for
    /// layout there, so the bar is laid out by hand. In a window — the app,
    /// the panel specs below — the keyboard guide's moves lay it out on their
    /// own (measured on the simulator with `-composer-keyboard-qa`).
    static func relayout(_ host: UIView, _ bar: CommentsInputBar) {
        host.layoutIfNeeded()
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
    }

    /// The engaged comments panel, mounted the way the feed mounts it: full
    /// screen, told the feed's insets.
    static func engagedPanel() -> (PostDetailViewController, UIWindow) {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        let window = UIWindow(frame: Self.screen)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = Self.screen
        controller.setEngagedPageSwipeHandler { _, _, _ in }
        controller.setEngagedInsets(top: 200, bottomInset: Self.insets.bottom)
        controller.setComposerEntranceState(offstage: false)
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// Where the toolbar's glass begins, in screen coordinates: the drop under
    /// the footer line (`SnapActionColumn.toolbarGlassDrop`).
    static var toolbarGlassTop: CGFloat {
        screen.height - insets.bottom + SnapActionColumn.toolbarGlassDrop
    }

    /// The glass bubble a toolbar item stands in, in `window`: its first
    /// ancestor taller than the item (UIKit insets the item in its glass).
    ///
    /// ⚠️ READ OFF THE BAR, NEVER ASSUMED. The bubble's height is UIKit's:
    /// 48pt in the app on iOS 27, 44pt for the same lone ⋯ in the package
    /// test host — and a test that took the item's centre minus 24 read the
    /// host's drop 2pt short and called the host unfaithful (it is not).
    static func glassFrame(of item: UIView, in window: UIWindow) -> CGRect? {
        var node = item.superview
        while let view = node, view !== window {
            if view.bounds.height > item.bounds.height + 0.5 { return view.convert(view.bounds, to: window) }
            node = view.superview
        }
        return nil
    }

    // MARK: - The toolbar's glass

    /// ⚠️ THE ONE MEASURED NUMBER, CHECKED AGAINST A REAL BAR on whatever
    /// runtime runs the suite. Every composer rests its input row `glassGap`
    /// above the toolbar's glass, and where the glass begins under the
    /// safe-area line is a per-OS constant (`SnapActionColumn.toolbarGlassDrop`)
    /// — reading the private floating bar at runtime would put a frame of
    /// UIKit's own layout into the composer's, a frame late, during every
    /// push. This puts a toolbar in a window and reads the drop off the glass
    /// UIKit actually drew; if UIKit moves its bar, this fails with the new
    /// number, and the constant is what to update.
    @Test func theToolbarsGlassStandsWhereTheComposerExpectsIt() async throws {
        let screen = UIViewController()
        let more = SnapFooterToolbar.makeMoreButton(menu: UIMenu(children: []))
        screen.toolbarItems = [.flexibleSpace(), UIBarButtonItem(customView: more)]
        let nav = UINavigationController(rootViewController: screen)
        nav.setToolbarHidden(false, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = nav
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<30 {
            nav.view.setNeedsLayout()
            nav.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(more.window != nil, "the bar never hosted its item")

        let safeLine = screen.view.convert(
            CGPoint(x: 0, y: screen.view.bounds.height - screen.view.safeAreaInsets.bottom), to: window
        ).y
        let glass = try #require(Self.glassFrame(of: more, in: window), "no glass around the item")
        let drop = glass.minY - safeLine
        #expect(abs(drop - SnapActionColumn.toolbarGlassDrop) < 0.5,
                "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion): the glass \(glass) starts \(drop)pt under the safe-area line \(safeLine), not \(SnapActionColumn.toolbarGlassDrop)")
    }

    // MARK: - The media layout

    /// The repost bubble is the like anchor's twin, one md under it, and the
    /// caption and the page strip stop md short of it.
    @Test func theRepostBubbleStandsUnderTheLikeBubbleBesideTheCaption() {
        let chrome = Self.chrome()
        let like = chrome.debugBoostButton.frame
        let repost = chrome.debugRepostButton.frame

        #expect(chrome.debugRepostButton.isHidden == false)
        #expect(chrome.debugRepostButton.accessibilityLabel == "Repost")
        #expect(repost.size == like.size)
        #expect(abs(repost.width - SnapActionColumn.bubbleSize) < 0.5)
        #expect(repost.maxX == like.maxX)
        #expect(abs(repost.minY - (like.maxY + SnapActionColumn.gap)) < 0.5)
        #expect(chrome.debugCaptionFrame.maxX <= repost.minX - Spacing.md + 0.5)
        // Its top is the caption floor's: beside the caption's first line.
        #expect(abs(chrome.debugCaptionFrame.maxY - (repost.minY + SnapChromeView.captionFloorHeight)) < 0.5)
        #expect(chrome.debugPageBarFrame.maxX == chrome.debugCaptionFrame.maxX)
        #expect(chrome.interactionRoots.contains { $0 === chrome.debugRepostButton })
    }

    /// Media chrome, like the anchor: a text page's composer stands in the
    /// column instead.
    @Test func aTextPageHasNoRepostBubble() {
        let chrome = Self.chrome(mediaURL: nil)
        #expect(chrome.debugRepostButton.isHidden)
    }

    // MARK: - The comments layout

    /// ⚠️ THE CONTRACT. The engaged composer's stake sits on the like
    /// bubble's frame and its rail slot — a REPOST face — on the repost
    /// bubble's, in screen coordinates: equal, not close. The field rests on
    /// the toolbar below them, and the waveform is in the field.
    @Test func theComposerBubblesStandExactlyOnTheMediaLayoutsBubbles() throws {
        let media = Self.mediaColumn()
        let (controller, window) = Self.engagedPanel()
        let composer = try Self.composerColumn(in: controller.view, space: window)

        let stake = try #require(composer.stake)
        #expect(stake == media.like, "stake \(stake) vs like \(media.like)")
        #expect(composer.rail == media.repost, "rail \(composer.rail) vs repost \(media.repost)")
        #expect(composer.bar.debugRailSymbol == PostActionSymbol.repost)
        #expect(!composer.bar.debugFieldActionButton.isHidden, "the waveform is in the field")
        #expect(composer.bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)
        #expect(abs(composer.field.maxY - (Self.toolbarGlassTop - SnapActionColumn.glassGap)) < 0.5,
                "the field ends at \(composer.field.maxY), not glassGap above the glass at \(Self.toolbarGlassTop)")
        _ = window
    }

    /// The column's entrance is alpha only — a slide would move the bubbles.
    @Test func theColumnComposerEntersWithoutSliding() {
        let (controller, window) = Self.engagedPanel()
        controller.setComposerEntranceState(offstage: true)
        let bar = Self.firstView(CommentsInputBar.self, in: controller.view)
        #expect(bar?.alpha == 0)
        #expect(bar?.transform == .identity)
        _ = window
    }

    private func hostedColumnBar(railFace: CommentsInputBar.RailFace = .empty) -> (CommentsInputBar, UIView) {
        let bar = CommentsInputBar()
        bar.railFace = railFace
        bar.onPageSwipe = { _, _, _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        return (bar, host)
    }

    /// The bar's own geometry: both bubbles the band's height, md apart, the
    /// slot lifted `columnLift` off the field's bottom, and a field that grows
    /// BESIDE the stake, never moving it. Without a rail face (a draft post)
    /// the slot holds no bubble but keeps its station, and the field holds the
    /// waveform as on every bar.
    @Test func theColumnBarHoldsTheStakeStillWhileTheFieldGrows() throws {
        let (bar, host) = hostedColumnBar()

        let stake = try #require(Self.button(bar, "Boost post"))
        let slot = bar.debugRailButton
        let field = try #require(Self.fieldView(in: bar))
        let side = SnapActionColumn.bubbleSize
        #expect(stake.frame.size == CGSize(width: side, height: side))
        #expect(slot.frame.size == CGSize(width: side, height: side))
        #expect(abs(slot.frame.minY - stake.frame.maxY - SnapActionColumn.gap) < 0.5)
        #expect(abs(field.frame.maxY - bar.bounds.maxY) < 0.5, "the field is the bar's bottom")
        #expect(abs(bar.bounds.maxY - slot.frame.maxY - SnapActionColumn.columnLift) < 0.5)
        #expect(slot.isHidden, "no rail face, no rail bubble")
        #expect(!bar.debugFieldActionButton.isHidden, "the waveform is in the field")
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)
        #expect(abs(bar.bounds.height - CommentsInputBar.restingHeight(for: .large)) < 0.5)
        #expect(!bar.hasAmbiguousLayout)

        let stakeInHost = stake.convert(stake.bounds, to: host)
        bar.draftText = Array(repeating: "A line that wraps", count: 8).joined(separator: " ")
        host.layoutIfNeeded()
        #expect(stake.convert(stake.bounds, to: host) == stakeInHost, "the stake moved as the field grew")
        #expect(!bar.hasAmbiguousLayout)
    }

    /// ⚠️ THE RAIL IS THE HOST'S ACTION AND NOTHING ELSE (asked 2026-10-02).
    /// Typing never turns the repost bubble into send: a tap on it reposts
    /// over a draft as over an empty field, and the draft stays.
    @Test func theRepostBubbleNeverBecomesSend() throws {
        let (bar, _) = hostedColumnBar(railFace: .repost)
        var sent: [String] = []
        var railTaps = 0
        bar.onSend = { sent.append($0) }
        bar.onRailAction = { railTaps += 1 }
        let rail = bar.debugRailButton

        #expect(!rail.isHidden)
        #expect(bar.debugRailSymbol == PostActionSymbol.repost)
        #expect(rail.accessibilityLabel == "Repost")
        rail.sendActions(for: .primaryActionTriggered)
        #expect(railTaps == 1)

        bar.draftText = "Nice one"
        #expect(bar.debugRailSymbol == PostActionSymbol.repost, "the rail turned into \(bar.debugRailSymbol ?? "-")")
        #expect(rail.accessibilityLabel == "Repost")
        rail.sendActions(for: .primaryActionTriggered)
        #expect(railTaps == 2)
        #expect(sent.isEmpty, "a tap on the rail sent the draft")
        #expect(bar.draftText == "Nice one")

        bar.isSending = true
        #expect(bar.debugRailSymbol == PostActionSymbol.repost)
        #expect(rail.isEnabled)
    }

    /// ⚠️ THE FIELD'S WAVEFORM IS THE SEND. Over a draft it becomes the send
    /// arrow — the same button, its glyph replaced (`symbolContentTransition`)
    /// — a tap sends, and the emptied field wears the waveform again.
    @Test func theFieldsWaveformBecomesSendWhileThereIsText() throws {
        let (bar, _) = hostedColumnBar(railFace: .repost)
        var sent: [String] = []
        var voiceTaps = 0
        bar.onSend = { sent.append($0) }
        bar.onVoiceNote = { voiceTaps += 1 }
        let action = bar.debugFieldActionButton

        #expect(action.configuration?.symbolContentTransition != nil, "the glyph swap is a symbol replace")
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)
        action.sendActions(for: .primaryActionTriggered)
        #expect(voiceTaps == 1)

        bar.draftText = "   "
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol, "blank is not a draft")

        bar.draftText = "Nice one"
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.sendSymbol)
        #expect(action.accessibilityLabel == "Send comment")
        #expect(action.isEnabled)
        action.sendActions(for: .primaryActionTriggered)
        #expect(sent == ["Nice one"])
        #expect(voiceTaps == 1, "a tap over a draft sends, it does not record")

        // Sent: the field emptied, and the button is the waveform again.
        #expect(bar.draftText.isEmpty)
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)

        // In flight: the send face holds, quiet, until the host is done.
        bar.isSending = true
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.sendSymbol)
        #expect(!action.isEnabled)
        bar.isSending = false
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)

        // The draft post's wording.
        bar.sendAccessibilityLabel = "Publish post"
        bar.draftText = "Hello"
        #expect(action.accessibilityLabel == "Publish post")
    }

    /// The waveform in the field and the emote button both fit inside it, the
    /// waveform at the field's end.
    @Test func theWaveformSitsBesideTheEmoteButtonInsideTheField() throws {
        let (bar, _) = hostedColumnBar(railFace: .repost)
        let field = try #require(Self.fieldView(in: bar))
        let voice = bar.debugFieldActionButton
        let emote = try #require(
            field.contentView.subviews.compactMap { $0 as? UIButton }.first { $0 !== voice }
        )
        field.layoutIfNeeded()
        #expect(voice.superview === field.contentView)
        #expect(emote.frame.maxX <= voice.frame.minX + 0.5, "the emote button is not before the waveform")
        #expect(voice.frame.maxX <= field.bounds.width)
        var voiceTaps = 0
        bar.onVoiceNote = { voiceTaps += 1 }
        voice.sendActions(for: .primaryActionTriggered)
        #expect(voiceTaps == 1)
    }

    // MARK: - The keyboard

    /// The rise, pure: nothing until the row lifts, then its lift over the
    /// column's clearance, capped at 1 — and the field's trailing inset
    /// interpolating from the column's width to nothing.
    @Test func theRiseIsTheRowsLiftOverTheColumnsClearance() {
        #expect(CommentsInputBar.riseProgress(lift: 0, clearance: 100) == 0)
        #expect(CommentsInputBar.riseProgress(lift: -5, clearance: 100) == 0)
        #expect(CommentsInputBar.riseProgress(lift: 25, clearance: 100) == 0.25)
        #expect(CommentsInputBar.riseProgress(lift: 100, clearance: 100) == 1)
        #expect(CommentsInputBar.riseProgress(lift: 300, clearance: 100) == 1)
        #expect(CommentsInputBar.riseProgress(lift: 3, clearance: 0) == 1)
        let rest = SnapActionColumn.bubbleSize + Spacing.sm
        #expect(abs(CommentsInputBar.fieldTrailingInset(progress: 0) - rest) < 0.001)
        #expect(abs(CommentsInputBar.fieldTrailingInset(progress: 0.5) - rest / 2) < 0.001)
        #expect(CommentsInputBar.fieldTrailingInset(progress: 1) == 0)
        #expect(CommentsInputBar.fieldTrailingInset(progress: 2) == 0)
    }

    /// ⚠️ THE FIELD WIDENS WITH THE KEYBOARD, FRAME BY FRAME. The keyboard's
    /// top walks up and back down (an interactive dismissal is the same walk,
    /// one frame at a time): the row stays at rest — rest width — until the
    /// keyboard reaches it, then rides `sm` above it, its width interpolating
    /// with how far it has risen clear of the column, and the column's
    /// bubbles never move.
    @Test func theFieldWidensAsTheKeyboardLiftsItClearOfTheColumn() throws {
        let (bar, host) = hostedColumnBar(railFace: .repost)
        let field = try #require(Self.fieldView(in: bar))
        let stake = try #require(Self.button(bar, "Boost post"))
        let rail = bar.debugRailButton
        // No keyboard: the guide's top below the host, like a screen's bottom
        // under a bar resting above the toolbar.
        let keyboard = Self.fakeKeyboard(in: host, for: bar, top: host.bounds.height + 80)
        host.layoutIfNeeded()

        let restField = field.frame
        let restStake = stake.convert(stake.bounds, to: host)
        let restRail = rail.convert(rail.bounds, to: host)
        let restBar = bar.frame
        let fullWidth = bar.bounds.width - field.frame.minX
        let restWidth = fullWidth - (SnapActionColumn.bubbleSize + Spacing.sm)
        #expect(abs(restField.width - restWidth) < 0.5, "rest width \(restField.width) vs \(restWidth)")
        #expect(bar.riseProgress == 0)
        // Clearance: from the row's resting bottom to the column's top.
        let clearance = restBar.height - stake.frame.minY

        func keyboardTop(lifting lift: CGFloat) -> CGFloat { restBar.maxY - lift + Spacing.sm }
        func widthAt(lift: CGFloat) -> CGFloat {
            keyboard.constant = keyboardTop(lifting: lift)
            Self.relayout(host, bar)
            #expect(abs(field.convert(field.bounds, to: host).maxY - (restBar.maxY - lift)) < 0.5,
                    "the row is not sm over the keyboard at lift \(lift)")
            #expect(stake.convert(stake.bounds, to: host) == restStake, "the stake moved at lift \(lift)")
            #expect(rail.convert(rail.bounds, to: host) == restRail, "the rail moved at lift \(lift)")
            #expect(bar.frame == restBar, "the bar moved at lift \(lift)")
            return field.frame.width
        }

        // The keyboard's top just reaching the row: nothing yet.
        #expect(abs(widthAt(lift: 0) - restWidth) < 0.5)
        // A quarter, half the way clear, then clear of the column and beyond.
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            let width = widthAt(lift: clearance * fraction)
            let expected = restWidth + (fullWidth - restWidth) * fraction
            #expect(abs(width - expected) < 0.5, "at \(fraction): \(width) vs \(expected)")
            #expect(abs(bar.riseProgress - fraction) < 0.01)
        }
        #expect(abs(widthAt(lift: clearance) - fullWidth) < 0.5)
        #expect(abs(widthAt(lift: clearance + 200) - fullWidth) < 0.5, "a full keyboard leaves the field full width")

        // And back down, the way a dismissal drags it.
        #expect(abs(widthAt(lift: clearance / 2) - (restWidth + fullWidth) / 2) < 0.5)
        keyboard.constant = host.bounds.height + 80
        Self.relayout(host, bar)
        #expect(field.frame == restField, "the row did not come home: \(field.frame) vs \(restField)")
        #expect(bar.riseProgress == 0)
        #expect(!bar.hasAmbiguousLayout)
    }

    /// A risen row's touches are still the bar's, though it stands above the
    /// bar's own bounds; the empty run beside the column is not.
    @Test func theRisenRowStillTakesItsTouches() throws {
        let (bar, host) = hostedColumnBar(railFace: .repost)
        let field = try #require(Self.fieldView(in: bar))
        let keyboard = Self.fakeKeyboard(in: host, for: bar, top: host.bounds.height + 80)
        host.layoutIfNeeded()
        keyboard.constant = bar.frame.minY - 120
        Self.relayout(host, bar)
        #expect(field.frame.maxY < 0, "the row did not rise above the bar")
        #expect(bar.point(inside: CGPoint(x: field.frame.midX, y: field.frame.midY), with: nil))
        #expect(!bar.point(inside: CGPoint(x: field.frame.midX, y: bar.bounds.height - 4), with: nil),
                "the row's resting place, empty now, is not the bar's")
        #expect(bar.occupiedMinY < bar.frame.minY)
        #expect(abs(bar.occupiedMinY - (bar.frame.minY + field.frame.minY)) < 0.5)
    }

    /// ⚠️ THE CONTRACT, KEYBOARD UP. On the engaged panel the column's
    /// bubbles stand on the media layout's like and repost bubbles with a
    /// keyboard up exactly as at rest — equal frames, in window coordinates —
    /// while the field rides `sm` above the keyboard at full width.
    @Test func theColumnHoldsTheMediaLayoutsBubblesWithTheKeyboardUp() throws {
        let media = Self.mediaColumn()
        let (controller, window) = Self.engagedPanel()
        let rest = try Self.composerColumn(in: controller.view, space: window)
        let keyboard = Self.fakeKeyboard(in: controller.view, for: rest.bar, top: Self.screen.height)
        controller.view.layoutIfNeeded()
        let settled = try Self.composerColumn(in: controller.view, space: window)
        #expect(settled.field == rest.field, "a keyboard at the screen's bottom moved the field")

        keyboard.constant = Self.screen.height - 336
        controller.view.layoutIfNeeded()
        let up = try Self.composerColumn(in: controller.view, space: window)
        #expect(up.stake == media.like, "stake \(String(describing: up.stake)) vs like \(media.like)")
        #expect(up.rail == media.repost, "rail \(up.rail) vs repost \(media.repost)")
        #expect(up.stake == rest.stake && up.rail == rest.rail)
        #expect(abs(up.field.maxY - (Self.screen.height - 336 - Spacing.sm)) < 0.5)
        #expect(abs(up.field.maxX - up.rail.maxX) < 0.5, "the risen field does not take the column's width")
        #expect(up.bar.debugRailSymbol == PostActionSymbol.repost)
        _ = window
    }

    /// ⚠️ THE PULL-DOWN CLOSE IS THE KEYBOARD'S WHILE IT IS UP (asked
    /// 2026-10-02). With the keyboard up a downward drag at the list's top only
    /// puts the keyboard away — it never drives the layout's fade-and-shrink
    /// close; with the keyboard down the same drag does.
    @Test func thePullDownCloseWaitsForTheKeyboardToBeDown() throws {
        #expect(PostDetailViewController.armsPullDismiss(atTop: true, keyboardOpen: false))
        #expect(!PostDetailViewController.armsPullDismiss(atTop: true, keyboardOpen: true))
        #expect(!PostDetailViewController.armsPullDismiss(atTop: false, keyboardOpen: false))

        let (controller, window) = Self.engagedPanel()
        var pulls: [CGFloat] = []
        controller.setPullDismissDriveHandler { phase, translation, _ in
            if phase == .changed { pulls.append(translation) }
        }
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view))
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: controller.view))
        let top = -stream.contentInset.top
        func pull() {
            stream.contentOffset.y = top
            controller.scrollViewWillBeginDragging(stream)
            stream.contentOffset.y = top - 60
            controller.scrollViewDidScroll(stream)
        }

        bar.setKeyboardOpen(true)
        pull()
        #expect(pulls.allSatisfy { $0 == 0 }, "a pull with the keyboard up drove the close: \(pulls)")

        bar.setKeyboardOpen(false)
        pulls.removeAll()
        pull()
        #expect(pulls.contains { abs($0 - 60) < 0.5 }, "a pull with the keyboard down drove nothing: \(pulls)")
        _ = window
    }

    // MARK: - The toolbar and the menu

    /// Share has a button in the toolbar's capsule, so ⋯ does not offer it.
    @Test func theMenuLeavesShareToTheToolbar() {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: nil
        )
        #expect(controller.debugMoreMenuTitles(for: PostID("p1")) == ["Not interested"])
    }
}

/// A repository that vends nothing: these tests are about geometry.
private final class ColumnSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
