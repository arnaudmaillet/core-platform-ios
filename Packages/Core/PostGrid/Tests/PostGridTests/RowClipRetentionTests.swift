import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

private struct StubVideoSource: VideoSource {
    func playableURL(for url: URL) async throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(url.lastPathComponent).mp4")
    }
}

/// A card's carousel keeping its clips warm — and yielding when the feed needs
/// the players more.
///
/// ## What makes this different from the post page
///
/// A post open full-screen is the only thing drawing and may spend the whole
/// pool. A row is one of several, and the coordinator gives every chosen row a
/// player before anything is kept warm. So the row's allowance is what is LEFT
/// OVER, and these pin both halves of that: it uses the spare when there is
/// some, and it behaves exactly as it always did when there is none.
@MainActor
struct RowClipRetentionTests {
    private func url(_ name: String) -> URL { URL(string: "mock://video/\(name)")! }

    /// A row whose pages are `true` for a clip, `false` for a still.
    private func row(_ shape: [Bool], id: String = "p") -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let pages = shape.enumerated().map { index, isClip in
            GalleryPost.MediaPage(
                thumbnailURL: URL(string: "mock://thumb/\(index)"),
                videoURL: isClip ? self.url("clip-\(index)") : nil,
                aspectRatio: 1.5
            )
        }
        cell.configure(
            with: GalleryPost(
                id: PostID(id), kind: .photo, isRepost: false,
                pages: pages, caption: "Short.", publishedAtMS: 0
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        attributes.frame = cell.frame
        cell.bounds.size.height = cell.preferredLayoutAttributesFitting(attributes).frame.height
        cell.layoutIfNeeded()
        return cell
    }

    // MARK: - With an allowance

    /// ⚠️ THE CHANGE: each clip keeps its own surface, on its own page.
    @Test func aGrantedRowKeepsEachClipOnItsOwnPage() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        let first = cell.makeVideoRenderViewIfNeeded()
        let firstPage = first.superview

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        let second = cell.makeVideoRenderViewIfNeeded()

        #expect(second !== first)
        // The clip left behind is still hanging on ITS page, not evicted — which
        // is what keeps its last frame there instead of its thumbnail.
        #expect(first.superview === firstPage)
        #expect(second.superview !== firstPage)
        #expect(cell.retainedPlaybackSurfaces.count == 2)
    }

    /// Coming back finds the same surface, not a fresh one.
    @Test func returningToAClipFindsTheSurfaceItLeft() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        let first = cell.makeVideoRenderViewIfNeeded()

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 0, animated: false)
        cell.retainClips(budget: 2)

        #expect(cell.makeVideoRenderViewIfNeeded() === first)
    }

    /// Stills are not candidates: a gallery of photographs around one clip
    /// keeps one surface however generous the budget.
    @Test func photographsAreNotKept() {
        let cell = row([true, false, false])
        cell.retainClips(budget: 5)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 5)

        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    /// The allowance bounds it: three clips, room for one extra.
    @Test func theAllowanceIsARealCeiling() {
        let cell = row([true, true, true])
        for page in 0..<3 {
            cell.debugScrollCarousel(toPage: page, animated: false)
            cell.retainClips(budget: 1)
            _ = cell.makeVideoRenderViewIfNeeded()
            // The watched clip plus one kept — never the whole gallery.
            #expect(cell.retainedPlaybackSurfaces.count <= 2)
        }
    }

    // MARK: - Without one

    /// ⚠️ ZERO IS THE OLD BEHAVIOUR, EXACTLY — asserted, not assumed.
    ///
    /// The coordinator reads "this row holds more than one surface" to decide it
    /// may release a loan rather than stop it. A row that helped itself to a
    /// second surface with no allowance would therefore leave the previous
    /// clip's player bound, untracked and unreclaimable — so a granted row and
    /// an ungranted one must differ here, and the difference is asserted next to
    /// its opposite above.
    @Test func anUngrantedRowStillMovesItsOneSurface() {
        let cell = row([true, true])
        cell.retainClips(budget: 0)
        let first = cell.makeVideoRenderViewIfNeeded()
        let firstPage = first.superview

        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 0)
        let second = cell.makeVideoRenderViewIfNeeded()

        #expect(second === first)
        #expect(second.superview !== firstPage)
        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    /// Losing the allowance gives the extra surfaces back.
    @Test func withdrawingTheAllowanceReleasesWhatItBought() {
        let cell = row([true, true])
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        cell.retainClips(budget: 2)
        _ = cell.makeVideoRenderViewIfNeeded()
        #expect(cell.retainedPlaybackSurfaces.count == 2)

        let dropped = cell.retainClips(budget: 0)

        #expect(dropped.count == 1)
        #expect(cell.retainedPlaybackSurfaces.count == 1)
    }

    // MARK: - Sharing the pool

    /// ⚠️ THE BUDGET IS IN PLAYERS, NOT ROWS.
    ///
    /// A screen full of playing rows leaves nothing spare, and the retention
    /// yields rather than competing. Driven through the coordinator because the
    /// division is its decision, not the row's.
    @Test func afullScreenOfRowsLeavesNothingToKeepWarm() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 3, capacity: 3
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 3)
        let rows = (0..<3).map { row([true, true], id: "post-\($0)") }
        coordinator.setSurfaceVisible(true)

        func reconcile(page: Int) {
            coordinator.update(candidates: rows.enumerated().map { index, cell in
                .init(id: PostID("post-\(index)"), url: self.url("clip-\(page)"),
                      cell: cell, distanceFromCentre: CGFloat(index))
            })
            for cell in rows { _ = cell.makeVideoRenderViewIfNeeded() }
        }

        // ⚠️ Driven exactly like `aLoneRowMaySpendTheSpare`, its opposite. A
        // `<=` on a row that never got a surface at all would pass while proving
        // nothing, so the row is put through the same page change that makes the
        // lone row grow — and asserted NOT to grow.
        reconcile(page: 0)
        for cell in rows { cell.debugScrollCarousel(toPage: 1, animated: false) }
        reconcile(page: 1)

        for cell in rows {
            #expect(cell.retainedPlaybackSurfaces.count == 1)
        }
    }

    /// And the converse: one row on screen may spend what the others are not
    /// using. Asserted beside the case above, because a version that always
    /// granted zero would pass that one and defeat the whole feature.
    @Test func aLoneRowMaySpendTheSpare() async {
        let pool = VideoPlaybackController(
            source: StubVideoSource(), poolSize: 6, capacity: 6
        )
        let coordinator = GridVideoPlaybackCoordinator(pool: pool, maxConcurrent: 6)
        let cell = row([true, true], id: "post-0")
        coordinator.setSurfaceVisible(true)

        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-0"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()
        cell.debugScrollCarousel(toPage: 1, animated: false)
        coordinator.update(candidates: [
            .init(id: PostID("post-0"), url: url("clip-1"),
                  cell: cell, distanceFromCentre: 0)
        ])
        _ = cell.makeVideoRenderViewIfNeeded()

        #expect(cell.retainedPlaybackSurfaces.count == 2)
    }
}
