import DesignSystem
import Testing
import UIKit
@testable import Upload

/// The strip reserved between the toolbar and the page indicator.
///
/// ⚠️ **EVERY TEST HERE FORCES `additionalSafeAreaInsets`, AND WITHOUT THAT THEY
/// WOULD ALL PASS VACUOUSLY.** A programmatic `UIWindow` has no safe area, so a
/// band anchored to `safeAreaLayoutGuide.bottomAnchor` lands in the same place as
/// one anchored to the view's bottom, and an assertion about the difference
/// cannot fail. `MediaEditorTests` records the same trap costing a wrong
/// conclusion once already on this screen.
@MainActor
struct MediaEditorBandTests {
    private struct Screen {
        let editor: MediaEditorViewController
        let window: UIWindow
    }

    private static let bottomInset: CGFloat = 40

    private func open(_ count: Int) -> Screen {
        let items = (0..<count).map {
            MediaLibraryItem(id: "item-\($0)", kind: .photo)
        }
        let editor = MediaEditorViewController(items: items, library: StubLibrary()) { _, _, _ in
            UIViewController()
        }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        // The trap, answered: give the screen a foot to clear.
        editor.additionalSafeAreaInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: Self.bottomInset, right: 0
        )
        window.layoutIfNeeded()
        return Screen(editor: editor, window: window)
    }

    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: String) async -> [MediaLibraryItem] { [] }
        func thumbnail(for item: String, size: CGSize) async -> UIImage? { nil }
        func presentLimitedPicker(from host: UIViewController) {}
    }

    // MARK: - Empty

    @Test func anEmptyBandIsInvisibleAndTakesNoRoom() {
        let screen = open(3)
        let band = screen.editor.debugBand

        #expect(band.isHidden)
        #expect(band.debugIsShowing == false)
        #expect(band.frame.height == 0, "an empty band claims no height: \(band.frame)")
        #expect(band.backgroundColor == nil || band.backgroundColor == .clear,
                "the media runs underneath; a plate here would cut the picture in two")
    }

    /// ⚠️ **THE REGRESSION THIS WHOLE DESIGN EXISTS TO PREVENT.** The gap lives
    /// inside the band so that an empty one reproduces the previous geometry
    /// exactly. Had the indicator stated the gap itself, an empty zero-height
    /// band would have pushed it 8pt down — invisible on a single medium, which
    /// has no indicator at all.
    @Test func anEmptyBandLeavesTheIndicatorExactlyWhereItWas() {
        let screen = open(3)
        let dots = screen.editor.debugPageDots
        let root = screen.editor.view!

        let safeBottom = root.bounds.height - root.safeAreaInsets.bottom
        #expect(root.safeAreaInsets.bottom >= Self.bottomInset,
                "guard: without a real safe area this assertion cannot fail")
        // ⚠️ ONE INTERPOLATED LITERAL, NEVER A CONCATENATION. `#expect`'s second
        // argument is a `Comment`, which a string LITERAL becomes on its own;
        // joining two with `+` yields a plain `String` and fails to convert. It
        // cost a build here.
        #expect(
            abs(dots.frame.maxY - (safeBottom - Spacing.sm)) < 0.5,
            "must sit where it did before the band: \(dots.frame.maxY) vs \(safeBottom - Spacing.sm)"
        )
    }

    // MARK: - Filled

    @Test func aBandRunsTheFullWidthOfTheSheetRatherThanItsMargins() {
        let screen = open(3)
        let root = screen.editor.view!
        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true

        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()

        let band = screen.editor.debugBand
        #expect(band.frame.width == root.bounds.width,
                "full width of the sheet: \(band.frame.width) vs \(root.bounds.width)")
        #expect(root.layoutMargins.left > 0, "guard: margins exist, so this is a real distinction")
    }

    @Test func showingAControlLiftsTheIndicatorByThatControlPlusOneGap() {
        let screen = open(3)
        let before = screen.editor.debugPageDots.frame.maxY
        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true

        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()

        let after = screen.editor.debugPageDots.frame.maxY
        #expect(
            abs((before - after) - (64 + Spacing.sm)) < 0.5,
            "lifted by the content plus one gap: moved \(before - after), expected \(64 + Spacing.sm)"
        )
        #expect(screen.editor.debugBand.debugIsShowing)
    }

    @Test func takingTheControlAwayGivesTheRoomBack() {
        let screen = open(3)
        let resting = screen.editor.debugPageDots.frame.maxY
        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true

        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()
        screen.editor.setEditingAccessory(nil)
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugBand.frame.height == 0)
        #expect(screen.editor.debugBand.debugIsShowing == false)
        #expect(abs(screen.editor.debugPageDots.frame.maxY - resting) < 0.5,
                "and the indicator returns to where it rested")
    }

    /// A second tenant replaces the first rather than stacking on it.
    @Test func aSecondControlReplacesTheFirst() {
        let screen = open(3)
        let first = UIView()
        first.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let second = UIView()
        second.heightAnchor.constraint(equalToConstant: 90).isActive = true

        screen.editor.setEditingAccessory(first)
        screen.window.layoutIfNeeded()
        screen.editor.setEditingAccessory(second)
        screen.window.layoutIfNeeded()

        #expect(first.superview == nil, "the first is gone, not merely covered")
        #expect(screen.editor.debugBand.content === second)
        #expect(abs(screen.editor.debugBand.frame.height - (90 + Spacing.sm)) < 0.5)
    }

    // MARK: - The band claims its own drags

    /// ⚠️ **THE EDGE BAND AND THE FIRST CHIP OVERLAP.** The stack's back-swipe
    /// accepts anything within 20pt of the leading edge, and the row's first chip
    /// starts at x=16 — so a drag begun on it was claimed as a back-swipe and the
    /// row would not scroll. Reported from a device.
    @Test func aTouchInsideTheBandBelongsToTheBand() {
        let screen = open(3)
        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true
        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()

        let root = screen.editor.view!
        let inside = strip.convert(CGPoint(x: 8, y: strip.bounds.midY), to: root)

        #expect(
            UploadNavigationController.beginsInsideTheEditingBand(inside, in: root),
            "a drag on the band's tenant is the tenant's, not the stack's: \(inside)"
        )
    }

    /// ⚠️ **THE HALF THAT KEEPS THE BACK-SWIPE ALIVE.** A rule that answered true
    /// everywhere would silence the gesture entirely, and the test above would
    /// not notice.
    @Test func aTouchOnTheCanvasIsNotTheBands() {
        let screen = open(3)
        let root = screen.editor.view!

        #expect(
            UploadNavigationController.beginsInsideTheEditingBand(
                CGPoint(x: 8, y: root.bounds.midY), in: root
            ) == false,
            "mid-canvas is nobody's accessory — the stack may still have it"
        )
    }

    // MARK: - The single-medium case

    /// ⚠️ NO CONDITIONAL LAYOUT, AND THIS PROVES IT. `MediaPageDotsView` hides
    /// itself under two items, so the band's placement never has to ask whether
    /// there is a carousel — it anchors to the safe area either way.
    @Test func aSingleMediumHasNoIndicatorAndTheBandStillSitsAtTheFoot() {
        let screen = open(1)
        let root = screen.editor.view!

        #expect(screen.editor.debugPageDots.isHidden, "one medium, no indicator")
        let safeBottom = root.bounds.height - root.safeAreaInsets.bottom
        #expect(
            abs(screen.editor.debugBand.frame.maxY - (safeBottom - Spacing.sm)) < 0.5,
            "the band still rests on the safe area: \(screen.editor.debugBand.frame)"
        )
    }

    // MARK: - The dissolve behind the chrome

    /// ⚠️ **THE DENOMINATOR FOR THE TWO TESTS AFTER IT.** The dissolve hangs from
    /// the band's top when the band holds something and from the toolbar's top
    /// when it does not — but an EMPTY band collapses to `safeArea.bottom -
    /// Spacing.sm`, only 8pt from the toolbar. Without a real safe area the two
    /// anchors land close enough that both of the next tests would pass whichever
    /// constraint were active, which is the same trap this file already records
    /// for the band itself. This asserts the cases are actually distinguishable.
    @Test func theTwoAnchorsLandInClearlyDifferentPlaces() {
        let screen = open(3)
        let root = screen.editor.view!
        let empty = screen.editor.debugBackdrop.frame.minY

        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true
        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()
        let filled = screen.editor.debugBackdrop.frame.minY

        #expect(root.safeAreaInsets.bottom >= Self.bottomInset,
                "guard: with no safe area the anchors coincide and nothing below can fail")
        #expect(empty - filled > 60,
                "a filled band must start the ramp clearly higher: empty=\(empty) filled=\(filled)")
    }

    @Test func anEmptyBandHangsTheDissolveFromTheToolbar() {
        let screen = open(3)
        let root = screen.editor.view!
        let safeBottom = root.bounds.height - root.safeAreaInsets.bottom
        let begins = screen.editor.debugBackdrop.frame.minY

        #expect(abs(begins - safeBottom) < 0.5,
                "begins at the toolbar's top edge: \(begins) vs \(safeBottom)")
    }

    @Test func aFilledBandHangsTheDissolveFromTheBand() {
        let screen = open(3)
        let strip = UIView()
        strip.heightAnchor.constraint(equalToConstant: 64).isActive = true

        screen.editor.setEditingAccessory(strip)
        screen.window.layoutIfNeeded()

        let band = screen.editor.debugBand.frame.minY
        let begins = screen.editor.debugBackdrop.frame.minY
        #expect(abs(begins - band) < 0.5,
                "begins where the controls do: \(begins) vs \(band)")
    }

    /// ⚠️ **THE FOOT OF THE SCREEN, NOT THE SAFE AREA** — and never hidden. The
    /// picker's copy of this blur lost its whole band to an `isHidden` once; the
    /// top anchor is the dial here, visibility is not.
    @Test func theDissolveReachesTheFootOfTheScreenAndIsNeverHidden() {
        let screen = open(3)
        let root = screen.editor.view!
        let backdrop = screen.editor.debugBackdrop

        #expect(backdrop.isHidden == false)
        #expect(root.safeAreaInsets.bottom >= Self.bottomInset,
                "guard: this only differs from the safe area when there IS one")
        #expect(abs(backdrop.frame.maxY - root.bounds.maxY) < 0.5,
                "runs past the safe area to the screen's foot: \(backdrop.frame) in \(root.bounds)")
    }

    /// ⚠️ **ABOVE THE PICTURE, BENEATH THE CHROME.** `pin(to:)` and
    /// `constrain(in:)` both call `addSubview` first, which would have moved the
    /// dissolve to the top of the stack and veiled the very controls it exists to
    /// lift off the picture.
    @Test func theDissolveSitsAboveThePictureButBeneathTheChrome() throws {
        let screen = open(3)
        let subviews = screen.editor.view!.subviews
        let backdrop = try #require(subviews.firstIndex(of: screen.editor.debugBackdrop))
        let band = try #require(subviews.firstIndex(of: screen.editor.debugBand))
        let dots = try #require(subviews.firstIndex(of: screen.editor.debugPageDots))

        #expect(backdrop < band, "the band draws on top of the dissolve")
        #expect(backdrop < dots, "and so does the indicator")
    }
}
