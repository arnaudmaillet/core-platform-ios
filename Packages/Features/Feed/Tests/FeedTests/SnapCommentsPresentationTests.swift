import CoreModels
import DesignSystem
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

    /// The docked slot is a perfect 1:1 square tile.
    @Test func mediaSlotIsSquare() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        #expect(slot.width == slot.height)
        #expect(slot.height == SnapCommentsLayout.mediaSlotHeight)
        #expect(slot.minX == Spacing.lg)
        #expect(slot.minY == Self.topInset + SnapCommentsLayout.stripTopPadding)
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
        // Visible but touch-inert: an interactive rail above the container
        // would eat the composer's trailing ✕ when the keyboard lifts it
        // into the rail's column.
        #expect(rail.isUserInteractionEnabled == false)
        #expect(ticker.alpha == 0)
        #expect(subtitle.alpha == 0)

        cell.setCommentsEngaged(false)
        #expect(cell.isCommentsEngaged == false)
        #expect(media.transform == .identity)
        #expect(media.layer.cornerRadius == 0)
        #expect(ticker.alpha == 1)
        #expect(subtitle.alpha == 1)
        #expect(rail.isUserInteractionEnabled == true)
    }

    /// The glass card wraps the slot with uniform padding, inset from the
    /// screen edges — a floating object, not a band.
    @Test func stripCardWrapsTheSlot() {
        let slot = SnapCommentsLayout.mediaSlotFrame(in: Self.container, topInset: Self.topInset)
        let card = SnapCommentsLayout.stripCardFrame(in: Self.container, topInset: Self.topInset)
        #expect(card.minY == slot.minY - SnapCommentsLayout.stripCardPadding)
        #expect(card.maxY == slot.maxY + SnapCommentsLayout.stripCardPadding)
        #expect(card.minX == slot.minX - SnapCommentsLayout.stripCardPadding)
        #expect(card.maxX == Self.container.width - card.minX)
        #expect(card.maxY < SnapCommentsLayout.stripBottom(topInset: Self.topInset))
    }

    /// The layered engaged hierarchy: the comments host spans the FULL cell
    /// (content rides under the strip), the frosted backdrop covers exactly
    /// screen-top → strip-bottom, and the media is z-lifted above both for
    /// the engagement's lifetime; `clearComments` restores everything.
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

        // …under the floating glass card (rounded, hairline-stroked,
        // wrapping the slot — not a wall-to-wall band)…
        let subviews = cell.contentView.subviews
        let backdrop = try #require(subviews.compactMap { $0 as? UIVisualEffectView }.first)
        #expect(backdrop.isHidden == false)
        #expect(backdrop.frame == SnapCommentsLayout.stripCardFrame(
            in: Self.container, topInset: Self.topInset
        ))
        #expect(backdrop.layer.cornerRadius == SnapCommentsLayout.stripCardCornerRadius)

        // …under the media (z-lifted above stream and backdrop).
        let media = try #require(subviews.compactMap { $0 as? UIImageView }.first)
        let containerIndex = try #require(subviews.firstIndex(of: container))
        let backdropIndex = try #require(subviews.firstIndex(of: backdrop))
        let mediaIndex = try #require(subviews.firstIndex(of: media))
        #expect(containerIndex < backdropIndex)
        #expect(backdropIndex < mediaIndex)

        cell.setCommentsEngaged(false)
        cell.clearComments()
        #expect(hosted.superview == nil)
        #expect(container.isHidden == true)
        #expect(backdrop.isHidden == true)
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
