import Testing
import UIKit
@testable import Feed

/// The comments sheet's detents (#2195): the collapsed one is its shape's
/// height whatever the comments; the comments only decide whether the
/// expanded one is offered; and once the sheet has expanded, the expanded
/// one is the only one — a swipe down closes it (the owner, 2026-11-10) —
/// until the next opening.
@MainActor
struct CommentsSheetDetentsTests {
    private typealias Detents = CommentsSheetDetents

    /// A 17 Pro Max's portrait sheet: 60 % of 956 pt, over a 34 pt home
    /// indicator.
    private static let resting: CGFloat = 573.6
    private static let bottomInset: CGFloat = 34
    private static let maximum: CGFloat = 894

    private func rule(offersExpanded: Bool = true) -> Detents {
        Detents(restingHeight: Self.resting, bottomInset: Self.bottomInset, offersExpanded: offersExpanded)
    }

    /// The panel's height with `count` comments: its bar and composer
    /// (~160 pt), ~60 pt a comment, and the home indicator.
    private func content(_ count: Int) -> CGFloat {
        160 + CGFloat(count) * 60 + Self.bottomInset
    }

    // MARK: - The collapsed height

    /// The cap with no comments, with few and with many.
    @Test(arguments: [0, 12, -6] as [CGFloat])
    func theCollapsedDetentIsTheCapWhateverTheComments(_ correction: CGFloat) {
        let detents = rule()
        let cap = Self.resting + correction
        #expect(detents.collapsedHeight(capCorrection: correction, maximum: Self.maximum) == cap)
        // The comments have no say in it: the same rule, before and after.
        for count in [0, 2, 200] {
            _ = detents.identifiers(contentHeight: content(count), capCorrection: correction)
            #expect(detents.collapsedHeight(capCorrection: correction, maximum: Self.maximum) == cap, "\(count)")
        }
    }

    @Test func theCollapsedDetentStaysWithinWhatUIKitAllows() {
        #expect(rule().collapsedHeight(capCorrection: 0, maximum: 400) == 400)
    }

    // MARK: - A change of content

    /// Comments arriving, replies opened, the other tab: the content's
    /// height changes whether the expanded detent is offered (portrait), and
    /// nothing else — the collapsed detent stays first, at its height.
    @Test func aContentChangeOnlyOffersTheExpandedDetent() {
        let detents = rule()
        #expect(detents.identifiers(contentHeight: nil, capCorrection: 0) == [Detents.collapsed])
        #expect(detents.identifiers(contentHeight: content(2), capCorrection: 0) == [Detents.collapsed])
        #expect(detents.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.collapsed, Detents.expanded])
        // Back to a short thread (replies closed, the other tab): taken back.
        #expect(detents.identifiers(contentHeight: content(3), capCorrection: 0) == [Detents.collapsed])
    }

    /// The comments outgrow the collapsed sheet by more than a point.
    @Test func theExpandedDetentWaitsForTheCommentsToOutgrowTheSheet() {
        let detents = rule()
        let exact = Self.resting + Self.bottomInset
        #expect(!detents.isExpandable(contentHeight: exact, capCorrection: 0))
        #expect(!detents.isExpandable(contentHeight: exact + 1, capCorrection: 0))
        #expect(detents.isExpandable(contentHeight: exact + 2, capCorrection: 0))
        // The floating sheet's correction raises the bar with it.
        #expect(!detents.isExpandable(contentHeight: exact + 2, capCorrection: 12))
    }

    /// Square, 4:3 and 16:9 have no expanded detent, however many comments.
    @Test func aFullWidthShapeHasNoExpandedDetent() {
        let fullWidth = CommentsSheetShape.standardCatalogue.filter { $0.layout == .fullWidth }
        #expect(fullWidth.count == 3)
        for shape in fullWidth {
            let picture = CGSize(width: shape.ratioWidth * 300, height: shape.ratioHeight * 300)
            let detents = rule(offersExpanded: SnapCommentsSheetSession.offersExpandedDetent(picture: picture))
            #expect(detents.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.collapsed], "\(shape)")
            var selected = detents
            selected.select(Detents.expanded)
            #expect(!selected.hasExpanded, "\(shape)")
        }
    }

    // MARK: - Expanded, then a swipe down

    /// Once the expanded detent is selected, it is the only one: a swipe
    /// down closes the sheet natively, never stopping at the collapsed
    /// height — whatever the comments do meanwhile.
    @Test func onceExpandedTheExpandedDetentIsTheOnlyOne() {
        var detents = rule()
        #expect(detents.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.collapsed, Detents.expanded])
        detents.select(Detents.expanded)
        #expect(detents.hasExpanded)
        for count in [0, 2, 200] {
            #expect(detents.identifiers(contentHeight: content(count), capCorrection: 0) == [Detents.expanded], "\(count)")
        }
        // Selecting the collapsed one in between does not bring it back:
        // only the preview's button, or a new opening, does.
        detents.select(Detents.collapsed)
        #expect(detents.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.expanded])
    }

    /// The next opening is a new session, with a new rule: the collapsed
    /// detent is back.
    @Test func theCollapsedHeightIsBackAtTheNextOpening() {
        var first = rule()
        first.select(Detents.expanded)
        #expect(first.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.expanded])
        let next = rule()
        #expect(!next.hasExpanded)
        #expect(next.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.collapsed, Detents.expanded])
        #expect(next.collapsedHeight(capCorrection: 0, maximum: Self.maximum) == Self.resting)
    }

    /// The preview's own button asks for the collapsed sheet: the rule
    /// starts over, as at an opening.
    @Test func thePreviewsButtonBringsTheCollapsedDetentBack() {
        var detents = rule()
        detents.select(Detents.expanded)
        detents.collapseAgain()
        #expect(detents.identifiers(contentHeight: content(200), capCorrection: 0) == [Detents.collapsed, Detents.expanded])
    }

    /// The session's identifiers are the rule's.
    @Test func theSessionsIdentifiersAreTheRules() {
        #expect(SnapCommentsSheetSession.detent == Detents.collapsed)
        #expect(SnapCommentsSheetSession.expandedDetent == Detents.expanded)
    }
}
