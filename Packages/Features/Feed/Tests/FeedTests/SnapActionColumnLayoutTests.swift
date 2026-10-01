import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **`-snap-layout-v2`: the action column holds still across layouts.**
///
/// ```
///   media layout                         comments layout
///   ~~~~ band ~~~~~~~~~~~~~~ [♥]          ———————————————————— [♥]
///   caption…                 [⇄]          ———————————————————— [⇄ / ↑]
///                                         [◉][field…      ☺ 〰]
/// ```
///
/// The like anchor and the repost bubble are constraints inside the page's
/// chrome; the composer's stake and rail slot are constraints inside the
/// comments panel, resting on a line computed from the column's numbers. The
/// two never see each other — so the only proof they agree is to lay both out
/// at one screen size and compare the frames. Equal frames are what "switching
/// layouts, the bubbles don't move" means.
///
/// And with or without the flag, the composer's INPUT ROW rests on the
/// toolbar — `sm` above its glass — while the column keeps its place above.
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
        actionColumn: Bool, insets: UIEdgeInsets = insets, mediaURL: URL? = URL(string: "mock://media/1")
    ) -> SnapChromeView {
        let chrome = SnapChromeView(frame: screen)
        chrome.usesActionColumn = actionColumn
        chrome.setFixedInsets(insets)
        chrome.configure(with: mediaModel(mediaURL: mediaURL))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The media layout's two bubbles, in screen coordinates.
    static func mediaColumn(insets: UIEdgeInsets = insets) -> (like: CGRect, repost: CGRect) {
        let chrome = chrome(actionColumn: true, insets: insets)
        return (chrome.debugBoostButton.frame, chrome.debugRepostButton.frame)
    }

    /// The composer's column in `space`: the stake (nil when the bar shows
    /// none), and the rail slot — the rail button when the bar has a rail
    /// face, the mic otherwise.
    static func composerColumn(
        in root: UIView, space: UICoordinateSpace
    ) throws -> (stake: CGRect?, rail: CGRect, field: CGRect, bar: CommentsInputBar) {
        let bar = try #require(firstView(CommentsInputBar.self, in: root))
        let stake = button(bar, "Boost post").flatMap { $0.isHidden ? nil : $0 }
        let rail = bar.debugRailButton.isHidden ? try #require(button(bar, "Record voice comment")) : bar.debugRailButton
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

    private func detail(actionColumn: Bool) -> PostDetailViewController {
        let controller = PostDetailViewController(
            viewModel: PostDetailViewModel(postID: PostID("p"), repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        controller.usesActionColumn = actionColumn
        return controller
    }

    /// The engaged comments panel, mounted the way the feed mounts it: full
    /// screen, told the feed's insets.
    private func engagedPanel(actionColumn: Bool) -> (PostDetailViewController, UIWindow) {
        let controller = detail(actionColumn: actionColumn)
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

    // MARK: - Flag off: no repost bubble, the input row on the toolbar

    /// Off, the chrome carries no repost bubble at all — not even hidden — and
    /// the caption runs to its classic margin.
    @Test func withoutTheFlagThePageHasNoRepostBubble() {
        let chrome = Self.chrome(actionColumn: false)
        #expect(!chrome.subviews.contains { $0 is SnapRailRepostButton })
        #expect(chrome.interactionRoots.count == 5)
        #expect(abs(chrome.debugCaptionFrame.maxX - (Self.screen.width - Spacing.lg)) < 0.5)
    }

    @Test func withoutTheFlagTheComposerKeepsItsClassicBubbles() throws {
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 340, height: CommentsInputBar.restingHeight(for: .large))
        bar.layoutIfNeeded()
        let stake = try #require(Self.button(bar, "Boost post"))
        let mic = try #require(Self.button(bar, "Record voice comment"))
        #expect(stake.frame.size == CGSize(width: 44, height: 44))
        #expect(mic.frame.size == CGSize(width: 38, height: 38))
        let glyph = mic.configuration?.image.map { String(describing: $0) } ?? ""
        #expect(!glyph.contains("waveform"))
        #expect(bar.debugRailButton.isHidden, "no rail button without the flag")
        #expect(bar.debugFieldVoiceButton.isHidden, "no waveform in the field without the flag")
    }

    /// ⚠️ THE INPUT ROW RESTS ON THE TOOLBAR, flag off: the field's bottom `sm`
    /// above the toolbar's glass, and the stake and mic where they stood
    /// before — `sm` above the footer line, so a little higher than the field.
    @Test func withoutTheFlagTheFieldRestsOnTheToolbarAndTheColumnKeepsItsPlace() throws {
        let (controller, window) = engagedPanel(actionColumn: false)
        let composer = try Self.composerColumn(in: controller.view, space: window)
        let footerLine = Self.screen.height - Self.insets.bottom

        #expect(abs(composer.field.maxY - (Self.toolbarGlassTop - Spacing.sm)) < 0.5,
                "the field ends at \(composer.field.maxY), not sm above the glass at \(Self.toolbarGlassTop)")
        #expect(abs(composer.rail.maxY - (footerLine - Spacing.sm)) < 0.5, "the mic moved: \(composer.rail)")
        let stake = try #require(composer.stake)
        #expect(abs(stake.maxY - (composer.rail.minY - Spacing.sm)) < 0.5, "the stake left its station over the mic")
        #expect(composer.rail.maxY < composer.field.maxY, "the column stands higher than the field")
        _ = window
    }

    // MARK: - The media layout

    /// The repost bubble is the like anchor's twin, one md under it, and the
    /// caption and the page strip stop md short of it.
    @Test func theRepostBubbleStandsUnderTheLikeBubbleBesideTheCaption() {
        let chrome = Self.chrome(actionColumn: true)
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
        let chrome = Self.chrome(actionColumn: true, mediaURL: nil)
        #expect(chrome.debugRepostButton.isHidden)
    }

    // MARK: - The comments layout

    /// ⚠️ THE CONTRACT. The engaged composer's stake sits on the like
    /// bubble's frame and its rail slot — a REPOST face — on the repost
    /// bubble's, in screen coordinates: equal, not close. The field rests on
    /// the toolbar below them.
    @Test func theComposerBubblesStandExactlyOnTheMediaLayoutsBubbles() throws {
        let media = Self.mediaColumn()
        let (controller, window) = engagedPanel(actionColumn: true)
        let composer = try Self.composerColumn(in: controller.view, space: window)

        let stake = try #require(composer.stake)
        #expect(stake == media.like, "stake \(stake) vs like \(media.like)")
        #expect(composer.rail == media.repost, "rail \(composer.rail) vs repost \(media.repost)")
        #expect(composer.bar.debugRailSymbol == PostActionSymbol.repost)
        #expect(abs(composer.field.maxY - (Self.toolbarGlassTop - Spacing.sm)) < 0.5,
                "the field ends at \(composer.field.maxY), not sm above the glass at \(Self.toolbarGlassTop)")
        _ = window
    }

    /// The column's entrance is alpha only — a slide would move the bubbles.
    @Test func theColumnComposerEntersWithoutSliding() {
        let (controller, window) = engagedPanel(actionColumn: true)
        controller.setComposerEntranceState(offstage: true)
        let bar = Self.firstView(CommentsInputBar.self, in: controller.view)
        #expect(bar?.alpha == 0)
        #expect(bar?.transform == .identity)
        _ = window
    }

    private func hostedColumnBar(railFace: CommentsInputBar.RailFace = .voice) -> (CommentsInputBar, UIView) {
        let bar = CommentsInputBar()
        bar.usesActionColumn = true
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
    /// BESIDE the stake, never moving it.
    @Test func theColumnBarHoldsTheStakeStillWhileTheFieldGrows() throws {
        let (bar, host) = hostedColumnBar()

        let stake = try #require(Self.button(bar, "Boost post"))
        let mic = try #require(Self.button(bar, "Record voice comment"))
        let field = try #require(Self.fieldView(in: bar))
        let side = SnapActionColumn.bubbleSize
        #expect(stake.frame.size == CGSize(width: side, height: side))
        #expect(mic.frame.size == CGSize(width: side, height: side))
        #expect(abs(mic.frame.minY - stake.frame.maxY - SnapActionColumn.gap) < 0.5)
        #expect(abs(field.frame.maxY - bar.bounds.maxY) < 0.5, "the field is the bar's bottom")
        #expect(abs(bar.bounds.maxY - mic.frame.maxY - SnapActionColumn.columnLift(actionColumn: true)) < 0.5)
        let glyph = mic.configuration?.image.map { String(describing: $0) } ?? ""
        #expect(glyph.contains("waveform"), "the mic wears \(glyph)")
        #expect(abs(bar.bounds.height - CommentsInputBar.restingHeight(for: .large, actionColumn: true)) < 0.5)
        #expect(!bar.hasAmbiguousLayout)

        let stakeInHost = stake.convert(stake.bounds, to: host)
        bar.draftText = Array(repeating: "A line that wraps", count: 8).joined(separator: " ")
        host.layoutIfNeeded()
        #expect(stake.convert(stake.bounds, to: host) == stakeInHost, "the stake moved as the field grew")
        #expect(!bar.hasAmbiguousLayout)
    }

    /// ⚠️ ONE BUBBLE, TWO GLYPHS. With a rail face the slot is the rail button
    /// alone: REPOST over an empty field, the SEND arrow over a draft — the
    /// same button, its glyph replaced (`symbolContentTransition`), not a
    /// second button crossfaded over it — and the voice note is a waveform in
    /// the field.
    @Test func theRepostBubbleBecomesSendWhileThereIsText() throws {
        let (bar, _) = hostedColumnBar(railFace: .repost)
        var sent: [String] = []
        var railTaps = 0
        bar.onSend = { sent.append($0) }
        bar.onRailAction = { railTaps += 1 }
        let rail = bar.debugRailButton

        #expect(!rail.isHidden)
        #expect(Self.button(bar, "Record voice comment")?.isHidden == true, "the slot's mic stood down")
        #expect(Self.button(bar, "Send comment")?.isHidden == true, "send's own button stood down")
        #expect(!bar.debugFieldVoiceButton.isHidden, "the waveform is in the field")
        #expect(rail.configuration?.symbolContentTransition != nil, "the glyph swap is a symbol replace")
        #expect(bar.debugRailSymbol == PostActionSymbol.repost)
        #expect(rail.accessibilityLabel == "Repost")
        rail.sendActions(for: .primaryActionTriggered)
        #expect(railTaps == 1)

        bar.draftText = "Nice one"
        #expect(bar.debugRailSymbol == "arrow.up")
        #expect(rail.accessibilityLabel == "Send comment")
        #expect(rail.isEnabled)
        rail.sendActions(for: .primaryActionTriggered)
        #expect(sent == ["Nice one"])
        #expect(railTaps == 1, "a tap over a draft sends, it does not repost")

        // Sent: the field emptied, and the bubble is repost again.
        #expect(bar.draftText.isEmpty)
        #expect(bar.debugRailSymbol == PostActionSymbol.repost)
    }

    /// The waveform in the field and the emote button both fit inside it, the
    /// waveform at the field's end.
    @Test func theWaveformSitsBesideTheEmoteButtonInsideTheField() throws {
        let (bar, _) = hostedColumnBar(railFace: .repost)
        let field = try #require(Self.fieldView(in: bar))
        let voice = bar.debugFieldVoiceButton
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

    // MARK: - The toolbar and the menu

    /// Share has a button in the toolbar's capsule, so ⋯ stops offering it.
    @Test func theMenuDropsShareWhenTheColumnCarriesIt() {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: ColumnSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: nil
        )
        controller.usesActionColumn = true
        #expect(controller.debugMoreMenuTitles(for: PostID("p1")) == ["Not interested"])
        controller.usesActionColumn = false
        #expect(controller.debugMoreMenuTitles(for: PostID("p1")) == ["Share", "Not interested"])
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
