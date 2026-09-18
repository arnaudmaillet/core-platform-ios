import DesignSystem
import Testing
import UIKit
@testable import Upload

@MainActor
struct MediaEditorTests {
    private struct Screen {
        let editor: MediaEditorViewController
        let navigation: UINavigationController
        let window: UIWindow
        let library: StubLibrary
        let handedOn: Handed
    }

    /// What `onNext` was given, so a test can read it after the fact.
    ///
    /// ⚠️ `@MainActor` IS STATED, NOT INHERITED. A nested type does not take the
    /// enclosing suite's isolation, and `UIViewController()` standing as a
    /// default value is main-actor isolated — which is exactly the error this
    /// first wore. `StubLibrary` beside it needs no such line: it conforms to a
    /// `@MainActor` protocol, and that infers the isolation for it.
    @MainActor
    private final class Handed {
        var items: [MediaLibraryItem]?
        var edits: [String: MediaEdits]?
        let destination = UIViewController()
    }

    /// Answers every request with a small flat picture, so a test can tell one
    /// that arrived from one that never did — and keeps the sizes it was asked
    /// for, because "full screen" is a claim about the size, not the image.
    private final class StubLibrary: MediaLibraryReading {
        private(set) var requestedSizes: [CGSize] = []

        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        /// Nothing to present against a stub — the seam exists so the picker can
        /// offer the system sheet without importing `Photos`.
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }
        /// The editor draws a video's poster frame; it never asks for the file.
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? { nil }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            requestedSizes.append(size)
            return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }
    }

    /// Hosted as the window's root: a page only exists once the canvas has a
    /// size to lay it out in.
    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let library = StubLibrary()
        let handed = Handed()
        let editor = MediaEditorViewController(items: items, library: library) { editing, edits in
            handed.items = editing
            handed.edits = edits
            return handed.destination
        }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return Screen(
            editor: editor, navigation: navigation, window: window,
            library: library, handedOn: handed
        )
    }

    /// The library answers on its own turn, so the screen is given one.
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func items(_ count: Int, videoAt videoIndex: Int? = nil) -> [MediaLibraryItem] {
        (0..<count).map { index in
            MediaLibraryItem(
                id: "item-\(index)",
                kind: index == videoIndex ? .video(duration: 9) : .photo
            )
        }
    }

    // MARK: - The canvas

    /// The picker hands over what was chosen in the order it was chosen, and
    /// that order is the page order.
    @Test func theCanvasHoldsOnePageForEachChosenItem() {
        let screen = open(Self.items(3))

        #expect(screen.editor.debugPageCount == 3)
    }

    /// One item is still a canvas, not a special case.
    @Test func aSingleChosenItemIsStillOnePage() {
        let screen = open(Self.items(1))

        #expect(screen.editor.debugPageCount == 1)
    }

    /// ⚠️ What proves "full screen" is the SIZE the picture was asked for. A
    /// canvas that had quietly kept the grid's inset adjustment would still show
    /// a picture, just not one filling the screen.
    @Test func thePictureIsAskedForAtTheScreensOwnSize() async throws {
        let screen = open(Self.items(1))

        try await settle(until: { !screen.library.requestedSizes.isEmpty })

        let asked = try #require(screen.library.requestedSizes.first)
        #expect(asked.width == 390, "the window's width, not a tile's: \(asked)")
        #expect(asked.height == 844, "and its full height: \(asked)")
        #expect(screen.editor.debugCanvasIgnoresInsets, "so it runs under the bars")
    }

    @Test func theChosenMediaReachesItsPage() async throws {
        let screen = open(Self.items(1))

        try await settle(until: { Self.pages(in: screen.window).first?.debugHasPicture == true })

        let page = try #require(Self.pages(in: screen.window).first)
        #expect(page.debugHasPicture, "the picture the library answered with")
        #expect(page.representedID == "item-0")
    }

    /// A video has no player here, so its page is its poster frame — and it says
    /// "Video" to anyone listening rather than to nobody.
    @Test func aVideosPageNamesItselfEvenThoughNothingPlaysYet() async throws {
        let screen = open(Self.items(1, videoAt: 0))

        try await settle(until: { Self.pages(in: screen.window).first?.debugHasPicture == true })

        let page = try #require(Self.pages(in: screen.window).first)
        #expect(page.accessibilityLabel == "Video")
    }

    // MARK: - The history

    private enum Band {
        static let filters = 3
        static let crop = 4
    }

    private func choose(_ band: Int, on screen: Screen) {
        screen.editor.debugCategoryBar.select(band)
        screen.window.layoutIfNeeded()
    }

    /// ⚠️ **A BAR ITEM IS BORN ENABLED.** Seen on the simulator before it was
    /// seen here: the screen opened with two bright arrows over a photograph
    /// nobody had touched, and tapping either did nothing at all — `stepBack`
    /// finds no step and returns. Nothing else re-decides them until something
    /// changes, so the bar has to ask on the way up.
    @Test func theArrowsAreDeadOnAScreenNobodyHasTouchedYet() {
        let screen = open(Self.items(2))

        #expect(!screen.editor.debugUndoItem.isEnabled)
        #expect(!screen.editor.debugRedoItem.isEnabled)
    }

    /// ⚠️ **A STEP IS THE AUTHOR'S, NOT THE BAND'S.** The arrow that stood here
    /// undid "what the open mode owns", so the same tap meant different things
    /// depending on which tools happened to be showing — and a change made in a
    /// band the author had since left could not be reached at all. Two changes
    /// in two bands, taken back in the order they were made.
    @Test func aStepBackCrossesTheBandItWasTakenIn() async throws {
        let screen = open(Self.items(1))
        choose(Band.filters, on: screen)
        let row = try #require(screen.editor.debugBand.content as? MediaFilterRowView)
        row.debugTap(.mono)
        choose(Band.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })
        screen.editor.debugCropSurface.setAngle(6)

        screen.editor.debugTapUndo()

        #expect(screen.editor.debugCrop(for: "item-0").angle == 0, "the last change came off")
        #expect(screen.editor.edits(for: "item-0").filter == .mono, "and only the last one")

        screen.editor.debugTapUndo()

        #expect(screen.editor.edits(for: "item-0").filter == .original)
        #expect(!screen.editor.debugHasEdits(for: "item-0"), "back to a page nobody had touched")
        #expect(!screen.editor.debugUndoItem.isEnabled)
        #expect(screen.editor.debugRedoItem.isEnabled, "both steps are ahead now")
    }

    @Test func aStepTakenBackCanBeTakenAgain() async throws {
        let screen = open(Self.items(1))
        choose(Band.filters, on: screen)
        let row = try #require(screen.editor.debugBand.content as? MediaFilterRowView)
        row.debugTap(.mono)
        screen.editor.debugTapUndo()
        #expect(screen.editor.edits(for: "item-0").filter == .original, "guard")
        // ⚠️ **READ THE RING AFTER THE STEP BACK, NOT ONLY AFTER THE STEP
        // FORWARD.** Asserting it only at the end proves nothing: the row is
        // ALREADY on the look the redo restores, so a row that is never
        // re-stated at all reads as correct. Measured — deleting the mode's
        // `editsWereRestored` left this test green until this line existed.
        #expect(row.debugSelected == .original,
                "the ring stayed on a look the page no longer wears")

        screen.editor.debugTapRedo()

        #expect(screen.editor.edits(for: "item-0").filter == .mono)
        #expect(row.debugSelected == .mono, "the row went on showing the look that was undone")
        #expect(!screen.editor.debugRedoItem.isEnabled)
    }

    /// ⚠️ **A NEW CHANGE ENDS THE WAY FORWARD.** What was undone and then built
    /// on top of is not a page that ever existed, and offering to walk into it
    /// would hand the author a look they never chose.
    @Test func aNewChangeAfterAStepBackClosesTheWayForward() async throws {
        let screen = open(Self.items(1))
        choose(Band.filters, on: screen)
        let row = try #require(screen.editor.debugBand.content as? MediaFilterRowView)
        row.debugTap(.mono)
        screen.editor.debugTapUndo()
        #expect(screen.editor.debugRedoItem.isEnabled, "guard")

        row.debugTap(.noir)

        #expect(!screen.editor.debugRedoItem.isEnabled)
        screen.editor.debugTapUndo()
        #expect(screen.editor.edits(for: "item-0").filter == .original,
                "the way back is the real one: got \(screen.editor.edits(for: "item-0").filter)")
    }

    /// ⚠️ **THE ARROWS ACT ON THE PICTURE IN FRONT OF THE AUTHOR.** One list for
    /// the whole screen would have a step taken on page two undo something on
    /// page one — a change they cannot see happening, on a photograph they would
    /// have to swipe back to find.
    @Test func theArrowsActOnThePageInFront() async throws {
        let screen = open(Self.items(2))
        choose(Band.filters, on: screen)
        let row = try #require(screen.editor.debugBand.content as? MediaFilterRowView)
        row.debugTap(.mono)
        #expect(screen.editor.debugUndoItem.isEnabled, "guard: page one has a step")

        screen.editor.debugScrollToPage(1)

        #expect(!screen.editor.debugUndoItem.isEnabled, "page two has a history of its own, and it is empty")
        screen.editor.debugScrollToPage(0)
        #expect(screen.editor.debugUndoItem.isEnabled, "and page one's came back with it")
        #expect(screen.editor.edits(for: "item-0").filter == .mono, "nothing was undone by the swipe")
    }

    // MARK: - The bars

    /// Bar items are laid out from the trailing edge inwards, so "Next" is
    /// stated first to sit at the edge with "Add a song" beside it.
    @Test func theTopBarKeepsItsPromisedOrder() throws {
        let screen = open(Self.items(2))

        // ⚠️ **THE TRAILING SIDE IS JUST "Next" NOW.** The fill/fit glyph used to
        // stand beside it; it has gone to the crop tools, where it is reachable
        // at the moment it means something.
        let right = try #require(screen.editor.navigationItem.rightBarButtonItems)
        #expect(right.count == 1, "got \(right.map { $0.title ?? $0.accessibilityLabel ?? "?" })")
        #expect(right.first?.title == "Next", "Next takes the edge")
        #expect(screen.editor.debugFitActionName == "Fit the picture",
                "named for what it will DO: the canvas fills, so the glyph offers fit")
        // ⚠️ **THE CHEVRON IS UIKit'S NOW, AND THAT IS WHAT KEEPS THE
        // BACK-SWIPE.** A custom leading item stands IN PLACE of the back button
        // and UIKit disables the interactive pop along with it — silently, so no
        // assertion about the bar can catch the loss. The flag below is the
        // difference, and it is asserted because only a real edge drag on a
        // device would otherwise reveal it.
        let left = try #require(screen.editor.navigationItem.leftBarButtonItems)
        // ⚠️ **AN ICON NOW, SO THE ASSERTION IS ON THE SPOKEN NAME.** The words
        // "Save draft" cost more than sixty points beside a chevron and an undo
        // arrow, which is more than an SE's bar has to give —
        // `navbar-leading-selector-collapse` records this family of screens
        // losing a control to exactly that. A titleless item asserted by `title`
        // reads as `[nil]`, which is why this asks the accessibility label: an
        // icon button with no spoken name is a button VoiceOver cannot announce.
        #expect(left.map(\.accessibilityLabel) == ["Save draft", "Undo", "Redo"],
                "the draft and the two history arrows; the chevron is the system's")
        #expect(left.allSatisfy { $0.image != nil }, "an icon bar item with no icon is a blank capsule")
        #expect(screen.editor.navigationItem.leftItemsSupplementBackButton)
        #expect(
            screen.editor.navigationItem.backButtonDisplayMode == .minimal,
            "the chevron the NEXT screen wears carries no word"
        )
    }

    /// The strip carries the editing categories, in the toolbar, with no backdrop
    /// of its own — the toolbar already supplies one.
    /// The foot reads `[song][categories]`, in that order, both leading.
    @Test func theSoundPillLeadsTheCategoryStripInTheToolbar() {
        let screen = open(Self.items(1))

        let hosted = (screen.editor.toolbarItems ?? []).compactMap(\.customView)
        #expect(hosted.count == 2, "the pill and the strip, and nothing else")
        #expect(hosted.first is SoundPillView, "the song leads: \(hosted)")
        #expect(hosted.last is IconSelectorBar, "and the categories follow it")
        // A photograph is offered every category but the timeline.
        #expect(screen.editor.debugCategoryTitles
                == MediaEditorViewController.categories(for: .photo).map(\.title))
        #expect(screen.editor.debugCategoryBar.suppressesBackdrop, "no bubble inside a bubble")
        #expect(screen.navigation.isToolbarHidden == false, "raised by the screen itself")
    }

    /// ⚠️ THE REGRESSION THIS PINS: a tap sets `selectedIndex` and sends
    /// `.valueChanged`, but the pill is placed by `setProgress` — which only a
    /// host calls. With no pager here and no action wired, tapping a category
    /// moved nothing and read as a dead control.
    @Test func tappingACategoryMovesThePillOntoIt() throws {
        let screen = open(Self.items(1))
        // ⚠️ BY NAME, NOT BY POSITION. This reached for the toolbar's FIRST
        // custom view, which was the strip until the sound pill moved down to
        // lead the band — and then the cast silently found a `SoundPillView`.
        // The order is a layout decision and belongs to the test that asserts
        // it; every other test should name what it wants.
        let bar = screen.editor.debugCategoryBar
        screen.window.layoutIfNeeded()

        bar.debugTap(2)
        screen.window.layoutIfNeeded()

        #expect(bar.selectedIndex == 2)
        let alignment = try #require(bar.debugLensAlignment)
        // ⚠️ CENTRES, NOT LEADING EDGES. The pill is the icon's square and the
        // segment is that plus its clearance, so their minX agree only by
        // accident — which is exactly how a 4pt leftward offset survived until
        // this assertion was rewritten.
        #expect(
            abs(alignment.lens.midX - alignment.segment.midX) < 1,
            "the pill sits on the segment that was tapped: \(alignment)"
        )
    }

    /// ⚠️ **A PROGRAMMATIC WINDOW HAS NO SAFE AREA, so the obvious version of
    /// this test passes with or without the fix and proves nothing.** The inset
    /// is forced here, which is what makes it discriminating: with the section
    /// measuring against `.safeArea` the page comes back exactly 90pt short.
    ///
    /// This is the one that actually pins "fill fills the window" — the two
    /// properties below govern the view's frame, which was never the problem.
    @Test func thePageFillsTheCanvasRatherThanTheSafeArea() async throws {
        let screen = open(Self.items(1))
        screen.editor.additionalSafeAreaInsets = UIEdgeInsets(top: 50, left: 0, bottom: 40, right: 0)
        screen.window.layoutIfNeeded()
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })
        screen.window.layoutIfNeeded()

        let page = try #require(Self.pages(in: screen.window).first)
        let canvas = screen.editor.debugCanvasBounds
        #expect(
            page.frame.height == canvas.height,
            "the page must be the whole canvas: page \(page.frame) vs canvas \(canvas)"
        )
        #expect(page.frame.minY == 0, "and start at its top, not below the safe area")
    }

    /// ⚠️ THE REGRESSION THIS PINS, AND IT COST A BUILD TO FIND. Making the bars
    /// transparent was NOT enough: `extendedLayoutIncludesOpaqueBars` is false by
    /// default, so the navigation controller lays this screen's view out BELOW
    /// the bars, and the canvas — pinned to that view — stopped at the chrome.
    /// Measured on device the picture was short by a nav bar at the top and a
    /// toolbar at the foot.
    @Test func theCanvasIsLaidOutUnderTheBarsRatherThanBetweenThem() {
        let screen = open(Self.items(1))

        #expect(screen.editor.extendedLayoutIncludesOpaqueBars, "or fill stops at the chrome")
        #expect(screen.editor.edgesForExtendedLayout == .all)
        #expect(screen.editor.debugCanvasIgnoresInsets, "and the grid adds none of its own")
    }

    // MARK: - The carousel indicator

    /// One picture needs no indicator: it answers a question nobody asked and
    /// puts furniture over the media.
    /// ⚠️ `throws` + `try #require`, NOT `try?`. Swallowing the requirement
    /// leaves `dots` nil and turns the expectation below into a statement about
    /// nothing — a test whose failure mode is silence.
    @Test func aSingleMediaDrawsNoIndicator() throws {
        let screen = open(Self.items(1))

        let dots = try #require(Self.dots(in: screen.window).first, "the row is built regardless")
        #expect(dots.isHidden, "and hidden, because one page needs no indicator")
    }

    @Test func severalMediaDrawOneDotEachAndMarkTheFirst() throws {
        let screen = open(Self.items(3))

        let dots = try #require(Self.dots(in: screen.window).first)
        #expect(dots.isHidden == false)
        #expect(dots.debugDotCount == 3)
        #expect(dots.debugCurrent == 0, "the mark starts on the page the canvas opens at")
    }

    private static func dots(in view: UIView) -> [MediaPageDotsView] {
        var found: [MediaPageDotsView] = []
        for subview in view.subviews {
            if let row = subview as? MediaPageDotsView { found.append(row) }
            found += dots(in: subview)
        }
        return found
    }

    // MARK: - Fill or fit

    /// The canvas has always filled, so that is where the toggle starts and what
    /// the glyph offers to undo.
    @Test func thePictureFillsTheCanvasUntilItIsToldOtherwise() async throws {
        let screen = open(Self.items(2))

        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        #expect(screen.editor.debugFit(for: "item-0") == .fill)
        let page = try #require(Self.pages(in: screen.window).first)
        #expect(page.debugContentMode == .scaleAspectFill)
    }

    /// ⚠️ **THE FILL/FIT GLYPH LEFT THE HEADER FOR THE CROP TOOLS**, beside the
    /// quarter turn and the mirror — asked for in those words. All three say
    /// how the picture sits in its frame, and none of them has anything to act
    /// on while the author is somewhere else.
    @Test func theFitGlyphLaysTheCurrentPictureWholeAndLivesWithTheCropTools() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })
        #expect(screen.editor.navigationItem.rightBarButtonItems?.count == 1,
                "the header still carries the fill/fit glyph")

        screen.editor.debugCropTools.debugTapFit()
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugFit(for: "item-0") == .fit)
        let page = try #require(Self.pages(in: screen.window).first { $0.representedID == "item-0" })
        #expect(page.debugContentMode == .scaleAspectFit, "shown whole, with the ground around it")
        #expect(screen.editor.debugCropTools.debugFitLabel == "Fill the screen",
                "and the glyph now offers the way back")
        #expect(screen.editor.debugCropTools.debugGlyphs.allSatisfy { $0 != nil },
                "a symbol that does not resolve draws an empty button")
    }

    /// ⚠️ THE REGRESSION THIS PINS. A screen-wide flag would make choosing for
    /// one picture silently re-lay every other one in the carousel — and a
    /// portrait and a landscape shot in the same post want opposite answers.
    @Test func choosingForOnePictureLeavesTheOthersAlone() async throws {
        let screen = open(Self.items(3))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        screen.editor.debugTapFit()

        #expect(screen.editor.debugFit(for: "item-0") == .fit, "the one in front of the viewer")
        #expect(screen.editor.debugFit(for: "item-1") == .fill, "and nobody else moved")
        #expect(screen.editor.debugFit(for: "item-2") == .fill)
    }

    @Test func askingTwicePutsThePictureBackAsItWas() async throws {
        let screen = open(Self.items(1))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        screen.editor.debugTapFit()
        screen.editor.debugTapFit()

        #expect(screen.editor.debugFit(for: "item-0") == .fill)
        let page = try #require(Self.pages(in: screen.window).first)
        #expect(page.debugContentMode == .scaleAspectFill)
    }

    // MARK: - Going on

    @Test func nextHandsOnWhatWasChosenInTheOrderItWasChosen() {
        let screen = open(Self.items(3))

        screen.editor.debugTapNext()

        #expect(screen.handedOn.items?.map(\.id) == ["item-0", "item-1", "item-2"])
        #expect(screen.handedOn.edits?.isEmpty == true, "nothing was changed, so nothing is carried")
        #expect(
            screen.navigation.viewControllers.last === screen.handedOn.destination,
            "and the step after this one is on top"
        )
    }

    /// ⚠️ THE REGRESSION THIS PINS: a picture the author chose to show WHOLE
    /// came back CROPPED on the next screen, because the fit choices stopped at
    /// the editor's own boundary.
    @Test func theFitChoicesTravelToTheNextScreen() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        screen.editor.debugTapFit()
        screen.editor.debugTapNext()

        #expect(screen.handedOn.edits?["item-0"]?.fit == .fit, "the one the author changed")
        #expect(screen.handedOn.edits?["item-1"] == nil, "and no opinion about the rest")
    }

    private static func pages(in view: UIView) -> [MediaEditorPageCell] {
        var found: [MediaEditorPageCell] = []
        for subview in view.subviews {
            if let page = subview as? MediaEditorPageCell { found.append(page) }
            found += pages(in: subview)
        }
        return found
    }

    // MARK: - Sliding the pill, not only tapping it

    /// ⚠️ **THE HALF `IconSelectorBarTests` CANNOT REACH.** Those pin that the
    /// selector announces a choice; nothing there says this screen subscribed.
    /// They could all pass while the editor wires nothing — a green suite over
    /// dead code, which this flow has produced more than once.
    ///
    /// Reported from a device: sliding the pill onto a category moved the pill and
    /// left the band showing the previous one until the viewer also tapped it.
    /// ⚠️ **THE SCREEN OPENS ON NOTHING.** It used to open with Effects chosen
    /// over an EMPTY band — one filled icon promising tools that were not
    /// there, and a first tap on it that counted as a reselect. Asked for as
    /// *"il faudrait que le sélecteur puisse avoir un state neutre, ce qui sera
    /// le state par défaut lorsque la fenêtre apparaîtra"*.
    @Test func theStripOpensWithNothingChosen() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        #expect(screen.editor.debugCategoryBar.selection == nil,
                "the strip opened on \(String(describing: screen.editor.debugCategoryBar.selection))")
        #expect(screen.editor.debugSelectedCategory == nil)
        #expect(!screen.editor.debugCategoryBar.debugLensIsShowing, "a pill stands over nothing")
        #expect(screen.editor.debugBand.debugIsShowing == false)
    }

    /// ⚠️ **AND A SECOND TAP PUTS THE TOOLS AWAY AGAIN** — *"si on réappuie
    /// dessus, cela met le state du sélecteur à vide"*. The same gesture used to
    /// re-open the tools it had just opened.
    @Test func tappingTheChosenCategoryAgainClosesItsTools() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })
        let filters = try #require(screen.editor.debugCategoryTitles.firstIndex(of: "Filters"))
        screen.editor.debugCategoryBar.debugTap(filters)
        #expect(screen.editor.debugBand.debugIsShowing, "guard: the tools are up")

        screen.editor.debugCategoryBar.debugTap(filters)

        #expect(screen.editor.debugCategoryBar.selection == nil,
                "the strip kept \(String(describing: screen.editor.debugCategoryBar.selection))")
        #expect(screen.editor.debugBand.debugIsShowing == false, "the tools stayed up")
        #expect(!screen.editor.debugCategoryBar.debugLensIsShowing)

        // And a third tap opens them again, rather than doing nothing at all.
        screen.editor.debugCategoryBar.debugTap(filters)
        #expect(screen.editor.debugBand.debugIsShowing)
    }

    @Test func choosingACategoryOpensWhatItOffers() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        // ⚠️ DERIVED, NEVER `categories[3]`. This strip has been reordered once
        // already and gained a fifth entry since; a hard-coded position would
        // break in silence.
        let filters = try #require(
            screen.editor.debugCategoryTitles.firstIndex(of: "Filters"),
            "the category this test is about must exist"
        )

        #expect(screen.editor.debugBand.debugIsShowing == false,
                "witness: the band starts closed, so 'it opened' below means something")

        screen.editor.debugCategoryBar.debugTap(filters)

        #expect(screen.editor.debugBand.debugIsShowing,
                "the band follows the selector, by tap or by slide alike")
    }

    /// The fifth mode exists and is reachable by name rather than by position.
    @Test func cropIsOfferedInTheSelector() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { !Self.pages(in: screen.window).isEmpty })

        #expect(screen.editor.debugCategoryTitles.contains("Crop"),
                "offered: \(screen.editor.debugCategoryTitles)")
    }
}
