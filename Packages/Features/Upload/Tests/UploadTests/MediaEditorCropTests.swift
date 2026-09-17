import DesignSystem
import Testing
import UIKit
@testable import Upload

/// Crop mode on the editor: what opening it borrows, and what leaving it gives
/// back.
///
/// ⚠️ **NO UNIT TEST CAN BEGIN THE STACK'S OWN BACK-SWIPE OR THE SHEET'S OWN
/// DISMISSAL**, so nothing here proves the screen does not pop or the sheet does
/// not close — the same limit `CarouselBackSwipeTests` states, and the reason an
/// earlier revision of this flow had 89 green tests around a rule wired to a
/// gesture that never arrived. What these pin is the STATE the screen puts the
/// canvas, the sheet and the stack into, which is the half that a test can see.
/// The other half is a drag on a device.
@MainActor
struct MediaEditorCropTests {
    private enum Mode {
        static let filters = 3
        static let crop = 4
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let navigation: UINavigationController
        let window: UIWindow
        let library: StubLibrary
        let handedOn: Handed
    }

    @MainActor
    private final class Handed {
        var edits: [String: MediaEdits]?
        let destination = UIViewController()
    }

    private final class StubLibrary: MediaLibraryReading {
        /// Every size the screen asked for, so a test can tell a render that reused
        /// what it had from one that went back to the library for it.
        private(set) var requested: [CGSize] = []

        /// ⚠️ **ONLY THE CANVAS-SIZED ONES COUNT.** The filter row asks for a 56pt
        /// chip whenever it opens, which is a different picture for a different
        /// purpose — counting it would make "did the canvas refetch?" unanswerable.
        var canvasFetches: Int { requested.filter { $0.width >= 100 }.count }

        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }
        /// The editor draws a video's poster frame; it never asks for the file.
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? { nil }
        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            requested.append(size)
            return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
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

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let handed = Handed()
        let library = StubLibrary()
        let editor = MediaEditorViewController(items: items, library: library) { _, edits in
            handed.edits = edits
            return handed.destination
        }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return Screen(editor: editor, navigation: navigation, window: window, library: library, handedOn: handed)
    }

    /// Choosing a mode the way the strip does: `select` announces, and the screen
    /// answers on that channel.
    private func choose(_ mode: Int, on screen: Screen) {
        screen.editor.debugCategoryBar.select(mode)
        screen.window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - What the band holds

    @Test func choosingCropPutsTheCropToolsInTheBand() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)

        #expect(screen.editor.debugBand.content is MediaCropToolsView,
                "got \(String(describing: screen.editor.debugBand.content))")
        #expect(screen.editor.debugIsCropping)
    }

    /// The witness: the band holds different things for different modes, so the
    /// line above is about crop and not merely about the band being filled.
    @Test func choosingFiltersPutsTheLooksThereInstead() {
        let screen = open(Self.items(1))

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugBand.content is MediaFilterRowView,
                "got \(String(describing: screen.editor.debugBand.content))")
        #expect(!screen.editor.debugIsCropping)
    }

    /// ⚠️ **IT LEAVES AT THE END OF THE FADE, NOT AT THE START OF IT.** The
    /// picture crossfades back out to the canvas over a quarter second, so the
    /// surface has to stay in the hierarchy for the length of that — which is why
    /// this settles rather than asserting in the same turn, and why the flag is
    /// checked separately. A view that never leaves is a leak; a view that leaves
    /// too early is a black flash.
    @Test func theSurfaceIsPutOnTheScreenAndTakenOffAgain() async throws {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)
        #expect(screen.editor.debugCropSurfaceIsShowing, "guard: it must really be up")

        choose(Mode.filters, on: screen)

        #expect(!screen.editor.debugIsCropping, "the mode ends at once")
        try await settle(until: { !screen.editor.debugCropSurfaceIsShowing })
        #expect(!screen.editor.debugCropSurfaceIsShowing,
                "a flag saying 'not cropping' is not the same as a view that has left")
    }

    /// ⚠️ **THE SAME PHOTOGRAPH TWICE, ONE OF THEM UNCUT.** The surface's BOX is
    /// inset so it never runs under the navigation bar, and the first cut inset the
    /// whole view with it — which left the canvas showing its own untouched copy in
    /// the band above, seen on a device. The view now spans everything and is
    /// opaque, so there is nothing to see behind it and nothing to hide: covering
    /// is what makes the second copy impossible, and covering cannot be mistimed.
    @Test func theSurfaceCoversTheCanvasCompletely() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)
        screen.window.layoutIfNeeded()

        let surface = screen.editor.debugCropSurface
        let band = screen.editor.debugBand.frame
        #expect(surface.frame.minY == 0 && surface.frame.width == screen.editor.view.bounds.width,
                "it must run to the very top, under the bar: \(surface.frame)")
        #expect(surface.frame.maxY >= band.minY - 0.5,
                "and down to whatever the band is holding: \(surface.frame) vs band \(band)")
        #expect(surface.backgroundColor == .systemBackground,
                "and be opaque: \(String(describing: surface.backgroundColor))")
        // ⚠️ BELOW THE BAND THE CANVAS DOES SHOW, AND IT SHOULD: that strip is
        // behind the dissolve, which exists to have something to dissolve.
        #expect(surface.debugSurface.minY > screen.editor.view.safeAreaInsets.top,
                "while the BOX still clears the chrome: \(surface.debugSurface)")
    }

    // MARK: - What it borrows

    @Test func theCanvasStopsPagingWhileTheSurfaceIsUpAndPagesAgainAfter() {
        let screen = open(Self.items(3))
        #expect(screen.editor.debugCanvasScrolls, "guard: it pages to begin with")

        choose(Mode.crop, on: screen)
        let whileCropping = screen.editor.debugCanvasScrolls

        choose(Mode.filters, on: screen)

        #expect(!whileCropping, "a drag on the picture must move the picture, not the page")
        #expect(screen.editor.debugCanvasScrolls, "and paging comes back: it was borrowed, not taken")
    }

    /// ⚠️ **THE SHEET IS TOLD, NOT OUT-ARBITRATED.** Its dismissal is
    /// velocity-dominated — measured on the filter row at 139pt/~3000pt/s — so no
    /// gesture priority makes a downward drag on the picture safe.
    @Test func theSheetIsPinnedShutWhileTheSurfaceIsUp() {
        let screen = open(Self.items(1))
        #expect(!screen.editor.debugSheetIsPinned, "guard: it starts dismissible")

        choose(Mode.crop, on: screen)
        let whileCropping = screen.editor.debugSheetIsPinned

        choose(Mode.filters, on: screen)

        #expect(whileCropping)
        #expect(!screen.editor.debugSheetIsPinned, "and dismissible again after")
    }

    @Test func theBackSwipeIsSuspendedWhileTheSurfaceIsUp() {
        let screen = open(Self.items(1))
        #expect(screen.editor.debugSuspendedPans == 0, "guard: nothing suspended to begin with")

        choose(Mode.crop, on: screen)
        let whileCropping = screen.editor.debugSuspendedPans

        choose(Mode.filters, on: screen)

        #expect(whileCropping > 0,
                "a rightward drag on the picture must move the picture, not leave the screen")
        #expect(screen.editor.debugSuspendedPans == 0, "and every one of them is given back")
    }

    /// ⚠️ **THE DEFECT THIS TEST EXISTS FOR.** The screen keeps ONE list of
    /// suspended recognisers and refuses to suspend twice; the category strip's
    /// touch probe used to restore them on every lift, unconditionally. So
    /// entering crop mode and then brushing the strip handed the back-swipe back
    /// while the crop surface was still up — and a rightward drag on the picture
    /// would have taken the screen away. Two owners, one slot, and the suspension
    /// belonged to whichever spoke last.
    @Test func brushingTheCategoryStripDoesNotHandTheBackSwipeBackMidCrop() {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        #expect(screen.editor.debugSuspendedPans > 0, "guard: the crop must really have taken them")

        screen.editor.debugSetTouchingStrip(true)
        screen.editor.debugSetTouchingStrip(false)

        #expect(screen.editor.debugSuspendedPans > 0,
                "the strip's lift must not speak for the crop surface")
        #expect(screen.editor.debugIsCropping, "guard: and the surface is still up")
    }

    /// ⚠️ **TWO OWNERS, ONE CANVAS — THE SAME DEFECT, ONE LEVEL UP.** The
    /// overlays hold the canvas the way the crop surface does. Whichever lets go
    /// first must not unlock it under the other, and the last to let go gives
    /// back what the FIRST one borrowed.
    @Test func theCanvasStaysLockedUntilItsLastOwnerLetsGo() {
        let screen = open(Self.items(2))
        choose(Mode.crop, on: screen)
        screen.editor.lockCanvas(by: .overlays)
        #expect(!screen.editor.debugCanvasScrolls, "guard: locked")

        choose(Mode.filters, on: screen)

        #expect(!screen.editor.debugIsCropping, "guard: the crop surface went")
        #expect(!screen.editor.debugCanvasScrolls, "leaving crop unlocked a canvas the overlays still hold")
        #expect(screen.editor.debugSheetIsPinned)
        #expect(screen.editor.debugSuspendedPans > 0)

        screen.editor.unlockCanvas(by: .overlays)

        #expect(screen.editor.debugCanvasScrolls, "and paging comes back with the last owner")
        #expect(!screen.editor.debugSheetIsPinned)
        #expect(screen.editor.debugSuspendedPans == 0)
    }

    @Test func leavingTheScreenUnwindsCropModeWithIt() {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        #expect(screen.editor.debugIsCropping, "guard")

        screen.editor.viewWillDisappear(false)

        #expect(!screen.editor.debugIsCropping,
                "'Next' pushes from the middle of a crop, and nothing else would put this back")
        #expect(screen.editor.debugCanvasScrolls)
        #expect(!screen.editor.debugSheetIsPinned)
        #expect(screen.editor.debugSuspendedPans == 0)
    }

    /// ⚠️ **`[‹][Save draft][undo] ⋯ [Next]`.** Undo acts on the whole screen, so
    /// it stands with the other things that do, after the draft. The trailing side
    /// keeps the one action that moves the flow forward.
    @Test func undoStandsAfterSaveDraftWhileCropping() async throws {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)

        let leading = screen.editor.debugLeadingBarItems
        #expect(leading.count == 2, "got \(leading.count) leading items")
        #expect(leading.last === screen.editor.debugCropResetItem,
                "undo comes after the draft, not before it")
        #expect(screen.editor.navigationItem.leftItemsSupplementBackButton,
                "and the chevron still leads them — a custom leading item replaces it silently")
    }

    /// ⚠️ **THE TRAILING SIDE IS "Next" ALONE WHILE CROPPING, AND FILL/FIT COMES
    /// BACK AFTER.** Laying a picture into a frame is a decision about a picture
    /// the author is still choosing; leaving the glyph there offers an act with
    /// nothing to act on. Losing it permanently would be the real defect.
    ///
    /// ⚠️ **THE UNDO ARROW NO LONGER GOES WITH THE MODE, AND THAT IS A CHANGE
    /// RATHER THAN A REGRESSION.** It used to belong to crop alone; it is now one
    /// arrow whose MEANING is whichever mode is open — the rectangle and the
    /// angle in crop, the cut in the timeline. Two arrows a few points apart,
    /// each undoing a different thing, with nothing on screen to say which, is
    /// the alternative. So what this asserts is that fill/fit steps aside and
    /// comes back, and that the leading side keeps its two items throughout.
    @Test func fillAndFitStepAsideForTheModeAndReturnWithIt() async throws {
        let screen = open(Self.items(1))
        #expect(screen.editor.debugFitActionName != nil, "guard: the glyph is there to begin with")

        choose(Mode.crop, on: screen)
        let whileCropping = screen.editor.debugFitActionName

        choose(Mode.filters, on: screen)

        #expect(whileCropping == nil, "fill/fit stayed: \(String(describing: whileCropping))")
        #expect(screen.editor.debugFitActionName != nil,
                "and fill/fit is back: \(String(describing: screen.editor.debugFitActionName))")
        #expect(screen.editor.debugLeadingBarItems.count == 2,
                "the leading side is the draft and the undo arrow")
    }

    /// ⚠️ **THE ARROW STANDS IN THE BAR PERMANENTLY NOW, SO IT HAS TO SAY WHEN IT
    /// CANNOT ACT.** `resetCrop` begins `guard let id = croppingID`, and that is
    /// set only between `enterCrop` and `exitCrop` — so outside the surface the
    /// arrow drew ENABLED over a photograph carrying a crop and did nothing when
    /// tapped. It used to be hidden by living only in the crop bar.
    @Test func theUndoArrowIsDeadOnceTheCropSurfaceIsGone() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })
        screen.editor.debugCropSurface.setAngle(8)
        #expect(screen.editor.debugCanResetCrop, "guard: there is something to undo while cropping")

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugCanResetCrop == false,
                "the arrow offers to undo a crop it can no longer reach")
    }

    @Test func undoIsOfferedOnlyWhenThereIsSomethingToUndo() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })
        #expect(!screen.editor.debugCanResetCrop, "guard: nothing has been done yet")

        screen.editor.debugCropSurface.setAngle(8)

        #expect(screen.editor.debugCanResetCrop)
    }

    @Test func theFlipButtonMirrorsThePicture() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        screen.editor.debugCropTools.debugTapFlip()

        #expect(screen.editor.debugCropSurface.debugIsMirrored)
        #expect(screen.editor.debugCrop(for: "item-0").isMirrored,
                "and it is stored: \(screen.editor.debugCrop(for: "item-0"))")
    }

    /// ⚠️ **A SYMBOL NAME THAT DOES NOT EXIST IS AN EMPTY BUTTON, NOT A CRASH AND
    /// NOT A WARNING.** `UIImage(systemName:)` answers nil, the control lays out at
    /// its stated size, and it still takes taps — so the defect is a blank capsule
    /// on a device and nothing at all anywhere else. This screen shipped one for
    /// exactly one build: `arrow.trianglehead.counterclockwise.rotate`, which reads
    /// like a real name and is not in the catalogue.
    @Test func everyGlyphInTheCropToolsExists() {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)

        #expect(screen.editor.debugBarOffersCropReset, "guard: undo is in the bar to be checked")
        #expect(screen.editor.debugCropResetItem.image != nil,
                "undo has no glyph — the name is not in this SDK")
        for glyph in screen.editor.debugCropTools.debugGlyphs {
            #expect(glyph != nil, "a button in the band has no glyph")
        }
    }

    /// ⚠️ **THE DELAY WAS A LIBRARY ROUND TRIP, AND THAT IS WHAT THIS MEASURES.**
    /// Leaving crop used to ask `PHImageManager` for the picture all over again
    /// before it could paint the result, so the canvas showed the OLD framing until
    /// it answered — a beat on a local asset and a long wait on an iCloud one. The
    /// picture the surface has been showing is kept instead.
    ///
    /// ⚠️ **AND THE RENDER ITSELF IS DELIBERATELY NOT SYNCHRONOUS — AN EARLIER
    /// VERSION OF THIS TEST DEMANDED THAT IT WAS.** Cutting a canvas-sized picture
    /// in the same turn as the tap made the selector's pill stutter as it
    /// travelled, which is a worse defect than the one it fixed. So what is pinned
    /// is that no NEW picture is fetched, not that no runloop passes.
    @Test func leavingCropNeverGoesBackToTheLibrary() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })
        let before = screen.editor.debugPageImageSize(for: "item-0")
        let fetches = screen.library.canvasFetches

        screen.editor.debugCropSurface.choose(.square)
        choose(Mode.filters, on: screen)
        try await settle(until: {
            let now = screen.editor.debugPageImageSize(for: "item-0")
            return abs(now.width - now.height) < 2
        })

        let after = screen.editor.debugPageImageSize(for: "item-0")
        #expect(abs(before.width - before.height) > 2,
                "guard: the stub's picture is not square to begin with — \(before)")
        #expect(abs(after.width - after.height) < 2, "the square crop is drawn: \(after)")
        #expect(screen.library.canvasFetches == fetches,
                "and nothing was fetched to draw it: \(fetches) -> \(screen.library.canvasFetches)")
    }

    /// ⚠️ **THE CANVAS HAS TO BE UNDER THE FADE, OR THE FADE IS FROM BLACK.** The
    /// surface comes up from alpha zero over a quarter second; whatever is beneath
    /// it for that quarter second is what the author watches the picture emerge
    /// from. Measured on a recording before this assertion existed: one frame in
    /// 677 showed the whole screen dark, because the canvas was already gone when
    /// the fade began.
    @Test func theCanvasIsStillThereWhileTheSurfaceFadesIn() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)

        #expect(screen.editor.debugCanvasIsShowing,
                "hidden before the fade even starts — the picture would rise out of black")
        #expect(screen.editor.debugCanvasAlpha == 1,
                "and at full strength: \(screen.editor.debugCanvasAlpha)")
    }

    // MARK: - Where the picture sits

    /// ⚠️ **A WHOLE PICTURE CENTRED IN THE WHOLE WINDOW HANGS BEHIND THE CHROME.**
    /// Filling is full-bleed on purpose — the frame crops it either way. Fitting
    /// means showing the picture ENTIRE, and an entire picture centred on the
    /// window puts its middle under the toolbar: it reads as sitting low. The
    /// window it is centred in runs from the foot of the top bar to the head of
    /// the page indicator.
    @Test func aFittedPictureIsCentredBetweenTheBarAndTheDots() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { screen.editor.debugPictureFrame(for: "item-0") != .zero })

        screen.editor.debugTapFit()
        screen.window.layoutIfNeeded()

        let picture = screen.editor.debugPictureFrame(for: "item-0")
        #expect(abs(picture.minY - screen.editor.view.safeAreaInsets.top) < 1,
                "its head is the foot of the bar: \(picture) vs \(screen.editor.view.safeAreaInsets)")
        #expect(abs(picture.maxY - screen.editor.debugPageDotsTop) < 1,
                "and its foot is the head of the dots: \(picture.maxY) vs \(screen.editor.debugPageDotsTop)")
    }

    /// The witness: filling keeps every point of the window, bars included.
    @Test func aFilledPictureKeepsTheWholeWindow() async throws {
        let screen = open(Self.items(2))
        try await settle(until: { screen.editor.debugPictureFrame(for: "item-0") != .zero })

        let picture = screen.editor.debugPictureFrame(for: "item-0")
        #expect(screen.editor.debugFit(for: "item-0") == .fill, "guard: it starts filled")
        #expect(abs(picture.minY) < 1 && abs(picture.maxY - screen.editor.view.bounds.height) < 1,
                "full bleed, top to bottom: \(picture) in \(screen.editor.view.bounds)")
    }

    /// ⚠️ **THE BAND IS CHROME WHILE A CROP IS BEING MADE.** Everywhere else the
    /// canvas runs beneath the controls by design; here it showed the UNCUT
    /// photograph under a ruler measuring the cut one.
    @Test func theCropToolsStandOnTheScreensOwnGround() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)
        screen.window.layoutIfNeeded()

        let chrome = try? #require(screen.editor.debugCropChrome)
        #expect(chrome?.backgroundColor == .systemBackground,
                "got \(String(describing: chrome?.backgroundColor))")
        #expect((chrome?.frame.minY ?? 0) <= screen.editor.debugBand.frame.minY + 0.5,
                "it starts where the band does: \(String(describing: chrome?.frame))")
        #expect(abs((chrome?.frame.maxY ?? 0) - screen.editor.view.bounds.height) < 1,
                "and runs to the foot of the screen")
    }

    /// The witness: it is not there when no crop is being made.
    @Test func andTheFilterRowKeepsThePictureBehindIt() {
        let screen = open(Self.items(1))

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugCropChrome == nil,
                "the band's own rule — the media is the subject — still holds everywhere else")
    }

    // MARK: - The device's appearance

    private func brightness(_ colour: UIColor, _ style: UIUserInterfaceStyle) -> CGFloat {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getWhite(&white, alpha: &alpha)
        return white
    }

    /// ⚠️ **THE RULE, STATED AS A MEASUREMENT.** White in light, black in dark —
    /// asked for in exactly those words. `systemBackground` says it, but a test
    /// that reads the SCREEN'S colour is what catches somebody restoring a literal
    /// black here for the reason the old comment gave.
    @Test func theGroundIsWhiteInLightAndBlackInDark() throws {
        let screen = open(Self.items(1))

        let ground = try #require(screen.editor.view.backgroundColor)

        #expect(brightness(ground, .light) > 0.9, "light: \(brightness(ground, .light))")
        #expect(brightness(ground, .dark) < 0.1, "dark: \(brightness(ground, .dark))")
    }

    /// ⚠️ **AND EVERY INK HAS TO TURN WITH IT — THIS IS THE HALF THAT BITES.**
    /// The dial, the shapes and the notice were all written in literal white
    /// BECAUSE the ground was literally black, and that was measured from a
    /// screenshot at the time. A ground that follows the device turns each of those
    /// into white on white for half the world, with nothing to say so. This holds
    /// each ink against the ground in BOTH appearances and asks only that you could
    /// still read it.
    @Test func everyInkInTheBandStaysLegibleInBothAppearances() {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        let inks = screen.editor.debugCropTools.debugInks

        // ⚠️ THE FRAME COUNTS TOO, AND ITS NEIGHBOUR IS THE SCRIM — which is the
        // ground at 55%, so the ground is what it must contrast with. It was white
        // while the editor was black and vanished into the margin the day it was
        // not.
        let all = inks + [("the crop frame", screen.editor.debugCropSurface.debugFrameInk, UIColor.systemBackground)]

        #expect(all.count >= 5, "guard: there are inks to check — \(all.map(\.0))")
        for (name, ink, ground) in all {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let apart = abs(brightness(ink, style) - brightness(ground, style))
                #expect(apart > 0.3,
                        "\(name) in \(style == .light ? "light" : "dark"): only \(apart) apart from what it sits on")
            }
        }
    }

    // MARK: - A video

    /// ⚠️ **A VIDEO IS CROPPED NOW — IT WAS TOLD IT COULD NOT BE.** The crop
    /// travels in the clip's plan, the compositor draws it, and the export
    /// publishes it; the refusal would be the lie.
    @Test func aVideoCanBeCropped() {
        let screen = open(Self.items(1, videoAt: 0))

        choose(Mode.crop, on: screen)

        #expect(screen.editor.debugIsCropping, "the video was refused")
        #expect(screen.editor.debugBand.content is MediaCropToolsView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    @Test func aVideosCropIsStoredAgainstTheClip() {
        let screen = open(Self.items(1, videoAt: 0))
        choose(Mode.crop, on: screen)
        let cut = MediaCrop(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))

        screen.editor.debugCropSurface.onChange?(cut)

        #expect(screen.editor.debugCrop(for: "item-0") == cut, "got \(screen.editor.debugCrop(for: "item-0"))")
    }

    /// ⚠️ **A VIDEO IS OFFERED THE LOOKS NOW — IT WAS TOLD IT COULD NOT BE
    /// FILTERED.** That notice existed because `post()`'s video branch never
    /// read `edits`: an author could choose a look, watch the canvas apply it,
    /// and publish the untouched clip. The look now travels in the clip's plan
    /// and plays live in the preview, so the refusal would be the lie.
    @Test func aVideoIsOfferedTheLooks() {
        let screen = open(Self.items(1, videoAt: 0))

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugBand.content is MediaFilterRowView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    /// The same row on a photograph.
    @Test func aPhotographInTheSamePlaceGetsTheLooks() {
        let screen = open(Self.items(1))

        choose(Mode.filters, on: screen)

        #expect(screen.editor.debugBand.content is MediaFilterRowView,
                "got \(String(describing: screen.editor.debugBand.content))")
    }

    /// The witness: a photograph in the same position gets the tools.
    @Test func aPhotographInTheSamePlaceGetsTheTools() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)

        #expect(screen.editor.debugBand.content is MediaCropToolsView)
    }

    // MARK: - What the author keeps

    @Test func aCropChosenHereTravelsToTheNextScreen() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        let surface = screen.editor.debugCropSurface
        surface.choose(.square)
        screen.editor.debugTapNext()

        let carried = try #require(screen.handedOn.edits?["item-0"])
        #expect(!carried.crop.isUntouched, "got \(carried.crop)")
        #expect(abs(carried.crop.rect.width * 40 - carried.crop.rect.height * 30) < 1.5,
                "a square of a 40x30 picture keeps equal sides: \(carried.crop.rect)")
    }

    // MARK: - The band's controls actually reach the picture

    /// ⚠️ **FOUR CLOSURES TIE THE BAND TO THE SURFACE, AND A CLOSURE THAT WAS
    /// NEVER ASSIGNED LOOKS EXACTLY LIKE ONE THAT WAS.** These drive the tools,
    /// not the surface, so each one crosses the wire it is testing.
    @Test func turningTheDialInTheBandTurnsThePictureOnTheSurface() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        screen.editor.debugCropTools.debugDial.debugDrag(by: -StraightenDial.pointsPerDegree * 9)

        #expect(screen.editor.debugCropSurface.debugTurn.fine == 9,
                "got \(screen.editor.debugCropSurface.debugTurn)")
        #expect(screen.editor.debugCrop(for: "item-0").angle == 9,
                "and it is stored: \(screen.editor.debugCrop(for: "item-0").angle)")
    }

    @Test func choosingAShapeInTheBandShapesTheBox() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })
        let before = screen.editor.debugCropSurface.debugBox

        screen.editor.debugCropTools.debugPick(.square)

        let box = screen.editor.debugCropSurface.debugBox
        #expect(abs(before.width / before.height - 1) > 0.1, "guard: it did not start square")
        #expect(abs(box.width / box.height - 1) < 0.02, "got \(box)")
    }

    @Test func theQuarterTurnButtonTurnsThePicture() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        screen.editor.debugCropTools.debugTapQuarterTurn()

        #expect(screen.editor.debugCropSurface.debugTurn.quarters == 1)
        #expect(screen.editor.debugCrop(for: "item-0").angle == 90,
                "got \(screen.editor.debugCrop(for: "item-0").angle)")
    }

    /// ⚠️ **NOTHING MAY BE TOUCHED BEFORE THE PICTURE LANDS.** The library answers
    /// on its own turn, and until it does the surface holds a one-point
    /// placeholder — a drag or a turn in that window would compute a crop against
    /// nothing and store it.
    @Test func theToolsAreDeadUntilThereIsSomethingToCut() {
        let screen = open(Self.items(1))

        choose(Mode.crop, on: screen)

        #expect(!screen.editor.debugCropSurface.debugHasPicture, "guard: it has not landed yet")
        #expect(!screen.editor.debugCropSurface.isUserInteractionEnabled)
        #expect(!screen.editor.debugCropTools.isUserInteractionEnabled)
    }

    @Test func andTheyComeAliveWhenItDoes() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)

        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        #expect(screen.editor.debugCropSurface.isUserInteractionEnabled)
        #expect(screen.editor.debugCropTools.isUserInteractionEnabled)
    }

    /// ⚠️ **THE MODE OUTLIVES A PUSH, SO IT HAS TO COME BACK.** Leaving the screen
    /// unwinds crop mode — it must — and returning used to land on an editor whose
    /// pill said Crop over an empty band, with no way to reopen it: selecting the
    /// index the strip already rests on announces nothing.
    @Test func comingBackToTheScreenReopensTheModeThatIsStillChosen() {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        screen.editor.viewWillDisappear(false)
        #expect(!screen.editor.debugIsCropping, "guard: leaving really did unwind it")
        #expect(screen.editor.debugBand.content == nil, "and took the tools with it")

        screen.editor.viewDidAppear(false)

        #expect(screen.editor.debugIsCropping)
        #expect(screen.editor.debugBand.content is MediaCropToolsView)
    }

    /// The witness: a screen nobody edited carries nothing at all — not an entry
    /// saying "unchanged".
    @Test func aPictureNobodyTouchedIsNotCarried() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        screen.editor.debugTapNext()

        #expect(screen.handedOn.edits?.isEmpty == true,
                "got \(String(describing: screen.handedOn.edits))")
        #expect(!screen.editor.debugHasEdits(for: "item-0"))
    }

    @Test func straighteningIsCarriedTooAndUndoingItIsNotAnEntry() async throws {
        let screen = open(Self.items(1))
        choose(Mode.crop, on: screen)
        try await settle(until: { screen.editor.debugCropSurface.debugHasPicture })

        screen.editor.debugCropSurface.setAngle(12)
        #expect(screen.editor.debugCrop(for: "item-0").angle == 12,
                "guard: got \(screen.editor.debugCrop(for: "item-0").angle)")

        screen.editor.debugTapResetCrop()

        #expect(!screen.editor.debugHasEdits(for: "item-0"),
                "undoing everything removes the entry rather than storing a neutral one")
    }
}
