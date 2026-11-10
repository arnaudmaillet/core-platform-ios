import Testing
import UIKit
@testable import Feed

/// The rules ANY comments sheet catalogue keeps (#2195 § 5, the owner
/// 2026-11-08), written over its entries and its pairs of neighbours, never
/// over a copy of today's: adding, removing or changing a ratio needs no
/// change here. Each rule runs on today's catalogue and on one with 3:2 added
/// and the square removed — which proves it.
@MainActor
struct CommentsSheetCatalogueTests {
    private typealias Session = SnapCommentsSheetSession
    private static let layout = CommentsSheetLayout.standard

    /// Today's catalogue, and today's with 3:2 added and the square removed.
    nonisolated static let catalogues: [[CommentsSheetShape]] = {
        let today = CommentsSheetShape.standardCatalogue
        var changed = today.filter { $0.aspect != 1 }
        changed.append(CommentsSheetShape(3, by: 2))
        changed.sort { $0.aspect < $1.aspect }
        return [today, changed]
    }()

    /// An iPhone 17 Pro Max's window.
    private static let screen = CGSize(width: 440, height: 956)
    private static let safeArea = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)

    private func cut(_ size: CGSize, in catalogue: [CommentsSheetShape]) -> CGRect {
        SnapFeedCell.commentsSheetCut(of: CGRect(origin: .zero, size: size), catalogue: catalogue)
    }

    /// A picture of `ratio`, 6 000 pt tall: the side trim is lost in it.
    private func picture(_ ratio: CGFloat) -> CGSize { CGSize(width: 6000 * ratio, height: 6000) }

    private func resting(_ picture: CGSize, in catalogue: [CommentsSheetShape]) -> CGFloat {
        Session.restingHeight(screen: Self.screen, safeArea: Self.safeArea, picture: picture, catalogue: catalogue)
    }

    // MARK: - The catalogue

    @Test(arguments: catalogues)
    func theCatalogueIsSortedWithNoDuplicate(_ catalogue: [CommentsSheetShape]) {
        #expect(CommentsSheetShape.isValid(catalogue))
        #expect(!CommentsSheetShape.isValid(Array(catalogue.reversed())) || catalogue.count == 1)
        #expect(!CommentsSheetShape.isValid(catalogue + [catalogue[0]]))
        #expect(!CommentsSheetShape.isValid([]))
    }

    /// The test's own changed catalogue is what it says.
    @Test func theChangedCatalogueHasThreeTwoAndNoSquare() {
        let changed = Self.catalogues[1]
        #expect(changed.map(\.name) == ["3:4", "4:3", "3:2", "16:9"])
        #expect(changed.allSatisfy { $0.aspect != 1 })
    }

    // MARK: - The thresholds

    @Test(arguments: catalogues)
    func eachThresholdIsItsNeighboursGeometricMean(_ catalogue: [CommentsSheetShape]) {
        let thresholds = CommentsSheetShape.thresholds(of: catalogue)
        #expect(thresholds.count == catalogue.count - 1)
        for (index, threshold) in thresholds.enumerated() {
            let mean = (catalogue[index].aspect * catalogue[index + 1].aspect).squareRoot()
            #expect(abs(threshold - mean) < 0.000_001)
        }
    }

    @Test(arguments: catalogues)
    func eitherSideOfAThresholdTakesItsNeighbour(_ catalogue: [CommentsSheetShape]) {
        for (index, threshold) in CommentsSheetShape.thresholds(of: catalogue).enumerated() {
            let under = CommentsSheetShape.of(picture(threshold * 0.999), in: catalogue)
            let over = CommentsSheetShape.of(picture(threshold * 1.001), in: catalogue)
            #expect(under == catalogue[index], "under \(threshold)")
            #expect(over == catalogue[index + 1], "over \(threshold)")
        }
    }

    /// The nearest entry on a log scale: the thresholds' rule, said the other
    /// way, over pictures from very tall to very wide.
    @Test(arguments: catalogues)
    func aPictureTakesTheNearestRatioOnALogScale(_ catalogue: [CommentsSheetShape]) {
        for step in 0...60 {
            let ratio = 0.3 * pow(1.05, CGFloat(step))
            let distances = catalogue.map { abs(log(ratio) - log($0.aspect)) }
            guard let nearest = distances.min(), distances.filter({ abs($0 - nearest) < 0.000_1 }).count == 1,
                  let index = distances.firstIndex(of: nearest) else { continue }
            #expect(CommentsSheetShape.of(picture(ratio), in: catalogue) == catalogue[index], "\(ratio)")
        }
    }

    // MARK: - The cuts

    @Test(arguments: catalogues)
    func eachRatioIsUncut(_ catalogue: [CommentsSheetShape]) {
        let trim = Self.layout.landscapeSideTrim
        for shape in catalogue {
            let whole = CGSize(width: 300 * shape.ratioWidth, height: 300 * shape.ratioHeight)
            let shown = cut(whole, in: catalogue)
            #expect(shown.height == whole.height, "\(shape)")
            // A picture wider than tall loses its trimmed sides alone.
            let lost: CGFloat = whole.width > whole.height ? 2 * trim : 0
            #expect(abs(shown.width - (whole.width - lost)) < 0.001, "\(shape)")
        }
    }

    /// No cut takes more than `mostCut` of a dimension — and within the
    /// catalogue's ends, where that is enough, it reaches the shape's ratio
    /// exactly. Beyond them (a screenshot, a panorama), the rest is kept.
    @Test(arguments: catalogues)
    func noCutExceedsTheMost(_ catalogue: [CommentsSheetShape]) throws {
        let most = Self.layout.mostCut
        let first = try #require(catalogue.first).aspect
        let last = try #require(catalogue.last).aspect
        for step in 0...80 {
            let ratio = 0.25 * pow(1.04, CGFloat(step))
            let whole = picture(ratio)
            let shown = cut(whole, in: catalogue)
            #expect(1 - shown.width / whole.width <= most + 0.001, "\(ratio)")
            #expect(1 - shown.height / whole.height <= most + 0.001, "\(ratio)")
            guard ratio >= first, ratio <= last, let shape = CommentsSheetShape.of(whole, in: catalogue) else { continue }
            let needed = 1 - min(ratio, shape.aspect) / max(ratio, shape.aspect)
            guard needed < most - 0.000_1 else { continue }
            #expect(abs(shown.width / shown.height / shape.aspect - 1) < 0.001, "\(ratio) → \(shape)")
        }
    }

    // MARK: - The heights

    /// Each shape gets ONE height, the same with 0, 2 or 200 comments; only
    /// whether the expanded detent is offered follows them, and only over a
    /// shape that offers it.
    @Test(arguments: catalogues)
    func eachShapeGetsOneHeightWhateverItsComments(_ catalogue: [CommentsSheetShape]) {
        let bottomInset = Self.safeArea.bottom
        // The panel's height with 0, 2 and 200 comments: its bar and
        // composer (~160 pt), and ~60 pt a comment.
        let contents: [CGFloat?] = [nil, 160 + 2 * 60 + bottomInset, 160 + 200 * 60 + bottomInset]
        for shape in catalogue {
            let shown = cut(picture(shape.aspect), in: catalogue).size
            let height = resting(shown, in: catalogue)
            let rule = CommentsSheetDetents(
                restingHeight: height, bottomInset: bottomInset,
                offersExpanded: Session.offersExpandedDetent(picture: shown, catalogue: catalogue)
            )
            #expect(rule.offersExpanded == shape.offersExpandedDetent, "\(shape)")
            for content in contents {
                #expect(rule.collapsedHeight(capCorrection: 0, maximum: 900) == min(900, height), "\(shape)")
                let identifiers = rule.identifiers(contentHeight: content, capCorrection: 0)
                #expect(identifiers.first == CommentsSheetDetents.collapsed, "\(shape)")
                let expandable = shape.offersExpandedDetent && (content ?? 0) > 2000
                #expect(identifiers.contains(CommentsSheetDetents.expanded) == expandable, "\(shape) \(String(describing: content))")
            }
        }
    }

    /// The layout decides the height: a shape that shrinks into the room
    /// rests between the floor and the ceiling; a full-width one leaves its
    /// media the whole width, or stops at the minimum sheet.
    @Test(arguments: catalogues)
    func eachShapesLayoutDecidesItsHeight(_ catalogue: [CommentsSheetShape]) {
        let layout = Self.layout
        let screen = Self.screen
        for shape in catalogue {
            let shown = cut(picture(shape.aspect), in: catalogue).size
            let height = resting(shown, in: catalogue)
            #expect(height <= screen.height * layout.ceilingShare, "\(shape)")
            switch shape.layout {
            case .shrinksIntoRoom:
                #expect(height >= screen.height * layout.floorShare, "\(shape)")
            case .fullWidth:
                let media = (screen.width - 2 * layout.mediaSideMargin) * shown.height / shown.width
                let room = screen.height - Self.safeArea.bottom - height - layout.mediaGap - Self.safeArea.top
                let atMinimum = height == layout.minimumSheetHeight
                let atCeiling = abs(height - screen.height * layout.ceilingShare) < 0.5
                #expect(abs(room - media) < 0.5 || atMinimum || atCeiling, "\(shape)")
            }
        }
    }

    // MARK: - The launch argument (DEBUG)

    #if DEBUG
    @Test func theLaunchArgumentReplacesTheCatalogue() throws {
        let shapes = try #require(CommentsSheetShape.launchCatalogue(["app", "-comments-sheet-shapes", "3:4 1:1 3:2 16:9"]))
        #expect(shapes.map(\.name) == ["3:4", "1:1", "3:2", "16:9"])
        #expect(CommentsSheetShape.isValid(shapes))
        // The default layouts: under 1 shrinks and expands; 1 and over, full width.
        #expect(shapes.map(\.layout) == [.shrinksIntoRoom, .fullWidth, .fullWidth, .fullWidth])
        #expect(shapes.map(\.offersExpandedDetent) == [true, false, false, false])
    }

    @Test func theLaunchArgumentIsForgiving() throws {
        // Unquoted, over several arguments, up to the next option; unsorted,
        // with a duplicate and commas.
        let shapes = try #require(CommentsSheetShape.launchCatalogue(
            ["app", "-comments-sheet-shapes", "16:9,", "3:4", "16:9", "4:3", "-mock-auto-login"]
        ))
        #expect(shapes.map(\.name) == ["3:4", "4:3", "16:9"])
        #expect(CommentsSheetShape.launchCatalogue(["app"]) == nil)
        #expect(CommentsSheetShape.launchCatalogue(["app", "-comments-sheet-shapes", "wide"]) == nil)
        #expect(CommentsSheetShape.launchCatalogue(["app", "-comments-sheet-shapes", "0:1 1:0"]) == nil)
    }
    #endif
}
