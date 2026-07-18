import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The comments engagement's geometry and choreography contracts: one
/// authority (`SnapCommentsLayout`) feeds both layers, so the strip (cell)
/// and the panel (sheet) partition the container exactly; the cell's
/// engaged layout docks the media without touching playback ownership and
/// reverses to identity.
@MainActor
struct SnapCommentsPresentationTests {
    private static let container = CGRect(x: 0, y: 0, width: 390, height: 844)
    private static let topInset: CGFloat = 103

    // MARK: - Layout authority

    /// The docked slot is a perfect 1:1 square tile, on the card's second
    /// band — below the author header.
    @Test func mediaSlotIsSquare() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        #expect(slot.width == slot.height)
        #expect(slot.height == SnapCommentsLayout.mediaSlotHeight)
        #expect(slot.minX == Spacing.lg)
        #expect(slot.minY == Self.topInset + SnapCommentsLayout.stripTopPadding
            + SnapCommentsLayout.stripCardPadding)
    }

    /// Squareness comes from a CENTERED CROP, never a squash: the crop is
    /// the largest centered square of the media's own bounds, and the
    /// docking transform is uniform.
    @Test func mediaCropIsTheLargestCenteredSquare() {
        let crop = SnapCommentsLayout.mediaCropFrame(in: Self.container)
        #expect(crop.width == crop.height)
        #expect(crop.width == Self.container.width)
        #expect(abs(crop.midX - Self.container.midX) < 0.001)
        #expect(abs(crop.midY - Self.container.midY) < 0.001)
        let transform = SnapCommentsLayout.mediaTransform(
            bounds: Self.container,
            slot: SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        )
        #expect(transform.a == transform.d) // uniform scale — no distortion
    }

    /// Strip + comments region tile the cell with no gap and no overlap.
    @Test func stripAndCommentsRegionPartitionTheCell() {
        let stripBottom = SnapCommentsLayout.stripBottom(topInset: Self.topInset)
        let region = SnapCommentsLayout.commentsRegionHeight(
            containerHeight: Self.container.height, topInset: Self.topInset
        )
        #expect(stripBottom + region == Self.container.height)
    }

    /// The transform carries the CROP square exactly onto the slot — the
    /// real contract, asserted on an actual view's resolved frame (view
    /// transforms apply about the center anchor; `CGRect.applying` scales
    /// about the origin and would test the wrong semantics). The crop is
    /// centered, so the view's transformed center is the slot's center and
    /// the transformed width equals the slot's side; the height overflow is
    /// what the mask crops away.
    @Test func mediaTransformMapsCropOntoSlot() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let view = UIView(frame: Self.container)
        view.transform = SnapCommentsLayout.mediaTransform(bounds: Self.container, slot: slot)
        #expect(abs(view.frame.midX - slot.midX) < 0.5)
        #expect(abs(view.frame.midY - slot.midY) < 0.5)
        #expect(abs(view.frame.width - slot.width) < 0.5)
        let crop = SnapCommentsLayout.mediaCropFrame(in: Self.container)
        let scale = view.frame.width / Self.container.width
        #expect(abs(crop.height * scale - slot.height) < 0.5)
    }

    /// The caption's flight start: a view settled at its engaged home,
    /// wearing the flight transform, sits top-left aligned on the chrome
    /// caption's frame at the enlarged type scale — so animating to
    /// `.identity` is a genuine travel, not a teleport.
    @Test func captionFlightTransformMapsOntoSource() {
        let final = CGRect(x: 122, y: 119, width: 264, height: 96)
        let source = CGRect(x: 16, y: 700, width: 370, height: 44)
        let scale: CGFloat = 17.0 / 15.0
        let view = UIView(frame: final)
        view.transform = SnapCommentsLayout.captionFlightTransform(
            finalFrame: final, sourceFrame: source, scale: scale
        )
        #expect(abs(view.frame.minX - source.minX) < 0.5)
        #expect(abs(view.frame.minY - source.minY) < 0.5)
        #expect(abs(view.frame.width - final.width * scale) < 0.5)
        #expect(abs(view.frame.height - final.height * scale) < 0.5)
    }

    /// The conceal seam: the chrome caption vanishes instantly for the
    /// flight and returns on demand — independent of `chrome.alpha`, and
    /// never resurrecting a caption the post doesn't have.
    @Test func captionConcealSwapsInstantly() throws {
        let chrome = SnapChromeView(frame: Self.container)
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/1"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        let caption = try #require(
            chrome.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string == "caption" }
        )
        #expect(caption.isHidden == false)
        #expect(chrome.captionFlightSourceFrame != nil)
        chrome.setCaptionConcealed(true)
        #expect(caption.isHidden == true)
        // The flight source survives concealment (the reverse flight needs it).
        #expect(chrome.captionFlightSourceFrame != nil)
        chrome.setCaptionConcealed(false)
        #expect(caption.isHidden == false)
    }

    @Test func degenerateBoundsAreSafe() {
        #expect(SnapCommentsLayout.mediaSlotFrame(in: .zero, topInset: 0) == .zero)
        #expect(SnapCommentsLayout.mediaTransform(bounds: .zero, slot: .zero) == .identity)
        #expect(SnapCommentsLayout.commentsRegionHeight(containerHeight: 10, topInset: 500) == 0)
    }

    // MARK: - Cell engagement

    private func makeEngagedCell() -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        cell.setCommentsEngaged(true)
        return cell
    }

    /// Engaging docks the media (both render surfaces — whichever is
    /// visible rides the same transform), fades the comment surfaces while
    /// the ACTION RAIL stays untouched (the blueprint's keep), and shows
    /// the engaged caption; disengaging restores identity exactly.
    @Test func engagementDocksMediaAndReverses() throws {
        let cell = makeEngagedCell()
        #expect(cell.isCommentsEngaged)

        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let expected = SnapCommentsLayout.mediaTransform(bounds: Self.container, slot: slot)
        let media = try #require(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        #expect(media.transform == expected)
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        // The chrome as a whole never fades — only its comment surfaces do;
        // the rail rides both states at full presence.
        #expect(chrome.alpha == 1)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        #expect(rail.alpha == 1)
        // Fully interactive through the engagement — the keyboard-up
        // overlap with the composer's ✕ is arbitrated in the cell's
        // hitTest, not by disabling the rail.
        #expect(rail.isUserInteractionEnabled == true)
        #expect(ticker.alpha == 0)
        #expect(subtitle.alpha == 0)

        cell.setCommentsEngaged(false)
        #expect(cell.isCommentsEngaged == false)
        #expect(media.transform == .identity)
        #expect(media.layer.cornerRadius == 0)
        #expect(ticker.alpha == 1)
        #expect(subtitle.alpha == 1)
    }

    /// The keyboard-up collision rule: wherever the rail and the engaged
    /// composer physically overlap, the composer wins the touch; the rail
    /// keeps everything else. Exercised through the cell's real hitTest
    /// with a composer positioned inside the rail's column.
    @Test func engagedComposerOutranksTheRailWhereTheyOverlap() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/4"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        cell.layoutIfNeeded()
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        // Host a composer whose frame overlaps the rail's column (the
        // keyboard-up geometry), plus a probe point in the rail clear of it.
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
        let bar = CommentsInputBar()
        let overlap = CGPoint(x: rail.frame.midX, y: rail.frame.midY)
        let barOrigin = hosted.convert(CGPoint(x: overlap.x - 20, y: overlap.y - 20), from: cell)
        bar.frame = CGRect(origin: barOrigin, size: CGSize(width: 120, height: 46))
        hosted.addSubview(bar)

        let overlapHit = try #require(cell.hitTest(overlap, with: nil))
        #expect(sequence(first: overlapHit, next: { $0.superview }).contains { $0 is CommentsInputBar })
        // Above the composer, the rail still owns its column.
        let railPoint = CGPoint(x: rail.frame.midX, y: rail.frame.minY + 10)
        let railHit = try #require(cell.hitTest(railPoint, with: nil))
        #expect(sequence(first: railHit, next: { $0.superview }).contains { $0 is SnapShortcutRailView })
    }

    /// The glass card is exactly one media row tall — the slot wrapped
    /// with uniform padding, inset from the screen edges: a floating
    /// object, not a band. The column's rows live INSIDE the slot's
    /// vertical extent, so they add no height.
    @Test func stripCardWrapsTheSlot() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let card = SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset)
        #expect(card.minY == slot.minY - SnapCommentsLayout.stripCardPadding)
        #expect(card.maxY == slot.maxY + SnapCommentsLayout.stripCardPadding)
        #expect(card.minX == slot.minX - SnapCommentsLayout.stripCardPadding)
        #expect(card.maxX == Self.container.width - card.minX)
        #expect(card.height == SnapCommentsLayout.cardHeight)
        #expect(card.maxY < SnapCommentsLayout.stripBottom(topInset: Self.topInset))
    }

    /// The caption column's floor and line budget: the column stacks
    /// bottom-up — actions always reserved, the music line only when the
    /// post carries one — and the line cap is whole lines, floored, never
    /// zero.
    @Test func captionColumnReservesTheMusicLine() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let bare = SnapCommentsLayout.captionColumnMaxY(slotMaxY: slot.maxY, hasAudioLine: false)
        let withMusic = SnapCommentsLayout.captionColumnMaxY(slotMaxY: slot.maxY, hasAudioLine: true)
        let actionsReserved = SnapCommentsLayout.cardActionsHeight + Spacing.xs
        #expect(bare == slot.maxY - actionsReserved)
        #expect(withMusic == slot.maxY - actionsReserved
            - SnapCommentsLayout.cardMusicLineHeight - Spacing.xs)
        #expect(SnapCommentsLayout.captionLineCapacity(columnHeight: 100, lineHeight: 20) == 5)
        #expect(SnapCommentsLayout.captionLineCapacity(columnHeight: 99, lineHeight: 20) == 4)
        #expect(SnapCommentsLayout.captionLineCapacity(columnHeight: 5, lineHeight: 20) == 1)
        #expect(SnapCommentsLayout.captionLineCapacity(columnHeight: 100, lineHeight: 0) == 1)
    }

    /// The frost ramps: the header's dissolve starts exactly at the nav
    /// zone's boundary (the frozen top inset over the band's height),
    /// never inverts on degenerate insets, and the footer's solid fraction
    /// is a genuine mid-band stop — both ends of the frame dissolve, no
    /// hard geometric edges.
    @Test func frostRampsDeriveFromTheEngagedGeometry() {
        let fraction = SnapCommentsLayout.headerFrostSolidFraction(topInset: Self.topInset)
        let band = SnapCommentsLayout.stripBottom(topInset: Self.topInset)
        #expect(abs(fraction - Self.topInset / band) < 0.001)
        #expect(fraction > 0 && fraction < 1)
        #expect(SnapCommentsLayout.headerFrostSolidFraction(topInset: 0) == 0)
        #expect(SnapCommentsLayout.headerFrostSolidFraction(topInset: 100_000) <= 0.9)
        #expect(SnapCommentsLayout.footerFrostSolidFraction > 0)
        #expect(SnapCommentsLayout.footerFrostSolidFraction < 1)
        #expect(SnapCommentsLayout.footerFrostLead > 0)
    }

    /// The layered engaged hierarchy: the comments host spans the FULL
    /// cell (content rides under the strip), the wall-to-wall header
    /// frost covers exactly screen-top → strip-bottom, the glass card
    /// floats above the frost, and the media is z-lifted above all of it
    /// for the engagement's lifetime — the sandwich is stream → frost →
    /// card → media; `clearComments` restores everything.
    @Test func installedCommentsLayerBehindTheStrip() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        // Full-height stream…
        let container = try #require(hosted.superview)
        #expect(container.frame.minY == 0)
        #expect(container.frame.maxY == Self.container.height)
        #expect(container.frame.width == Self.container.width)
        #expect(container.alpha == 1)

        // …under the header frost (wall-to-wall, top → the partition
        // line, and hit-inert: the layer must never change the engaged
        // touch surface)…
        let subviews = cell.contentView.subviews
        let effectViews = subviews.compactMap { $0 as? UIVisualEffectView }
        let cardFrame = SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset)
        let frost = try #require(effectViews.first { $0.frame != cardFrame })
        let backdrop = try #require(effectViews.first { $0.frame == cardFrame })
        #expect(frost.isHidden == false)
        #expect(frost.frame == CGRect(
            x: 0, y: 0,
            width: Self.container.width,
            height: SnapCommentsLayout.stripBottom(topInset: Self.topInset)
        ))
        #expect(frost.isUserInteractionEnabled == false)
        // Progressive, not a hard-edged slab: the band wears its gradient
        // mask, re-framed to the bounds by layout.
        #expect(frost is ProgressiveFrostView)
        let frostMask = try #require(frost.mask)
        #expect(frostMask.frame == frost.bounds)

        // …under the floating glass card (rounded, hairline-stroked,
        // wrapping the slot — not a wall-to-wall band)…
        #expect(backdrop.isHidden == false)
        #expect(backdrop.layer.cornerRadius == SnapCommentsLayout.stripCardCornerRadius)

        // …under the media (z-lifted above stream, frost, and card).
        let media = try #require(subviews.compactMap { $0 as? UIImageView }.first)
        let containerIndex = try #require(subviews.firstIndex(of: container))
        let frostIndex = try #require(subviews.firstIndex(of: frost))
        let backdropIndex = try #require(subviews.firstIndex(of: backdrop))
        let mediaIndex = try #require(subviews.firstIndex(of: media))
        #expect(containerIndex < frostIndex)
        #expect(frostIndex < backdropIndex)
        #expect(backdropIndex < mediaIndex)

        cell.setCommentsEngaged(false)
        cell.clearComments()
        #expect(hosted.superview == nil)
        #expect(container.isHidden == true)
        #expect(backdrop.isHidden == true)
        #expect(frost.isHidden == true)
        #expect(frost.effect == nil)
        // Resting z restored: media back at the bottom of the stack.
        #expect(cell.contentView.subviews.firstIndex(of: media) == 0)
    }

    /// Reuse must never leak the mutated layout into the next post.
    @Test func reuseResetsEngagement() throws {
        let cell = makeEngagedCell()
        cell.prepareForReuse()
        #expect(cell.isCommentsEngaged == false)
        let media = try #require(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        #expect(media.transform == .identity)
    }

    /// The chrome canvas is hit-transparent: bare-area touches fall through
    /// to the layers beneath (media, engaged comments), while interactive
    /// subviews (the rail) still claim theirs. Without this, the full-cell
    /// chrome swallowed every drag over the engaged comments region and
    /// handed it to the pager.
    @Test func chromeCanvasIsHitTransparent() throws {
        // A configured media chrome, so the rail is populated and visible
        // (it hides itself on an empty payload — a hidden rail can't anchor
        // the positive half of this test).
        let chrome = SnapChromeView(frame: Self.container)
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/4"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.setFixedInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        // A bare-canvas point (mid-page, far from any chrome subview).
        #expect(chrome.hitTest(CGPoint(x: 60, y: 400), with: nil) == nil)
        // A point inside the shortcut rail still resolves to rail territory
        // (frame-based: the rail is a scroll view, so its bounds origin is
        // parked at the resting inset and doesn't map 1:1 to chrome space).
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let hit = chrome.hitTest(CGPoint(x: rail.frame.midX, y: rail.frame.maxY - 20), with: nil)
        #expect(hit != nil)
        #expect(hit.map { SnapFeedCollectionView.claimsTouches($0) } == true)
    }

    /// The swipe exit's finger-connection curve: odd-symmetric, near-1:1
    /// at small drags, saturating toward ±40 — the bar rides the finger
    /// but never leaves its band.
    @Test func swipeNudgeIsDampedAndSaturating() {
        #expect(CommentsInputBar.nudgeOffset(for: 0) == 0)
        #expect(CommentsInputBar.nudgeOffset(for: -20) == -CommentsInputBar.nudgeOffset(for: 20))
        // Near-linear early…
        let small = CommentsInputBar.nudgeOffset(for: 20)
        #expect(small > 8 && small < 20)
        // …saturating late, monotonically, under the cap.
        let large = CommentsInputBar.nudgeOffset(for: 400)
        #expect(large > CommentsInputBar.nudgeOffset(for: 100))
        #expect(large < 40)
    }

    // MARK: - Engaged card content

    private func makeConfiguredCell(audioText: String?, likeCount: Int64) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0004"),
                authorID: ProfileID("profile-1"),
                authorName: "Ana",
                metaText: "@ana · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: URL(string: "mock://media/4"),
                mediaKind: audioText == nil ? .image : .video,
                thumbnailURL: nil,
                audioText: audioText,
                likeCount: likeCount
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func engagedCard(of cell: SnapFeedCell) throws -> SnapEngagedPostCardView {
        // Two effect views live in the engaged cell (header frost + glass
        // card); the card is the one hosting the content view.
        let cards = cell.contentView.subviews
            .compactMap { $0 as? UIVisualEffectView }
            .flatMap { $0.contentView.subviews.compactMap { $0 as? SnapEngagedPostCardView } }
        return try #require(cards.first)
    }

    private func metricButton(_ label: String, in card: UIView) -> UIButton? {
        var stack: [UIView] = [card]
        while let view = stack.popLast() {
            if let button = view as? UIButton, button.accessibilityLabel == label { return button }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The card is the POST's column: music credits and the metrics row
    /// render from the same display model that feeds the page — likes from
    /// the hydration snapshot, comments from the loaded streams (blank
    /// until loaded — the known-zero honesty seam), repost/save as
    /// affordance seams. Author identity must NOT render here: the nav
    /// pill already carries it (zero duplication by design).
    @Test func engagedCardRendersTheFullPost() throws {
        let cell = makeConfiguredCell(audioText: "Original audio · @ana", likeCount: 1234)
        let card = try engagedCard(of: cell)

        var labels: [UILabel] = []
        var stack: [UIView] = [card]
        while let view = stack.popLast() {
            if let label = view as? UILabel { labels.append(label) }
            stack.append(contentsOf: view.subviews)
        }
        let texts = labels.compactMap(\.text)
        #expect(texts.contains("Original audio · @ana"))
        #expect(!texts.contains("Ana"))
        #expect(!texts.contains("@ana · 3m"))

        let like = try #require(metricButton("Like", in: card))
        #expect(like.configuration?.attributedTitle.map { String($0.characters) } == "1.2k")
        // Comments blank until the streams load…
        let comments = try #require(metricButton("Comments", in: card))
        #expect(comments.configuration?.attributedTitle == nil)
        // …then follow the same seam as the chrome's surfaces.
        cell.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: [], commentCount: 56, isLoaded: true
        ))
        #expect(comments.configuration?.attributedTitle.map { String($0.characters) } == "56")
        // The affordance-only seams exist without counts.
        #expect(metricButton("Repost", in: card) != nil)
        #expect(metricButton("Save", in: card) != nil)
    }

    /// Posts without an audio line hide the music row entirely — identity
    /// lives in the nav pill; no fallback duplication.
    @Test func engagedCardHidesMusicRowWithoutAudio() throws {
        let cell = makeConfiguredCell(audioText: nil, likeCount: 0)
        let card = try engagedCard(of: cell)
        var stack: [UIView] = [card]
        var musicVisible = false
        while let view = stack.popLast() {
            if let label = view as? UILabel, label.text?.contains("audio") == true,
               !label.isHidden { musicVisible = true }
            stack.append(contentsOf: view.subviews)
        }
        #expect(musicVisible == false)
        // Zero likes render no count — a bare heart, not a lying "0".
        let like = try #require(metricButton("Like", in: card))
        #expect(like.configuration?.attributedTitle == nil)
    }

    /// The card content's choreography: offstage at rest (alpha 0, the
    /// entrance offset), risen while engaged, and back to the entrance
    /// pose on disengage — symmetric legs of the one spring.
    @Test func engagedCardRisesAndSinksWithTheSpring() throws {
        let cell = makeConfiguredCell(audioText: nil, likeCount: 0)
        let card = try engagedCard(of: cell)
        #expect(card.alpha == 0)
        #expect(card.transform.ty == SnapCommentsLayout.cardContentEntranceOffset)
        cell.setCommentsEngaged(true)
        #expect(card.alpha == 1)
        #expect(card.transform == .identity)
        cell.setCommentsEngaged(false)
        #expect(card.alpha == 0)
        #expect(card.transform.ty == SnapCommentsLayout.cardContentEntranceOffset)
    }

    /// The engaged tap boundary: a touch anywhere inside the hosted
    /// comments container — rows, gaps, the composer's band — is a STREAM
    /// touch and must never fire the background tap (which closes the
    /// engagement); touches on the strip's layers stay eligible. The
    /// boundary is the pure walk the delegate uses.
    @Test func streamTouchesNeverCollapseTheEngagement() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
        let row = UIView()
        hosted.addSubview(row)

        #expect(SnapFeedCell.isCommentsStreamTouch(row, stopAt: cell.contentView))
        #expect(SnapFeedCell.isCommentsStreamTouch(hosted, stopAt: cell.contentView))
        // The strip's layers (the glass card and the docked media) remain
        // close-eligible…
        let card = try #require(
            cell.contentView.subviews.compactMap { $0 as? UIVisualEffectView }
                .first { $0.frame == SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset) }
        )
        #expect(SnapFeedCell.isCommentsStreamTouch(card, stopAt: cell.contentView) == false)
        let media = try #require(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        #expect(SnapFeedCell.isCommentsStreamTouch(media, stopAt: cell.contentView) == false)
    }

    /// The docked tile's swipe territory: the exit pan begins inside the
    /// slot (with its thumb margin) and nowhere else — mid-stream drags
    /// belong to the comments list, footer drags to the composer bar.
    @Test func mediaSwipeRegionIsTheDockedTile() {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        #expect(cell.mediaSwipeRegionContains(CGPoint(x: slot.midX, y: slot.midY)))
        #expect(cell.mediaSwipeRegionContains(CGPoint(x: slot.maxX + Spacing.sm - 1, y: slot.midY)))
        // The caption column, the stream, and the footer band are not
        // tile territory.
        #expect(cell.mediaSwipeRegionContains(CGPoint(x: slot.maxX + 60, y: slot.midY)) == false)
        #expect(cell.mediaSwipeRegionContains(CGPoint(x: slot.midX, y: Self.container.midY)) == false)
        #expect(cell.mediaSwipeRegionContains(CGPoint(x: slot.midX, y: Self.container.height - 60)) == false)
    }

    // MARK: - Entry point

    /// Every comments surface is an engagement entry point — the empty-state
    /// pill, the subtitle zone, and the ticker band all fan into the one
    /// `onCommentsTapped` path, and each is a declared interaction root so
    /// play/pause arbitration yields to it.
    @Test func everyCommentsSurfaceIsATapEntryPoint() throws {
        let chrome = SnapChromeView(frame: Self.container)
        let pill = try #require(chrome.subviews.compactMap { $0 as? SnapCommentEmptyStateView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        for surface in [pill, subtitle, ticker] {
            #expect(surface.isUserInteractionEnabled)
            #expect(chrome.interactionRoots.contains(where: { $0 === surface }))
        }

        var fires = 0
        chrome.onCommentsTapped = { fires += 1 }
        pill.onTap?()
        subtitle.onTap?()
        ticker.onTap?()
        #expect(fires == 3)
    }

}
