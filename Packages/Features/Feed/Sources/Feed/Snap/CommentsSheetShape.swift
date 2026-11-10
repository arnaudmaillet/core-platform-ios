import CoreGraphics
import DesignSystem
import Foundation

/// A shape a picture takes under the comments sheet (#2184, #2195): a little
/// of the picture is cut, and the sheet gets ONE height per shape instead of
/// one per ratio — the same sheet with no comments or a thousand, as TikTok
/// and Instagram keep it (the owner, 2026-11-08).
///
/// THE SHAPES ARE DATA, NOT CASES (#2195 § 5, the owner 2026-11-08): one
/// ordered `catalogue`, and nothing outside it names a shape. The resting
/// height (`SnapCommentsSheetSession.restingHeight`), the expanded detent
/// (`offersExpandedDetent`), the cut (`SnapFeedCell.commentsSheetCut`) and the
/// media's growth under the sheet read an entry's properties — `aspect`,
/// `layout`, `offersExpandedDetent` — never which entry it is.
///
/// THE THRESHOLDS ARE COMPUTED, NEVER WRITTEN: a picture takes the entry whose
/// ratio is nearest its own on a log scale, which puts each threshold at the
/// geometric mean (√(a × b)) of two neighbours (`thresholds`). Adding 3:2 or
/// removing the square moves them by itself.
///
/// HOW TO ADD A RATIO: one line in `standardCatalogue`, in its place by ratio
/// (the DEBUG check at launch says if it is not). Then, on the simulator or a
/// device: the sheet over a picture of that ratio and of its neighbours' —
/// the height each gets, and what the cut takes off the pictures that now
/// fall on each side of the new thresholds (`commentsSheetMostCut` still
/// bounds it). To try a catalogue without a rebuild, DEBUG only:
/// `-comments-sheet-shapes "3:4 1:1 3:2 16:9"` (`catalogue`).
struct CommentsSheetShape: Equatable, Sendable, CustomStringConvertible {
    /// How the media and the sheet share the screen.
    enum Layout: Equatable, Sendable {
        /// The media shrinks whole into the room above a sheet between
        /// `CommentsSheetLayout.floorShare` and `ceilingShare` of the screen:
        /// at its width, a tall picture would leave the sheet no room.
        case shrinksIntoRoom
        /// The media keeps the screen's width, less its side margins, and the
        /// sheet takes exactly what is left — never under
        /// `CommentsSheetLayout.minimumSheetHeight`.
        case fullWidth
    }

    /// For logs and tests.
    let name: String
    /// The ratio the shape cuts to, as a width and a height (`3:4`), never a
    /// decimal.
    let ratioWidth: CGFloat
    let ratioHeight: CGFloat
    let layout: Layout
    /// Whether the sheet over this shape offers its expanded detent — while
    /// the comments outgrow the collapsed one (#2184).
    let offersExpandedDetent: Bool

    init(_ name: String, _ ratioWidth: CGFloat, by ratioHeight: CGFloat, layout: Layout, offersExpandedDetent: Bool) {
        self.name = name
        self.ratioWidth = ratioWidth
        self.ratioHeight = ratioHeight
        self.layout = layout
        self.offersExpandedDetent = offersExpandedDetent
    }

    /// A shape from its ratio alone, on the simple default a tried catalogue
    /// takes (#2195 § 5): under 1, it shrinks into the room and offers the
    /// expanded detent, as portrait does; 1 and over takes the full width.
    init(_ ratioWidth: CGFloat, by ratioHeight: CGFloat) {
        let tall = ratioWidth < ratioHeight
        self.init(
            "\(Self.format(ratioWidth)):\(Self.format(ratioHeight))", ratioWidth, by: ratioHeight,
            layout: tall ? .shrinksIntoRoom : .fullWidth, offersExpandedDetent: tall
        )
    }

    /// The ratio (width / height) the shape cuts to.
    var aspect: CGFloat { ratioWidth / ratioHeight }

    var description: String { name }

    // MARK: The catalogue

    /// Today's shapes, sorted by ratio (the owner, 2026-11-08). Videos (mostly
    /// 16:9) and phone photos (mostly 4:3) keep their format; a 3:2 photo
    /// becomes 4:3 and loses 11 % of its width. Within the catalogue's ends,
    /// the worst cut is about 13 %, at a threshold.
    static let standardCatalogue: [CommentsSheetShape] = [
        CommentsSheetShape("3:4", 3, by: 4, layout: .shrinksIntoRoom, offersExpandedDetent: true),
        CommentsSheetShape("1:1", 1, by: 1, layout: .fullWidth, offersExpandedDetent: false),
        CommentsSheetShape("4:3", 4, by: 3, layout: .fullWidth, offersExpandedDetent: false),
        CommentsSheetShape("16:9", 16, by: 9, layout: .fullWidth, offersExpandedDetent: false),
    ]

    /// The catalogue the app uses: `standardCatalogue`, a constant in Release.
    /// In DEBUG, `-comments-sheet-shapes "3:4 1:1 4:3 16:9"` replaces it, so
    /// the owner can try another on a device without a rebuild — and either
    /// is checked as it is first read (`isValid`): a broken catalogue fails an
    /// assertion, not a layout.
    static let catalogue: [CommentsSheetShape] = {
        #if DEBUG
        let shapes = launchCatalogue(ProcessInfo.processInfo.arguments) ?? standardCatalogue
        assert(isValid(shapes), "The comments sheet's catalogue must be sorted by ratio, with no duplicate: \(shapes)")
        return shapes
        #else
        return standardCatalogue
        #endif
    }()

    /// At least one entry, every ratio a real one, sorted by ratio with no
    /// duplicate.
    static func isValid(_ catalogue: [CommentsSheetShape]) -> Bool {
        guard !catalogue.isEmpty else { return false }
        guard catalogue.allSatisfy({ $0.ratioWidth > 0 && $0.ratioHeight > 0 }) else { return false }
        return zip(catalogue, catalogue.dropFirst()).allSatisfy { pair in pair.0.aspect < pair.1.aspect }
    }

    /// Where a picture passes from one entry to the next: the geometric mean
    /// of the two ratios, the point equally far from both on a log scale.
    /// One fewer than the entries.
    static func thresholds(of catalogue: [CommentsSheetShape] = catalogue) -> [CGFloat] {
        zip(catalogue, catalogue.dropFirst()).map { pair in (pair.0.aspect * pair.1.aspect).squareRoot() }
    }

    /// The shape of a picture `size` — or of its cut, which keeps it: the
    /// entry nearest its ratio on a log scale, a picture on a threshold
    /// taking the wider entry. Nil for a picture not known yet.
    static func of(_ size: CGSize, in catalogue: [CommentsSheetShape] = catalogue) -> CommentsSheetShape? {
        guard size.width > 0, size.height > 0, let last = catalogue.last else { return nil }
        let ratio = size.width / size.height
        let limits = thresholds(of: catalogue)
        for (index, limit) in limits.enumerated() where ratio < limit {
            return catalogue[index]
        }
        return last
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(describing: value)
    }

    #if DEBUG
    static let launchArgument = "-comments-sheet-shapes"

    /// The catalogue `-comments-sheet-shapes` gives, nil without it or for
    /// one with no ratio read. Its value is one argument (`"3:4 1:1 4:3"`, as
    /// the debug dashboard's labs copy it) or several, up to the next
    /// option; spaces or commas between ratios. Sorted by ratio, duplicates
    /// dropped, each on the default layout (`init(_:by:)`).
    static func launchCatalogue(_ arguments: [String]) -> [CommentsSheetShape]? {
        guard let position = arguments.firstIndex(of: launchArgument) else { return nil }
        let words = arguments.dropFirst(position + 1).prefix { !$0.hasPrefix("-") }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))
        let ratios: [String] = words.flatMap { $0.components(separatedBy: separators) }.filter { !$0.isEmpty }
        var shapes: [CommentsSheetShape] = ratios.compactMap(parse)
        shapes.sort { $0.aspect < $1.aspect }
        var kept: [CommentsSheetShape] = []
        for shape in shapes where kept.last.map({ abs($0.aspect - shape.aspect) > 0.0001 }) ?? true {
            kept.append(shape)
        }
        return kept.isEmpty ? nil : kept
    }

    /// `"3:2"` as a shape on the default layout; nil for anything else.
    static func parse(_ ratio: String) -> CommentsSheetShape? {
        let parts = ratio.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return CommentsSheetShape(CGFloat(width), by: CGFloat(height))
    }
    #endif
}

/// The comments sheet's other numbers, in one place next to its catalogue
/// (#2195 § 5): today's values are the defaults (`standard`).
struct CommentsSheetLayout: Equatable, Sendable {
    /// A `shrinksIntoRoom` shape's sheet, as shares of the screen: never under
    /// the floor, which keeps the rows readable, never over the ceiling. The
    /// ceiling also bounds a `fullWidth` one.
    var floorShare: CGFloat = 0.6
    var ceilingShare: CGFloat = 0.75
    /// The shortest a `fullWidth` shape's sheet gets (#2184): its bar
    /// (~56 pt), three comment rows (~60 pt each) and its composer (~64 pt),
    /// measured on the simulator. Under it, the media shrinks to fit — a
    /// square on an iPhone SE.
    var minimumSheetHeight: CGFloat = 300
    /// The most the cut takes off a picture's width or height, half on each
    /// side (`SnapFeedCell.commentsSheetCut`): a 9:16 clip reaches 3:4 by it
    /// exactly; a picture beyond the catalogue's ends (a screenshot, a
    /// panorama) keeps the rest — no bands, no harder cut.
    var mostCut: CGFloat = 0.25
    /// What a picture wider than tall loses on each side once shrunk, in the
    /// card's points (the owner, 2026-11-03): a clip often carries a dark
    /// sliver down its sides, baked into the file (clip-98: 4 px of 1280),
    /// which its rounded corners cut through on the sides and not at the top
    /// — the curves read uneven.
    var landscapeSideTrim: CGFloat = 1.5
    /// Between the shrunk media and the screen's sides: it never touches them
    /// (the owner, 2026-11-03).
    var mediaSideMargin: CGFloat = Spacing.sm
    /// Between the shrunk media's bottom and the sheet's top.
    var mediaGap: CGFloat = Spacing.sm

    static let standard = CommentsSheetLayout()
}
