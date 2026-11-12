import CoreModels
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// The flat lists' spacing around their media (#2342): a media stretch that
/// follows a header's line stands 16pt under it, as it stands 16pt over the
/// next line, and "View all" sits 12pt under its tiles and 16pt over the next
/// post's line, its target still 44pt.
///
/// Measured on the LAID-OUT attributes of a real `DiscoverListLayout`, off
/// window — the numbers the screen draws.
@MainActor
struct DiscoverListSpacingTests {
    private static let width: CGFloat = 393

    /// What a section holds.
    private enum Stretch {
        case rows(Int)
        case pairs(Int)
        case chunk(MosaicChunk)

        var count: Int {
            switch self {
            case .rows(let count), .pairs(let count): count
            case .chunk(let chunk): chunk.tileCount
            }
        }
    }

    /// Owns the collection view AND its data source (a weak reference) — see
    /// `ChaoticSliceGutterTests.Harness`.
    @MainActor
    private final class Harness: NSObject, UICollectionViewDataSource {
        let stretches: [Stretch]
        let collectionView: UICollectionView

        init(_ stretches: [Stretch], titled: Set<Int> = [], showsViewAll: Bool = true) {
            self.stretches = stretches
            let layout = DiscoverListLayout.layout(
                chunk: { section in
                    guard stretches.indices.contains(section), case .chunk(let chunk) = stretches[section]
                    else { return nil }
                    return chunk
                },
                isPairs: { section in
                    guard stretches.indices.contains(section), case .pairs = stretches[section] else { return false }
                    return true
                },
                isTitled: { titled.contains($0) },
                showsViewAll: { showsViewAll }
            )
            collectionView = UICollectionView(
                frame: CGRect(x: 0, y: 0, width: DiscoverListSpacingTests.width, height: 4000),
                collectionViewLayout: layout
            )
            super.init()
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            collectionView.register(
                DiscoverViewAllFooterView.self,
                forSupplementaryViewOfKind: DiscoverListLayout.viewAllElementKind,
                withReuseIdentifier: DiscoverViewAllFooterView.reuseID
            )
            collectionView.register(
                UICollectionReusableView.self,
                forSupplementaryViewOfKind: PostGridListLayout.headerElementKind,
                withReuseIdentifier: "header"
            )
            collectionView.dataSource = self
            collectionView.layoutIfNeeded()
        }

        func numberOfSections(in view: UICollectionView) -> Int { stretches.count }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            stretches[section].count
        }

        func collectionView(
            _ view: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            view.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        func collectionView(
            _ view: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
        ) -> UICollectionReusableView {
            let identifier = kind == DiscoverListLayout.viewAllElementKind
                ? DiscoverViewAllFooterView.reuseID : "header"
            return view.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: identifier, for: indexPath)
        }

        /// The union of a section's items' frames.
        func extent(of section: Int) -> CGRect {
            (0..<stretches[section].count).compactMap {
                collectionView.layoutAttributesForItem(at: IndexPath(item: $0, section: section))?.frame
            }.reduce(CGRect.null) { $0.union($1) }
        }

        func footerFrame(of section: Int) -> CGRect? {
            collectionView.layoutAttributesForSupplementaryElement(
                ofKind: DiscoverListLayout.viewAllElementKind, at: IndexPath(item: 0, section: section)
            )?.frame
        }
    }

    /// A real chunk, as the planner tiles it.
    private static func chunk() throws -> MosaicChunk {
        let posts = (0..<60).map { index in
            GalleryPost(
                id: PostID("p\(index)"), kind: index % 3 == 2 ? .text : .photo, isRepost: false,
                thumbnailURL: index % 3 == 2 ? nil : URL(string: "https://example.com/\(index).jpg"),
                aspectRatio: 1.5, caption: "post \(index)", publishedAtMS: 0
            )
        }
        var planner = MosaicChunkPlanner()
        return try #require(planner.segments(for: posts, isComplete: true).compactMap(\.chunk).first)
    }

    /// The header's line (`HeroHeaderView.drawsFootHairline`) and a row's
    /// line both stand half the rows' gap outside the boundary.
    private static var lineOffset: CGFloat { PostGridListRowCell.separatorOffset }

    // MARK: - A media row: 16pt above, as below

    /// The rule's numbers: 16pt on each side of a line, 12pt of inset under
    /// the header's foot (its line stands 4pt over it), the 20pt after a run
    /// unchanged.
    @Test func theNumbers() {
        #expect(DiscoverListLayout.gapAtLine == 16)
        #expect(DiscoverListLayout.leadingMediaInset + Self.lineOffset == DiscoverListLayout.gapAtLine)
        #expect(DiscoverListLayout.leadingMediaInset == 12)
        #expect(DiscoverListLayout.gapAboveChunk - Self.lineOffset == DiscoverListLayout.gapAtLine)
        #expect(DiscoverListLayout.gapAboveChunk == 20, "the gap after a run is unchanged")
    }

    /// ⚠️ A block of pairs FIRST in the list — the profile's Posts under its
    /// header's line — stands 16pt under that line, not 4pt (#2342).
    @Test func pairsFirstStandSixteenUnderTheHeadersLine() {
        let harness = Harness([.pairs(4), .rows(3)])
        let top = harness.extent(of: 0).minY
        #expect(abs(top - DiscoverListLayout.leadingMediaInset) < 0.01, "pairs at \(top)")
        #expect(abs(top - (-Self.lineOffset) - 16) < 0.01, "16pt from the header's line")
    }

    /// The same for a chunk first in the list, with or without its "View
    /// all" — and the footer still starts at the chunk's foot.
    @Test func aChunkFirstStandsSixteenUnderTheHeadersLine() throws {
        let chunk = try Self.chunk()
        for showsViewAll in [true, false] {
            let harness = Harness([.chunk(chunk), .rows(3)], showsViewAll: showsViewAll)
            let tiles = harness.extent(of: 0)
            #expect(abs(tiles.minY - DiscoverListLayout.leadingMediaInset) < 0.01, "View all \(showsViewAll): \(tiles)")
            if showsViewAll {
                let footer = try #require(harness.footerFrame(of: 0))
                #expect(abs(footer.minY - tiles.maxY) < 0.5, "the footer starts at the chunk's foot: \(footer)")
            }
        }
    }

    /// Under the tiles, the gap is unchanged: 16pt from the tiles' foot to
    /// the next row's line (the row draws it half the gap over its head).
    @Test func underAFirstMediaRowSixteenToTheNextLine() {
        let harness = Harness([.pairs(2), .rows(3)])
        let pairs = harness.extent(of: 0)
        let row = harness.extent(of: 1)
        let line = row.minY - Self.lineOffset
        #expect(abs(line - pairs.maxY - 16) < 0.01, "\(pairs.maxY) → line \(line)")
    }

    /// A media row after a run of rows keeps its 16pt under the run's line
    /// (`gapAboveChunk`), and gets nothing more: the rule only adds the gap
    /// where it was missing.
    @Test func aMediaRowAfterARowKeepsItsSpacing() throws {
        let chunk = try Self.chunk()
        for media in [Stretch.pairs(2), .chunk(chunk)] {
            let harness = Harness([.rows(3), media, .rows(2)], showsViewAll: false)
            let rows = harness.extent(of: 0)
            let tiles = harness.extent(of: 1)
            #expect(abs(rows.minY) < 0.01, "a run first takes no inset: its rows pad themselves")
            let line = rows.maxY + Self.lineOffset
            #expect(abs(tiles.minY - line - 16) < 0.01, "\(media): line \(line) → tiles \(tiles.minY)")
        }
    }

    /// Two media rows in a row keep their spacing: the gap after the first
    /// (`gapAboveChunk`), no inset added on the second.
    @Test func twoMediaRowsInARowKeepTheirSpacing() throws {
        let chunk = try Self.chunk()
        let harness = Harness([.rows(2), .chunk(chunk), .pairs(2)], showsViewAll: false)
        let tiles = harness.extent(of: 1)
        let pairs = harness.extent(of: 2)
        #expect(abs(pairs.minY - tiles.maxY - DiscoverListLayout.gapAboveChunk) < 0.01)
    }

    /// Under a section's TITLE (the profile's History) a media stretch takes
    /// no inset: a title is not a line, and keeps its own gap.
    @Test func underASectionTitleNoInset() throws {
        let harness = Harness([.pairs(2), .rows(2)], titled: [0])
        let header = try #require(harness.collectionView.layoutAttributesForSupplementaryElement(
            ofKind: PostGridListLayout.headerElementKind, at: IndexPath(item: 0, section: 0)
        )?.frame)
        let pairs = harness.extent(of: 0)
        #expect(abs(pairs.minY - header.maxY) < 0.5, "title \(header) → pairs \(pairs)")
    }

    // MARK: - "View all": 12pt under the tiles, 16pt over the next line

    /// The footer the layout asks for is the footer's own height: the two
    /// gaps, the words from cap line to baseline, and the half-gap over the
    /// next row's head where its line stands.
    @Test func theFooterIsWhatItsGapsNeed() throws {
        let chunk = try Self.chunk()
        let harness = Harness([.rows(3), .chunk(chunk), .rows(3)])
        let scale = harness.collectionView.traitCollection.displayScale
        let footer = try #require(harness.footerFrame(of: 1))
        let expected = DiscoverViewAllFooterView.preferredHeight(displayScale: scale)
        #expect(abs(footer.height - expected) < 0.01, "\(footer.height) vs \(expected)")
        let font = DiscoverViewAllFooterView.titleFont()
        let needed = 12 + font.capHeight + 16 + Self.lineOffset
        #expect(expected >= needed && expected - needed < 1, "\(expected) for \(needed)")
        // The next row's line falls inside the footer, 16pt under the words.
        let row = harness.extent(of: 2)
        #expect(abs(row.minY - footer.maxY) < 0.01, "nothing between the footer and the next run")
    }

    /// The footer as drawn: the words' cap line 12pt under its top (the
    /// chunk's foot), their baseline 16pt over the next post's line, the
    /// target at least 44pt, the chevron on the trailing edge, and a touch
    /// in the target's overhang over the chunk reaches the control.
    @Test func viewAllTwelveUnderTheTilesSixteenOverTheLine() throws {
        let height = DiscoverViewAllFooterView.preferredHeight(displayScale: 3)
        let footer = DiscoverViewAllFooterView(frame: CGRect(x: 0, y: 0, width: Self.width - 32, height: height))
        footer.layoutIfNeeded()
        let lines = try #require(footer.debugTitleLines)
        #expect(abs(lines.capTop - DiscoverViewAllFooterView.titleTopInset) < 0.5, "cap line at \(lines.capTop)")
        #expect(DiscoverViewAllFooterView.titleTopInset == 12)
        let line = footer.bounds.height - Self.lineOffset
        #expect(abs(line - lines.baseline - DiscoverViewAllFooterView.gapBelowTitle) < 0.5,
                "baseline \(lines.baseline) → line \(line)")
        #expect(DiscoverViewAllFooterView.gapBelowTitle == 16)
        // Closer to the tiles than to the next post.
        #expect(DiscoverViewAllFooterView.titleTopInset < DiscoverViewAllFooterView.gapBelowTitle)

        let control = footer.debugControlFrame
        #expect(control.height >= 44, "the target: \(control)")
        #expect(abs(control.maxY - footer.bounds.maxY) < 0.01, "never past the footer's foot")
        #expect(control.maxX == footer.bounds.maxX, "the chevron ends on the chunk's right edge")
        #expect(control.minX > footer.bounds.midX, "right-aligned: \(control)")
        if control.minY < 0 {
            // Over the chunk's foot, above the footer's own bounds.
            let hit = footer.hitTest(CGPoint(x: control.midX, y: control.minY / 2), with: nil)
            #expect(hit != nil && hit !== footer, "the overhang takes the touch: \(String(describing: hit))")
        }
    }

    /// A footer taller than 44pt (a large text size) needs no overhang: the
    /// control is the footer's height, and the words keep their 12pt.
    @Test func aTallFooterNeedsNoOverhang() throws {
        let footer = DiscoverViewAllFooterView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        footer.layoutIfNeeded()
        let control = footer.debugControlFrame
        #expect(control.minY == 0 && control.height == 60, "\(control)")
        let lines = try #require(footer.debugTitleLines)
        #expect(abs(lines.capTop - DiscoverViewAllFooterView.titleTopInset) < 0.5)
    }
}
