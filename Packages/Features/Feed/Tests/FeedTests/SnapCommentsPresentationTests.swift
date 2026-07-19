import CoreContracts
import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
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

    @Test func degenerateBoundsAreSafe() {
        #expect(SnapCommentsLayout.mediaSlotFrame(in: .zero, topInset: 0) == .zero)
        #expect(SnapCommentsLayout.mediaTransform(bounds: .zero, slot: .zero) == .identity)
        #expect(SnapCommentsLayout.commentsRegionHeight(containerHeight: 10, topInset: 500) == 0)
    }

    // MARK: - Cell engagement

    /// Configures the cell as a PHOTO post (or a text-only page with
    /// `media: false`): engagement variants key off the model's media, so
    /// every engagement fixture must configure before engaging.
    private func configurePost(_ cell: SnapFeedCell, media: Bool = true) {
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0000"),
                authorID: ProfileID("profile-1"),
                authorName: "Ava",
                metaText: "@ava · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: media ? URL(string: "mock://media/0.jpg") : nil,
                mediaKind: .image,
                thumbnailURL: nil,
                audioText: media ? "Original audio · @ava" : nil
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
    }

    /// The standard engaged fixture is a PHOTO post: the dock/crop/card
    /// assertions run against the image surface, proving photo posts ride
    /// the exact video-parity pipeline (the dock loop drives both render
    /// surfaces with one transform — the video-side tests cover the other
    /// face). `media: false` builds a TEXT-ONLY page, whose engagement is
    /// the text-lead resting variant.
    private func makeEngagedCell(media: Bool = true) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell, media: media)
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
        // The "+" anchor is RAIL territory, not ticker content: it holds
        // its native seat at full presence through the engagement (only
        // its frame borrows the ticker band's edges) and it is a declared
        // interaction root, so the cell's tap arbitration yields to it in
        // both states.
        let plus = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)
        #expect(plus.alpha == 1)
        #expect(chrome.interactionRoots.contains(plus))

        cell.setCommentsEngaged(false)
        #expect(cell.isCommentsEngaged == false)
        #expect(media.transform == .identity)
        #expect(media.layer.cornerRadius == 0)
        #expect(ticker.alpha == 1)
        #expect(subtitle.alpha == 1)
        #expect(plus.alpha == 1)
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

    /// The caption column's floor and line budget: the actions row is the
    /// only bottom reservation (the audio credit lives in the native
    /// toolbar — keep-and-stack), and the line cap is whole lines,
    /// floored, never zero.
    @Test func captionColumnReservesTheActionsRow() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let floor = SnapCommentsLayout.captionColumnMaxY(slotMaxY: slot.maxY)
        #expect(floor == slot.maxY - SnapCommentsLayout.cardActionsHeight - Spacing.xs)
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
        configurePost(cell)
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

    /// REGRESSION (stranded center tile): an outbound push while engaged
    /// fires the lifecycle resign, whose Ken Burns stop once reset the
    /// media transform to identity — the docked tile became a frozen
    /// full-bleed center crop, and the return couldn't heal it (the drift
    /// rightly never restarts while engaged). The stop must settle onto
    /// the ENGAGED resting transform, and the appearance sync's re-assert
    /// must restore the dock even from a deliberately corrupted state.
    @Test func outboundResignKeepsTheDockedMediaTransform() throws {
        let cell = makeEngagedCell()
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let dock = SnapCommentsLayout.mediaTransform(bounds: Self.container, slot: slot)
        let media = try #require(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first)
        #expect(media.transform == dock)

        // The outbound push's lifecycle: activate, then resign (image
        // cells run the Ken Burns stop on this path).
        cell.willBecomeActive()
        cell.didResignActive()
        #expect(media.transform == dock)

        // The belt: even a corrupted transform snaps back to the slot on
        // the appearance re-assert; disengaged cells are untouched.
        media.transform = .identity
        cell.reassertEngagedGeometry()
        #expect(media.transform == dock)
        cell.setCommentsEngaged(false)
        cell.reassertEngagedGeometry()
        #expect(media.transform == .identity)
    }

    /// REGRESSION (phantom tile band): the docked video surface's FRAME
    /// is the full-bleed rect under the dock's uniform scale — taller
    /// than the visible square (the mask crops pixels, not hit-testing) —
    /// and, z-lifted, it ate stream touches ~65pt above/below the tile
    /// (an avatar tap on the first row dismissed the engagement). Hits on
    /// the media OUTSIDE the slot must route to the stream beneath; hits
    /// ON the tile stay the close target.
    @Test func dockedMediaHitAreaIsClippedToTheVisibleTile() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0000"),
                authorID: ProfileID("profile-1"),
                authorName: "Ava",
                metaText: "@ava · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: URL(string: "mock://media/0.mp4"),
                mediaKind: .video,
                thumbnailURL: nil,
                audioText: "Original audio · @ava"
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let video = try #require(
            cell.contentView.subviews.first { $0 is VideoRenderView }
        )
        // The phantom band exists (the premise): the frame is taller than
        // the visible square.
        #expect(video.frame.height > slot.height + 50)

        // A point in the band BELOW the slot (the first comment row's
        // territory) routes to the hosted stream, not the media.
        let bandPoint = CGPoint(x: slot.midX, y: slot.maxY + 40)
        #expect(video.frame.contains(bandPoint))
        let bandHit = try #require(cell.hitTest(bandPoint, with: nil))
        #expect(sequence(first: bandHit, next: { $0.superview }).contains { $0 === hosted })

        // A point ON the visible tile keeps hitting the media — the
        // docked tile stays the tap-to-close target.
        let tileHit = try #require(cell.hitTest(CGPoint(x: slot.midX, y: slot.midY), with: nil))
        #expect(tileHit === video)
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

    /// The card is the POST's column: the metrics row renders from the
    /// same display model that feeds the page — likes from the hydration
    /// snapshot, comments from the loaded streams (blank until loaded —
    /// the known-zero honesty seam), repost/save as affordance seams.
    /// Screen chrome must NOT duplicate here (keep-and-stack): the nav
    /// pill owns identity, the native toolbar's attribution owns the
    /// audio line.
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
        // Keep-and-stack: the native toolbar's attribution owns the audio
        // line and the nav pill owns identity — the card renders NEITHER
        // (zero duplication with visible screen chrome).
        #expect(!texts.contains("Original audio · @ana"))
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

    /// Zero likes render no count — a bare heart, not a lying "0".
    @Test func engagedCardHidesZeroCounts() throws {
        let cell = makeConfiguredCell(audioText: nil, likeCount: 0)
        let card = try engagedCard(of: cell)
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
        configurePost(cell)
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

    /// The card swipe's territory: the exit pan begins anywhere inside
    /// the floating glass card — media tile, caption column, metrics row
    /// — and nowhere else: the nav zone above the card, the mid-stream,
    /// and the footer band (the composer bar owns its own exit) stay out.
    @Test func cardSwipeRegionIsTheWholeGlassCard() {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let card = SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset)
        // The media tile…
        #expect(cell.cardSwipeRegionContains(CGPoint(x: slot.midX, y: slot.midY)))
        // …the caption/metrics column, out to the card's far edge…
        #expect(cell.cardSwipeRegionContains(CGPoint(x: card.maxX - 20, y: card.midY)))
        #expect(cell.cardSwipeRegionContains(CGPoint(x: card.midX, y: card.maxY - 4)))
        // …but not the nav zone above, the stream below, or the footer.
        #expect(cell.cardSwipeRegionContains(CGPoint(x: card.midX, y: Self.topInset / 2)) == false)
        #expect(cell.cardSwipeRegionContains(CGPoint(x: card.midX, y: Self.container.midY)) == false)
        #expect(cell.cardSwipeRegionContains(CGPoint(x: card.midX, y: Self.container.height - 60)) == false)
    }

    /// REGRESSION (feed paralysis): the card's exit pan is DISABLED for
    /// the whole default-feed lifetime — an idle enabled pan on the cell
    /// outranks the pager's own pan and eats every vertical drag, dead
    /// feed. The engagement state is the recognizer's only power switch,
    /// through every teardown path (disengage, reuse), and the begin gate
    /// must be its DELEGATE (UIKit consults the hit-tested view's
    /// `gestureRecognizerShouldBegin`, and feed touches hit deep
    /// subviews — a cell-level override alone never runs for them).
    @Test func cardSwipePanIsScopedToTheEngagementLifecycle() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let pan = try #require(cell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        #expect(pan.isEnabled == false)
        #expect(pan.delegate === cell)
        cell.setCommentsEngaged(true)
        #expect(pan.isEnabled == true)
        cell.setCommentsEngaged(false)
        #expect(pan.isEnabled == false)
        cell.setCommentsEngaged(true)
        cell.prepareForReuse()
        #expect(pan.isEnabled == false)
    }

    /// A text-only page's engagement is the media layout's card with the
    /// media hole COLLAPSED and the exits LOCKED: identical glass card at
    /// the identical frame and identical frost band, but the caption (and
    /// the card column with it) stretches to the slot's own left edge —
    /// no ghost space — and the card exit pan never arms (the engagement
    /// is the page's PERMANENT resting state; paging is the only way
    /// off). The dead-end lock is identical to media's: the container
    /// claims every touch.
    @Test func textOnlyEngagementCollapsesTheSlotAndLocksTheExits() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell, media: false)
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        // The full card sandwich, at the media layout's exact frames.
        let effectViews = cell.contentView.subviews.compactMap { $0 as? UIVisualEffectView }
        let cardFrame = SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset)
        let backdrop = try #require(effectViews.first { $0.frame == cardFrame })
        #expect(backdrop.isHidden == false)
        let frost = try #require(effectViews.first { $0.frame != cardFrame })
        #expect(frost.frame.height == SnapCommentsLayout.stripBottom(topInset: Self.topInset))
        // The caption claims the collapsed hole: leading at the slot's
        // own left edge (the card's inner padding line), full card width.
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let caption = try #require(
            cell.contentView.subviews.compactMap { $0 as? UILabel }
                .first { $0.text == "caption" && !$0.isHidden }
        )
        #expect(abs(caption.frame.minX - slot.minX) < 0.5)
        // No exit pan — the resting state is permanent.
        let pan = try #require(cell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        #expect(pan.isEnabled == false)
        // The dead-end lock is identical to media's.
        #expect(SnapFeedCollectionView.claimsTouches(hosted))
        // A MEDIA page keeps the media anchors and the armed exits.
        let mediaCell = makeEngagedCell()
        let mediaHosted = UIView()
        mediaCell.installComments(mediaHosted)
        #expect(SnapFeedCollectionView.claimsTouches(mediaHosted))
        let mediaPan = try #require(mediaCell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        #expect(mediaPan.isEnabled == true)
    }

    /// The card column's leading is the media-slot seam: past the hole
    /// normally, at the card's inner padding when the slot is collapsed
    /// (text-only posts) — the caption and actions stretch to the card's
    /// left edge with no ghost space.
    @Test func cardColumnCollapsesWithTheMediaSlot() {
        #expect(SnapEngagedPostCardView.columnLeading(slotCollapsed: false)
            == SnapCommentsLayout.stripCardPadding + SnapCommentsLayout.mediaSlotHeight + Spacing.md)
        #expect(SnapEngagedPostCardView.columnLeading(slotCollapsed: true)
            == SnapCommentsLayout.stripCardPadding)

        let card = SnapEngagedPostCardView(frame: CGRect(x: 0, y: 0, width: 374, height: 104))
        card.layoutIfNeeded()
        let actions = card.subviews.compactMap { $0 as? UIStackView }[0]
        #expect(actions.frame.minX == SnapEngagedPostCardView.columnLeading(slotCollapsed: false))
        card.setMediaSlotCollapsed(true)
        card.layoutIfNeeded()
        #expect(actions.frame.minX == SnapEngagedPostCardView.columnLeading(slotCollapsed: true))
        card.setMediaSlotCollapsed(false)
        card.layoutIfNeeded()
        #expect(actions.frame.minX == SnapEngagedPostCardView.columnLeading(slotCollapsed: false))
    }

    /// The engaged toolbar's sort selector: single-selection menu with a
    /// checkmark following the chosen order, title mirroring it, the seam
    /// firing only on genuine changes, and reset returning to the
    /// engagement-scoped default.
    @Test func commentSortButtonKeepsHonestSelectionState() throws {
        let button = SnapCommentSortButton()
        #expect(button.order == .recent)
        let titles = (button.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
        #expect(titles == SnapCommentSortButton.Order.allCases.map(\.rawValue))

        var changes: [SnapCommentSortButton.Order] = []
        button.onOrderChange = { changes.append($0) }
        button.select(.trending)
        #expect(button.order == .trending)
        // Menu rebuilt around the new state: exactly one checkmark, on it.
        let checked = (button.menu?.children ?? [])
            .compactMap { $0 as? UIAction }.filter { $0.state == .on }
        #expect(checked.map(\.title) == ["Trending"])
        // Re-selection is not a change; reset restores the default silently.
        button.select(.trending)
        button.reset()
        #expect(button.order == .recent)
        #expect(changes == [.trending])
    }

    /// The composer's trailing three-state machine (engaged bar — a close
    /// handler is wired): keyboard closed → ✕ closes the engagement;
    /// keyboard open + empty → the dismiss-keyboard face; keyboard open +
    /// text → send. The pushed screen (no close handler) keeps its
    /// permanent send regardless of the keyboard.
    @Test func composerTrailingSlotFollowsKeyboardAndText() throws {
        let bar = CommentsInputBar()
        bar.onClose = {}
        func button(_ label: String) -> UIButton? {
            bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
        }
        let send = try #require(button("Send comment"))

        // Keyboard closed, empty: the close ✕.
        #expect(button("Close comments") != nil)
        #expect(send.alpha == 0)

        // Keyboard closed, text drafted: STILL the ✕ (send needs the
        // keyboard; a parked draft keeps the close affordance).
        bar.draftText = "draft"
        #expect(button("Close comments") != nil)
        #expect(send.alpha == 0)

        // Keyboard opens over the draft: send takes the slot.
        bar.setKeyboardOpen(true)
        #expect(send.alpha == 1)
        #expect(send.isEnabled)

        // Text cleared with the keyboard up: the dismiss-keyboard face —
        // tapping must retire the keyboard, never the engagement.
        bar.draftText = ""
        #expect(button("Dismiss keyboard") != nil)
        #expect(button("Close comments") == nil)
        #expect(send.alpha == 0)

        // Keyboard retires: back to the ✕.
        bar.setKeyboardOpen(false)
        #expect(button("Close comments") != nil)

        // Pushed screen (no close handler): permanent send, no utility.
        let pushed = CommentsInputBar()
        let pushedSend = try #require(
            pushed.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Send comment" }
        )
        #expect(pushedSend.alpha == 1)
        pushed.setKeyboardOpen(true)
        #expect(pushedSend.alpha == 1)
    }

    /// The 2-level thread order: each top-level comment immediately
    /// followed by its replies oldest-first; orphaned replies (parent not
    /// in the page) are dropped, never stranded at the wrong depth.
    @Test func commentThreadingInterleavesRepliesUnderParents() {
        func view(_ id: String, parent: String = "", age: Int64 = 0) -> Comment_V1_CommentView {
            var v = Comment_V1_CommentView()
            v.commentID = id
            v.parentID = parent
            v.createdAtMs = age
            return v
        }
        let thread = CommentsRepository.threaded(
            topLevel: [view("a"), view("b"), view("c")],
            repliesByParent: [
                "a": [view("a-r1", parent: "a", age: 200), view("a-r0", parent: "a", age: 100)],
                "c": [view("c-r0", parent: "c", age: 50)],
                "ghost": [view("ghost-r0", parent: "ghost")],
            ]
        )
        #expect(thread.map(\.commentID) == ["a", "a-r0", "a-r1", "b", "c", "c-r0"])
    }

    /// A reply's display model carries the level-2 marker, and its row
    /// steps in by the standard reply indent while a parent row fills the
    /// width — the indent is the depth cue.
    @Test func replyRowsIndentByOneAvatarColumn() throws {
        let parentEntry = CommentEntry(
            id: "c0", authorID: ProfileID("p1"), authorName: "Ana Reyes",
            authorHandle: "ana", body: "parent", createdAt: Date()
        )
        let replyEntry = CommentEntry(
            id: "c0-r0", authorID: ProfileID("p2"), authorName: "Bo Chen",
            authorHandle: "bo", body: "reply", createdAt: Date(), parentID: "c0"
        )
        let parentModel = CommentDisplayModel(entry: parentEntry)
        let replyModel = CommentDisplayModel(entry: replyEntry)
        #expect(parentModel.isReply == false)
        #expect(replyModel.isReply == true)

        func settledRow(_ model: CommentDisplayModel) throws -> CGRect {
            let row = CommentRowView(model: model)
            row.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
            row.layoutIfNeeded()
            return try #require(row.subviews.first { $0 is UIStackView }).frame
        }
        #expect(try settledRow(parentModel).minX == 0)
        #expect(try settledRow(replyModel).minX == CommentRowView.replyIndent)
    }

    /// The fold's two faces: a collapsed popular thread shows the
    /// threshold's worth of replies plus the view-more seam; expansion
    /// shows the pool WITH the collapse seam at the block's bottom; small
    /// threads never grow either seam — and removing the parent from the
    /// expanded set folds the thread back exactly.
    @Test func threadPresentationTruncatesPopularThreads() {
        func model(_ id: String, parent: String? = nil) -> CommentDisplayModel {
            CommentDisplayModel(entry: CommentEntry(
                id: id, authorID: ProfileID("p"), authorName: "Ana", authorHandle: "ana",
                body: "b", createdAt: Date(timeIntervalSince1970: 0), parentID: parent
            ))
        }
        let models = [
            model("a"),
            model("a-r0", parent: "a"), model("a-r1", parent: "a"),
            model("a-r2", parent: "a"), model("a-r3", parent: "a"),
            model("b"),
            model("b-r0", parent: "b"),
        ]

        let collapsed = CommentThreadPresentation.items(from: models, expanded: [])
        #expect(collapsed == [
            .comment(models[0]), .comment(models[1]), .comment(models[2]),
            .viewMoreReplies(parentID: "a", hiddenCount: 2),
            .comment(models[5]), .comment(models[6]),
        ])

        let expanded = CommentThreadPresentation.items(from: models, expanded: ["a"])
        #expect(expanded == [
            .comment(models[0]), .comment(models[1]), .comment(models[2]),
            .comment(models[3]), .comment(models[4]),
            .collapseReplies(parentID: "a"),
            .comment(models[5]), .comment(models[6]),
        ])

        // The fold is a pure function of the set: removing the parent
        // restores the collapsed shape byte-identically.
        #expect(CommentThreadPresentation.items(from: models, expanded: []) == collapsed)
    }

    /// The header's like control: far-right on the name/time axis, count
    /// shown only when real, filled state on demand — session-local
    /// optimistic (no comment-like API yet).
    @Test func commentRowLikeControlRendersState() throws {
        let model = CommentDisplayModel(entry: CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ana Reyes",
            authorHandle: "ana", body: "body", createdAt: Date()
        ))
        let row = CommentRowView(model: model)
        var stack: [UIView] = [row]
        var like: UIButton?
        while let view = stack.popLast() {
            if let button = view as? UIButton, button.accessibilityLabel == "Like comment" { like = button }
            stack.append(contentsOf: view.subviews)
        }
        let button = try #require(like)
        #expect(button.configuration?.attributedTitle == nil) // bare heart at zero
        row.setLiked(true, count: 1)
        #expect(button.configuration?.attributedTitle.map { String($0.characters) } == "1")
        row.setLiked(false, count: 0)
        #expect(button.configuration?.attributedTitle == nil)

        // Right-aligned on the header axis: after layout, the control's
        // trailing sits at the row's trailing edge.
        row.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        row.layoutIfNeeded()
        let frameInRow = button.superview!.convert(button.frame, to: row)
        #expect(abs(frameInRow.maxX - 320) < 1)
    }

    /// The composer's reply state: the placeholder names the target and
    /// restores on clear; an idle keyboard dismissal (empty field) fires
    /// the host's reset seam, a drafted one does not.
    @Test func composerReplyStateSwapsPlaceholderAndResetsOnIdleDismiss() throws {
        let bar = CommentsInputBar()
        bar.onClose = {}
        func placeholder() -> String? {
            var stack: [UIView] = [bar]
            while let view = stack.popLast() {
                if let label = view as? UILabel, label.text?.hasPrefix("Reply to") == true || label.text == "Add a comment…" {
                    return label.text
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        #expect(placeholder() == "Add a comment…")
        bar.setReplyPlaceholder(name: "Ana Reyes")
        #expect(placeholder() == "Reply to Ana Reyes…")

        var resets = 0
        bar.onIdleDismiss = { resets += 1 }
        // Drafted dismissal keeps the reply state armed…
        bar.setKeyboardOpen(true)
        bar.draftText = "half a thought"
        bar.setKeyboardOpen(false)
        #expect(resets == 0)
        // …an idle dismissal resets it.
        bar.setKeyboardOpen(true)
        bar.draftText = ""
        bar.setKeyboardOpen(false)
        #expect(resets == 1)

        bar.setReplyPlaceholder(name: nil)
        #expect(placeholder() == "Add a comment…")
    }

    /// The keyboard-session rail yield: engaged cells concede the rail
    /// (alpha 0 — also retiring it from hit-testing) while the composer
    /// owns its risen band; resting cells never yield, and the restore
    /// side is unconditional so no teardown path can strand a hidden rail.
    @Test func keyboardRailYieldIsEngagementScoped() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)

        cell.setRailConcealed(true) // disengaged: refused
        #expect(rail.alpha == 1)

        cell.setCommentsEngaged(true)
        cell.setRailConcealed(true)
        #expect(rail.alpha == 0)
        cell.setRailConcealed(false)
        #expect(rail.alpha == 1)
    }

    /// The comments skeleton row is the messages doctrine transplanted:
    /// three shimmer bones (avatar, header, body) on the real row's
    /// geometry — and ONLY the organic content shimmers: the trailing
    /// band where the real row's like control stands is reserved empty,
    /// so no bone (not even the widest body pill) crosses into it.
    @Test func commentSkeletonRowMimicsOrganicContentOnly() {
        let row = CommentSkeletonRowView(index: 3) // widest body fraction (0.94)
        var bones: [UIView] = []
        var stack: [UIView] = [row]
        while let view = stack.popLast() {
            if view is SkeletonBoneView { bones.append(view) }
            stack.append(contentsOf: view.subviews)
        }
        #expect(bones.count == 3)
        #expect(row.isUserInteractionEnabled == false)

        row.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        row.layoutIfNeeded()
        let clearBandStart = 320 - CommentSkeletonRowView.likeColumnReservation
        for bone in bones {
            let boneMaxX = row.convert(bone.bounds, from: bone).maxX
            #expect(boneMaxX <= clearBandStart)
        }
    }

    /// The skeleton snapshot's density is viewport math, never a fixed
    /// integer: count = ceil(viewport / estimate), with the estimate a
    /// deliberate low-ball of the real row height so every form factor
    /// over-provisions (the list clips the excess) and none strands
    /// blank space above the input bar.
    @Test func skeletonDensityScalesWithTheViewport() {
        let se = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 667)
        let proMax = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 932)
        let pad = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 1366)

        // Coverage: estimate × count ≥ viewport on every device.
        #expect(CGFloat(se) * SnapCommentsLayout.skeletonRowEstimate >= 667)
        #expect(CGFloat(proMax) * SnapCommentsLayout.skeletonRowEstimate >= 932)
        #expect(CGFloat(pad) * SnapCommentsLayout.skeletonRowEstimate >= 1366)
        // Monotonic: taller viewports never get fewer rows.
        #expect(se <= proMax && proMax <= pad)
        // The estimate stays a low-ball of the measured row (~48pt) — the
        // direction that makes the division OVER-provision.
        #expect(SnapCommentsLayout.skeletonRowEstimate <= 48)
        // Pre-layout fallback (zero bounds) still blankets every iPhone.
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 0) >= proMax)
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
