import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import PostGrid

/// The closing line's actions are PLAIN (2026-09-30): no capsule, two ranks of
/// ink — comments and likes primary, repost and save secondary — new glyphs
/// for comments and repost, and the ink rather than an invisible box on the
/// caption's column. What stays of the capsule is its box: the press region,
/// the press wash, the hold's menu.
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
    private func actions(in cell: PostGridListRowCell) -> [PostCardPillView] {
        walk(cell.contentView, PostCardPillView.self)
            .filter { !$0.isHidden && $0.superviewChainIsVisible }
            .sorted { $0.convert($0.bounds, to: cell.contentView).minX < $1.convert($1.bounds, to: cell.contentView).minX }
    }

    private func glyph(of pill: PostCardPillView) -> String {
        let images = walk(pill, UIImageView.self).compactMap(\.image)
            + walk(pill, UIButton.self).compactMap { $0.configuration?.image }
        return images.map { String(describing: $0) }.joined()
    }

    // MARK: - No container

    /// ⚠️ NO GROUND on any action — neither a material nor a painted fill —
    /// while the page indicator, a scrubber, keeps its capsule.
    @Test func noActionDrawsAContainer() throws {
        let cell = row(kind: .photo)
        let line = actions(in: cell)
        #expect(line.count == 4)
        for pill in line {
            #expect(pill.contentView.backgroundColor == nil)
            #expect(pill.backgroundColor == nil)
            #expect(pill.makeGround() == nil)
            #expect(pill.effect == nil)
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

    // MARK: - Two ranks of ink

    /// Comments and likes are the card's primary actions: glyph AND count in
    /// `.label`. Repost and save are secondary: `.secondaryLabel`.
    @Test func thePrimaryPairOutranksTheSecondaryPair() throws {
        let line = actions(in: row())
        #expect(line.count == 4)
        let (save, repost, comments, likes) = (line[0], line[1], line[2], line[3])

        for secondary in [save, repost] {
            let button = try #require(walk(secondary, UIButton.self).first)
            #expect(button.configuration?.baseForegroundColor == .secondaryLabel)
        }
        for primary in [comments, likes] {
            let metric = try #require(walk(primary, PostMetricLabel.self).first)
            #expect(metric.icon.tintColor == .label)
            let count = try #require(walk(metric, UILabel.self).first { !$0.isHidden })
            #expect(count.textColor == .label, "a count follows its glyph's rank")
        }
    }

    /// A staked heart is still the points' red — the primary ink is the
    /// heart at rest, not a heart the viewer has filled.
    @Test func aStakedHeartIsStillRed() throws {
        let cell = row()
        let likes = try #require(actions(in: cell).last)
        let heart = try #require(walk(likes, PostMetricLabel.self).first)
        cell.setViewerStake(10)
        #expect(heart.icon.tintColor == PointsSymbol.tint)
        #expect(String(describing: heart.icon.image as Any).contains(PointsSymbol.glyph))
        cell.setViewerStake(0)
        #expect(heart.icon.tintColor == .label)
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
            #expect(UIImage(systemName: name) != nil, "\(name) is not a symbol on this runtime")
        }
    }

    /// The glyphs asked for on 2026-09-30, by the name the drawn image carries.
    @Test func theLineDrawsTheNewGlyphs() {
        let line = actions(in: row())
        #expect(glyph(of: line[0]).contains("system: bookmark"))
        #expect(glyph(of: line[1]).contains("system: arrow.trianglehead.2.clockwise.rotate.90"))
        #expect(glyph(of: line[2]).contains("system: ellipsis.message"))
        #expect(glyph(of: line[3]).contains("system: heart"))
    }

    // MARK: - The ink on the column

    /// ⚠️ THE INK, NOT THE BOX, sits on the caption's column: the save glyph
    /// starts where the caption starts, the like count ends where it ends.
    /// Measured on the drawn image and the drawn label, not on the hang the
    /// cell computed — a hang that agreed with itself would pass either way.
    @Test func theInkLinesUpWithTheCaption() throws {
        for kind in [GalleryPost.Kind.text, .photo] {
            let cell = row(kind: kind)
            let line = actions(in: cell)
            let save = try #require(walk(line[0], UIButton.self).first?.imageView)
            let ink = save.convert(save.bounds, to: cell.contentView)
            #expect(abs(ink.minX - PostGridListRowCell.captionInset) < 1, "\(kind): save ink at \(ink.minX)")

            let count = try #require(walk(line[3], UILabel.self).first { !$0.isHidden })
            let text = count.convert(count.bounds, to: cell.contentView)
            #expect(abs(cell.contentView.bounds.maxX - text.maxX - PostGridListRowCell.captionInset) < 0.5)
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

    /// The press is still `ActionAffordance`'s — wash, hold and, on the like,
    /// the stake menu — and a press still draws its capsule while held.
    @Test func thePressAndTheHoldMenuSurvive() throws {
        let cell = row()
        for pill in actions(in: cell) {
            let affordance = try #require(ActionAffordance.attached(to: pill))
            #expect(affordance.debugHoldRecognizer.view === pill)
        }
        let likes = try #require(actions(in: cell).last)
        #expect(ActionAffordance.attached(to: likes)?.debugHasMenu == true)
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
        }
    }
}
