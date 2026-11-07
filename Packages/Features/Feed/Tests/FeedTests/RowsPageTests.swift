import CoreModels
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The Rows page (#2170, the profile's History): one section of rows per
/// titled group, the group under the bar named, each row's view date kept on
/// its row, the trailing swipe and the menu, the author's tap and hold, and
/// the square that opens and closes the post.
@MainActor
struct RowsPageTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static let now = Date()

    private func posts(_ count: Int, textAt: Set<Int> = []) -> [GalleryPost] {
        (0..<count).map { index in
            let isText = textAt.contains(index)
            return GalleryPost(
                id: PostID("p\(index)"), kind: isText ? .text : .photo, isRepost: false,
                thumbnailURL: isText ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1, caption: "post \(index)", publishedAtMS: Int64(10_000 - index),
                authorID: ProfileID("a\(index)"), authorName: "Author \(index)", authorHandle: "author\(index)",
                reactionCount: 3
            )
        }
    }

    /// Each post viewed `index` hours ago.
    private func dates(_ posts: [GalleryPost]) -> [PostID: Date] {
        Dictionary(uniqueKeysWithValues: posts.enumerated().map { index, post in
            (post.id, Self.now.addingTimeInterval(-Double(index + 1) * 3_600))
        })
    }

    private func section(_ title: String, _ posts: [GalleryPost], _ dates: [PostID: Date]) -> PostGridPageSection {
        PostGridPageSection(title: title, posts: posts, viewedAt: dates.filter { date in posts.contains { $0.id == date.key } })
    }

    private func page() -> (any PostGridPage, ForYouGridPage) {
        let grid = ForYouGridPage(imagePipeline: ImagePipeline(fetcher: SilentFetcher()), style: ForYouGridPage.Style(.rows))
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        grid.setCorpusComplete(true)
        return (grid, grid)
    }

    private func row(_ grid: ForYouGridPage, _ id: String) throws -> PostHistoryRowCell {
        grid.layoutIfNeeded()
        return try #require(grid.debugCell(for: PostID(id)) as? PostHistoryRowCell)
    }

    @Test func theStyleMaps() {
        #expect(ForYouGridPage.Style(.rows) == .rows)
    }

    /// One section of rows per group, each titled; the group gone under the
    /// bar is named, and its name brings its first row to the bar.
    @Test func groupsAreSectionsTitledAndNamedUnderTheBar() throws {
        let all = posts(30)
        let dated = dates(all)
        let (page, grid) = page()
        var named: [PostGridPinnedSection?] = []
        page.onPinnedSectionChanged = { named.append($0) }
        page.show(.sections([
            section("Today", Array(all[0..<12]), dated),
            section("Yesterday", Array(all[12..<30]), dated)
        ]))
        page.layoutIfNeeded()
        #expect(grid.groupTitles == ["Today", "Yesterday"])
        #expect(grid.collectionView.numberOfSections == 2)
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 12)
        #expect(grid.collectionView.numberOfItems(inSection: 1) == 18)
        #expect(grid.isTitled(inSection: 0) && grid.isTitled(inSection: 1))
        #expect(grid.endsGroup(inSection: 0) && !grid.endsGroup(inSection: 1))
        #expect(grid.debugSectionHeaders().first?.title == "Today")
        #expect(page.pinnedSection == nil)
        #expect(grid.indexPath(for: 13) == IndexPath(item: 1, section: 1))
        #expect(grid.flatIndex(for: IndexPath(item: 1, section: 1)) == 13)

        let first = try #require(grid.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        grid.collectionView.contentOffset.y = first.frame.minY - grid.collectionView.adjustedContentInset.top
        grid.updatePinnedSection()
        #expect(page.pinnedSection == PostGridPinnedSection(index: 1, title: "Yesterday"))
        #expect(named.last == PostGridPinnedSection(index: 1, title: "Yesterday"))

        grid.scrollToSection(0, animated: false)
        grid.updatePinnedSection()
        #expect(page.pinnedSection?.index != 1)

        // Every row is a row: never a tile.
        #expect(all.allSatisfy { !grid.drawsAsTile($0.id) })
        // An untitled delivery is one section of rows.
        page.show(.content(all))
        page.layoutIfNeeded()
        #expect(!grid.isGrouped)
        #expect(grid.collectionView.numberOfSections == 1)
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 30)
    }

    /// Each row writes ITS post's view date — and still does once a post
    /// above it has gone.
    @Test func eachRowKeepsItsViewDateThroughARemoval() throws {
        let all = posts(6)
        let dated = dates(all)
        let (page, grid) = page()
        page.show(.sections([section("Today", Array(all[0..<4]), dated), section("Yesterday", Array(all[4..<6]), dated)]))
        for (index, post) in all.enumerated() {
            #expect(try row(grid, post.id.rawValue).debugViewedText == "\(index + 1)h")
        }
        let kept = all.filter { $0.id != PostID("p1") }
        page.show(.sections([section("Today", [kept[0], kept[1], kept[2]], dated), section("Yesterday", Array(kept[3..<5]), dated)]))
        #expect(grid.debugCell(for: PostID("p1")) == nil)
        for id in ["p0", "p2", "p3", "p4", "p5"] {
            let hours = Int(id.dropFirst())! + 1
            #expect(try row(grid, id).debugViewedText == "\(hours)h", "\(id) wore another row's date")
        }
    }

    /// A removal is expressed as one: the rows gone, and a group emptied
    /// with them; anything that moves a post is not.
    @Test func removalsAreRowsAndEmptiedGroups() throws {
        let all = posts(5)
        let old = [PostGridPageSection(title: "Today", posts: Array(all[0..<3])), PostGridPageSection(title: "Yesterday", posts: Array(all[3..<5]))]
        let oneRow = try #require(ForYouGridPage.removals(from: old, to: [
            PostGridPageSection(title: "Today", posts: [all[0], all[2]]), old[1]
        ]))
        #expect(oneRow.items == [IndexPath(item: 1, section: 0)] && oneRow.sections.isEmpty)
        let lastOfAGroup = try #require(ForYouGridPage.removals(from: old, to: [old[0]]))
        #expect(lastOfAGroup.sections == IndexSet(integer: 1))
        #expect(ForYouGridPage.removals(from: old, to: [
            PostGridPageSection(title: "Today", posts: [all[1], all[0], all[2]]), old[1]
        ]) == nil, "a reorder is not a removal")
        #expect(ForYouGridPage.removals(from: old, to: [
            PostGridPageSection(title: "Today", posts: Array(all[0..<4])), PostGridPageSection(title: "Yesterday", posts: [all[4]])
        ]) == nil, "a post moving between groups is not a removal")
        #expect(ForYouGridPage.removals(from: old, to: old) == nil, "nothing removed")
    }

    /// The trailing swipe is the host's, destructive, on the swiped row's
    /// post; the long press keeps the host's menu.
    @Test func theSwipeAndTheMenuAreTheHosts() throws {
        let all = posts(4)
        let (page, grid) = page()
        var removed: [PostID] = []
        page.rowSwipeAction = PostGridRowSwipeAction(title: "Remove from History", symbolName: "clock.badge.xmark") {
            removed.append($0.id)
        }
        page.postMenuActions = { context in [.removeFromHistory { removed.append(context.post.id) }] }
        page.show(.sections([PostGridPageSection(title: "Today", posts: all)]))
        page.layoutIfNeeded()
        let configuration = try #require(grid.trailingSwipe(at: IndexPath(item: 2, section: 0)))
        let action = try #require(configuration.actions.first)
        #expect(action.style == .destructive && action.title == "Remove from History")
        #expect(configuration.performsFirstActionWithFullSwipe)
        action.handler(action, UIView()) { _ in }
        #expect(removed == [PostID("p2")])

        let rows = grid.menuActions(for: all[1], authorID: ProfileID("a1"), anchor: UIView())
        let history = try #require(rows.compactMap { row -> (() -> Void)? in
            if case .removeFromHistory(let perform) = row { perform } else { nil }
        }.first)
        history()
        #expect(removed == [PostID("p2"), PostID("p1")])
        // The row names the swipe for VoiceOver.
        let cell = try row(grid, "p3")
        #expect(cell.accessibilityCustomActions?.map(\.name).contains("Remove from History") == true)
        // No host action, no swipe.
        page.rowSwipeAction = nil
        #expect(grid.trailingSwipe(at: IndexPath(item: 0, section: 0)) == nil)
    }

    /// The author beside content (#2145): a tap is the host's card, a hold
    /// the host's profile; with no card hook, the tap is the profile too.
    @Test func theAuthorsTapIsTheCardAndTheHoldTheProfile() throws {
        let all = posts(3)
        let (page, grid) = page()
        var events: [String] = []
        page.onAuthorTapped = { events.append("profile \($0.id.rawValue)") }
        page.onAuthorCardTapped = { events.append("card \($0.id.rawValue)") }
        page.show(.sections([PostGridPageSection(title: "Today", posts: all)]))
        let cell = try row(grid, "p1")
        cell.debugTapAuthor()
        cell.debugHoldAuthor()
        #expect(events == ["card p1", "profile p1"])
    }

    /// A media row flies its square, without counters, on the square's own
    /// corner; a text row has no flight and opens through the square's
    /// window; a flight hides the square alone.
    @Test func theSquareOpensAndClosesThePost() throws {
        let all = posts(4, textAt: [1])
        let (page, grid) = page()
        page.show(.sections([PostGridPageSection(title: "Today", posts: all)]))
        let media = try row(grid, "p0")
        let hero = try #require(grid.hero(for: PostID("p0"), in: grid))
        #expect(hero.frame == media.convert(media.mediaHeroRect, to: grid))
        #expect(hero.style == .listMedia)
        #expect(grid.rowSquareCornerRadius(for: PostID("p0")) == media.squareCornerRadius)

        #expect(grid.heroAppearance(for: PostID("p1")) == nil, "a text row flew")
        let text = try row(grid, "p1")
        let window = try #require(page.closeWindow(
            for: all[1], alignsPageToSource: true, willStageDismissal: {}, dismissalDidEnd: { _ in }
        ))
        #expect(window.rowFrame(grid) == text.convert(text.mediaHeroRect, to: grid))
        #expect(window.makeDismissStandIn(nil) is PostHistorySquareView)

        grid.setHeroHidden(true, for: PostID("p0"))
        #expect(media.isHeroMediaConcealed && !media.isHidden)
        #expect(grid.concealedPosts() == [PostID("p0")])
        grid.setHeroHidden(false, for: PostID("p0"))
        #expect(!media.isHeroMediaConcealed)
    }
}
