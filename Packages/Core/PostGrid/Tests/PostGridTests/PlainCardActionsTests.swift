import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The closing line's actions are PLAIN (2026-09-30): no capsule, ONE ink
/// (2026-10-01; two ranks before, the primary pair read too dark) — new glyphs
/// for comments and repost, and the ink rather than an invisible box on the
/// line's column (`actionLineInset`). What stays of the capsule is its box: the press region,
/// the press wash, the hold's menu — carried by the app's one button since #934
/// (`PostCardAction`).
@MainActor
struct PlainCardActionsTests {
    private static func post(kind: GalleryPost.Kind = .text, reactions: Int64? = 160) -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: kind, isRepost: false,
            pages: kind == .text ? [] : [GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://photo/1"))],
            caption: "A note.", publishedAtMS: 0,
            authorID: ProfileID("a"), authorName: "Sofía", authorHandle: "sofia",
            reactionCount: reactions, commentCount: 12
        )
    }

    /// A row the way For You wires one: both secondary actions, a stake.
    private func row(kind: GalleryPost.Kind = .text, width: CGFloat = 370) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.configure(with: Self.post(kind: kind), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.onRepostTapped = {}
        cell.onBookmarkTapped = {}
        cell.onStake = { _ in }
        cell.stakeMenu = { UIMenu(children: []) }
        size(cell)
        return cell
    }

    private func size(_ cell: PostGridListRowCell) {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
    }

    private func walk<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { walk($0, type) }
    }

    /// The line's actions left to right: save, repost, comments, likes.
    private func actions(in cell: PostGridListRowCell) -> [AppIconButton] {
        walk(cell.contentView, AppIconButton.self)
            .filter { !$0.isHidden && $0.superviewChainIsVisible }
            .sorted { $0.convert($0.bounds, to: cell.contentView).minX < $1.convert($1.bounds, to: cell.contentView).minX }
    }

    private func glyph(of action: AppIconButton) -> String {
        action.content.symbol ?? ""
    }

    // MARK: - No container

    /// ⚠️ NO GROUND on any action — neither a material nor a painted fill —
    /// while the page indicator, a scrubber, keeps its capsule.
    @Test func noActionDrawsAContainer() throws {
        let cell = row(kind: .photo)
        let line = actions(in: cell)
        #expect(line.count == 4)
        for action in line {
            #expect(action.style == .glyph)
            #expect(action.currentGround == nil || action.buttonShapes(), "a ground only for Button Shapes")
            #expect(action.backgroundColor == nil)
        }
    }

    @Test func thePageIndicatorKeepsItsCapsule() throws {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 370, height: 200))
        let page = GalleryPost.MediaPage(thumbnailURL: URL(string: "mock://photo/1"))
        cell.configure(
            with: GalleryPost(
                id: PostID("p"), kind: .photo, isRepost: false, pages: [page, page, page],
                caption: "A note.", publishedAtMS: 0, reactionCount: 160, commentCount: 12
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        size(cell)
        let indicator = try #require(walk(cell.contentView, MediaPageIndicatorView.self).first)
        #expect(indicator.contentView.backgroundColor == .tertiarySystemFill)
    }

    // MARK: - One ink

    /// ⚠️ ONE INK for the whole line (2026-10-01): the comments and likes —
    /// glyph AND count — draw in the same `.secondaryLabel` as repost and
    /// save. Their `.label` read too dark beside the caption; the pair is
    /// ranked by its counts, not by colour (`PostCardPillView.ink`).
    @Test func everyActionDrawsInTheLinesOneInk() throws {
        #expect(PostCardPillView.ink == .secondaryLabel)
        let line = actions(in: row())
        #expect(line.count == 4)
        let (save, repost, comments, likes) = (line[0], line[1], line[2], line[3])

        for action in [save, repost, comments, likes] {
            // Glyph and count in one foreground: the configuration's.
            #expect(action.configuration?.baseForegroundColor == .secondaryLabel)
        }
        // The rank the colour no longer carries: only the primary pair has a
        // number.
        #expect(save.content.count == nil && repost.content.count == nil)
        #expect(comments.content.count == 12 && likes.content.count == 160)
    }

    /// A staked heart is the Points heart: the button's OWN filled glyph in
    /// the Points pink, no overlay laid on it (#1186) — the line's ink is the
    /// heart at rest, not a heart the viewer has filled.
    @Test func aStakedHeartIsTheLikesHeart() throws {
        let cell = row()
        let likes = try #require(actions(in: cell).last)
        cell.setViewerStake(10)
        #expect(likes.isSelected)
        #expect(likes.likesHeart == nil, "a heart laid over the button: it doubled the like (#1186)")
        #expect(likes.selectedTint == LikesSymbol.tint)
        #expect(likes.configuration?.imageColorTransformer?(.black) == LikesSymbol.tint, "the staked heart is not the Points pink")
        #expect(likes.configuration?.baseForegroundColor == .secondaryLabel, "the count stays the line's ink")
        #expect(likes.content.symbol == LikesSymbol.glyph)
        cell.setViewerStake(0)
        #expect(likes.configuration?.baseForegroundColor == .secondaryLabel)
        #expect(likes.content.symbol == PostGridListRowCell.ActionSymbol.like)
    }

    // MARK: - Glyphs

    /// ⚠️ ASKED OF THE RUNTIME: a symbol name that does not resolve draws an
    /// empty control and nothing errors.
    @Test func everyActionGlyphResolves() {
        let names = [
            PostGridListRowCell.ActionSymbol.comments, PostGridListRowCell.ActionSymbol.like,
            PostGridListRowCell.ActionSymbol.repost, PostGridListRowCell.ActionSymbol.save,
            PostGridListRowCell.ActionSymbol.saved,
            // The app-wide set the card's two new glyphs come from — the
            // notifications' comment disc draws the filled one.
            PostActionSymbol.comments, PostActionSymbol.commentsFilled, PostActionSymbol.repost
        ]
        for name in names {
            // The app's own glyphs (#1128): resolved from DesignSystem's
            // catalog, which `UIImage(systemName:)` never reads.
            #expect(UIImage.symbol(named: name) != nil, "\(name) is not a symbol on this runtime")
        }
    }

    /// The line's glyphs, by the name the drawn image carries: the app's own
    /// set (#1128) — the star (save), repost, the comment bubble, the heart.
    @Test func theLineDrawsTheNewGlyphs() {
        let line = actions(in: row())
        #expect(glyph(of: line[0]).contains(AppSymbol.save.rawValue))
        #expect(glyph(of: line[1]).contains(AppSymbol.repost.rawValue))
        #expect(glyph(of: line[2]).contains(AppSymbol.comment.rawValue))
        #expect(glyph(of: line[3]).contains("core.heart"))
    }

    // MARK: - The ink on the column

    /// ⚠️ THE INK, NOT THE BOX, sits on the line's column: the save glyph
    /// starts `actionLineInset` in, the like count ends as far from the other
    /// edge — one plain padding inside the caption's column on both sides
    /// (the evening of 2026-09-30: more air around the actions).
    /// Measured on the drawn image and the drawn label, not on the hang the
    /// cell computed — a hang that agreed with itself would pass either way.
    @Test func theInkLinesUpWithTheCaption() throws {
        for kind in [GalleryPost.Kind.text, .photo] {
            let cell = row(kind: kind)
            let line = actions(in: cell)
            // The GLYPH's ink: a symbol's image view reaches past it by the
            // image's alignment insets, which the button lays the glyph by.
            let save = try #require(line[0].imageView)
            let insets = save.image?.alignmentRectInsets ?? .zero
            let ink = save.convert(save.bounds.inset(by: insets), to: cell.contentView)
            #expect(abs(ink.minX - PostGridListRowCell.actionLineInset) < 1, "\(kind): save ink at \(ink.minX)")

            let count = try #require(line[3].titleLabel)
            let text = count.convert(count.bounds, to: cell.contentView)
            #expect(abs(cell.contentView.bounds.maxX - text.maxX - PostGridListRowCell.actionLineInset) < 1)
        }
    }

    /// The line is INSET from the caption, and by exactly one plain padding:
    /// the outer actions' boxes — what a press lights — stand on the
    /// caption's column, never past it towards the card's corner.
    @Test func theLineIsInsetOnePaddingInsideTheCaption() {
        #expect(PostGridListRowCell.actionLineInset
                == PostGridListRowCell.captionInset + PostCardPillView.plainInsets.leading)
        #expect(PostGridListRowCell.actionLineInset > PostGridListRowCell.captionInset)
        let cell = row()
        let line = actions(in: cell)
        for pill in [line[0], line[3]] {
            let box = pill.convert(pill.bounds, to: cell.contentView)
            #expect(box.minX >= PostGridListRowCell.captionInset - 0.5, "a box spilled past the caption: \(box)")
            #expect(cell.contentView.bounds.maxX - box.maxX >= PostGridListRowCell.captionInset - 0.5)
        }
    }

    /// And the hang never carries a box off the card.
    @Test func everyBoxStaysOnTheCard() {
        let cell = row()
        for pill in actions(in: cell) {
            let frame = pill.convert(pill.bounds, to: cell.contentView)
            #expect(frame.minX >= 2 && frame.maxX <= cell.contentView.bounds.maxX - 2, "\(frame)")
        }
    }

    // MARK: - The press survives the container

    /// ⚠️ A FINGER'S TARGET WITH NO SHAPE TO AIM AT: every action takes a
    /// touch anywhere in a 44pt square around its centre, and the save and
    /// repost glyphs — 28pt boxes — hand it on to their control.
    @Test func everyActionIsAFingerWide() throws {
        let cell = row()
        for pill in actions(in: cell) {
            let reach = PostMetaPillView.minimumTouchTarget / 2 - 0.5
            let centre = CGPoint(x: pill.bounds.midX, y: pill.bounds.midY)
            for offset in [CGPoint(x: -reach, y: 0), CGPoint(x: reach, y: 0),
                           CGPoint(x: 0, y: -reach), CGPoint(x: 0, y: reach)] {
                let point = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
                let hit = pill.hitTest(point, with: nil)
                #expect(hit != nil, "\(pill.accessibilityLabel ?? "?") misses at \(offset)")
                #expect(hit.map { $0 === pill || $0.isDescendant(of: pill) } ?? false)
            }
        }
    }

    /// The press survives the move to the app's button (#934) — the wash,
    /// never a dim, the hold that freezes the list and, on the like, the stake
    /// menu.
    @Test func thePressAndTheHoldMenuSurvive() throws {
        let cell = row()
        for action in actions(in: cell) {
            #expect(action.washesOnPress)
            let hold = try #require(action.debugHoldRecognizer)
            #expect(hold.view === action)
        }
        let likes = try #require(actions(in: cell).last)
        #expect(likes.menuProvider != nil)
        #expect(likes.isContextMenuInteractionEnabled)
    }

    /// A saved post's star is the full-screen post's gold (#1182, #1188 —
    /// the reference); unsaved, it keeps the line's one ink.
    @Test func aSavedStarIsTheSaveGold() throws {
        let cell = row()
        let star = try #require(actions(in: cell).first { glyph(of: $0) == AppSymbol.save.rawValue })
        #expect(ink(of: star).allSatisfy { $0 == PostCardPillView.ink })
        cell.isBookmarked = true
        #expect(star.isSelected)
        #expect(glyph(of: star) == AppSymbol.saved.rawValue)
        #expect(star.selectedTint == Palette.saveGoldOnMedia)
        let drawn = star.configuration?.imageColorTransformer?(.black)
        #expect(drawn == Palette.saveGoldOnMedia, "the saved star is drawn in \(String(describing: drawn))")
    }

    // MARK: - The flight lands on the same line

    /// ⚠️ A hero close lands a stand-in on the row: every action on the line
    /// must be where the row draws it, in the row's ink, or the swap pops.
    @Test func theStandInDrawsTheRowsLine() throws {
        let width: CGFloat = 370
        let wired = row(width: width)
        let view = RevealDismissCardView(
            post: Self.post(), width: width,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            actions: .init(repost: true, bookmark: true, saved: false),
            height: wired.bounds.height
        )
        view.frame = wired.bounds
        view.layoutIfNeeded()
        let card = try #require(view.subviews.first as? PostGridListRowCell)

        let rowLine = actions(in: wired)
        let standInLine = actions(in: card)
        #expect(rowLine.count == standInLine.count)
        for (a, b) in zip(rowLine, standInLine) {
            let rowFrame = a.convert(a.bounds, to: wired.contentView)
            let standInFrame = b.convert(b.bounds, to: card.contentView)
            #expect(abs(rowFrame.minX - standInFrame.minX) < 0.5)
            #expect(abs(rowFrame.maxX - standInFrame.maxX) < 0.5)
            #expect(abs(rowFrame.minY - standInFrame.minY) < 0.5)
            #expect(glyph(of: a) == glyph(of: b))
            #expect(ink(of: a) == ink(of: b), "the stand-in's ink must be the row's")
        }
        // And that ink is the line's one ink, on the stand-in too.
        for action in standInLine {
            #expect(ink(of: action).allSatisfy { $0 == PostCardPillView.ink })
        }
    }

    /// The colour an action draws in: its configuration's foreground.
    private func ink(of action: AppIconButton) -> [UIColor] {
        [action.configuration?.baseForegroundColor].compactMap { $0 }
    }

    /// ⚠️ A STAKED heart flies home as the Points heart — filmed without this
    /// (when it was red): the stand-in's heart at rest, the row's colour, the
    /// colour changing in the landing frame.
    @Test func aStakedHeartFliesHomeAsTheLikesHeart() throws {
        func heart(_ view: UIView) throws -> AppIconButton {
            try #require(walk(view, AppIconButton.self)
                .filter { !$0.isHidden && $0.superviewChainIsVisible }
                .max { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX })
        }
        let wired = row()
        wired.setViewerStake(10)
        let view = RevealDismissCardView(
            post: Self.post(), width: 370,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            actions: .init(repost: true, bookmark: true, saved: false, stake: 10)
        )
        let card = try #require(view.subviews.first as? PostGridListRowCell)
        #expect(try heart(card).likesHeart == nil, "a heart laid over the flying card's: it doubled the like (#1186)")
        #expect(try heart(card).configuration?.imageColorTransformer?(.black) == LikesSymbol.tint, "the flying card's heart is not the Points pink")
        #expect(try heart(card).isSelected == heart(wired.contentView).isSelected)

        // And a staking row with no count yet keeps its heart on both.
        let countless = RevealDismissCardView(
            post: Self.post(reactions: nil), width: 370,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            actions: .init(repost: false, bookmark: false, saved: false, stake: 0)
        )
        let bare = try #require(countless.subviews.first as? PostGridListRowCell)
        // The line's last VISIBLE action is the heart, not the comments.
        #expect(try heart(bare).content.symbol == PostGridListRowCell.ActionSymbol.like)
    }

    // MARK: - Motion (#934)

    /// On screen, a stake REPLACES the glyph (UIKit's symbol transition) and
    /// fades the state tint; a new count ROLLS. The answers that come with
    /// binding a post land without motion. Reduce Motion takes the fades
    /// (`AppButtonTests`).
    @Test func aStakeAndANewCountAnimateOnScreenOnly() async throws {
        let cell = row()
        let likes = try #require(actions(in: cell).last)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(cell)
        window.isHidden = false
        defer {
            cell.removeFromSuperview()
            window.isHidden = true
        }
        likes.reducesMotion = { false }
        // The host's first answer for a newly bound post lands as it is.
        cell.setViewerStake(5)
        #expect(likes.events.isEmpty, "a newly bound row lands without motion")
        // A turn of the run loop later, a change is news.
        try await Task.sleep(for: .milliseconds(20))
        cell.setViewerStake(0)
        #expect(likes.events.contains(.symbolReplace))
        #expect(likes.events.contains(.stateTint))
        cell.showLikeCount(161)
        #expect(likes.events.contains(.countRoll(up: true)))
    }

}
