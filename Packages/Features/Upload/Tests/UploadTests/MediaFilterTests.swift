import Testing
import UIKit
@testable import Upload

/// The looks, the renderer behind them, and the row that offers them.
///
/// ⚠️ **THE COLOUR ASSERTIONS READ PIXELS, DELIBERATELY.** "A filter returned an
/// image" is satisfied by a filter that did nothing at all, which is exactly the
/// failure worth catching: a mis-wired `kCIInputImageKey` returns the source
/// untouched and every shallow test still passes. Sampling the result is what
/// tells a look apart from a no-op.
@MainActor
struct MediaFilterTests {
    /// A flat red square, big enough to sample without landing on an edge.
    private func redSquare(scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// The centre pixel, as three 0–255 components.
    private func centrePixel(of image: UIImage) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Draw the middle of the image into a one-pixel canvas.
        context.draw(cgImage, in: CGRect(x: -0.5, y: -0.5, width: 2, height: 2))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    // MARK: - The catalogue

    @Test func everyLookIsOfferedAndOriginalLeads() {
        let all = MediaFilter.allCases
        #expect(all.count == 9, "eight photo effects and the untouched original")
        #expect(all.first == .original, "the untouched picture is the first thing offered")
        #expect(all.allSatisfy { !$0.name.isEmpty })
        #expect(Set(all.map(\.name)).count == all.count, "no two looks share a caption")
    }

    // MARK: - The renderer

    /// ⚠️ `.original` IS THE ABSENCE OF A FILTER, not a filter that does nothing:
    /// it returns the source and pays no GPU cost.
    @Test func theOriginalHandsBackTheVerySameImage() {
        let source = redSquare()
        let out = MediaFilterRenderer.apply(.original, to: source)

        #expect(out === source, "the original must not be re-rendered at all")
    }

    @Test func monoDrainsTheColourOutOfAPicture() throws {
        let source = redSquare()
        let filtered = try #require(MediaFilterRenderer.apply(.mono, to: source))
        let before = try #require(centrePixel(of: source))
        let after = try #require(centrePixel(of: filtered))

        #expect(before.r > before.g + 60, "guard: the source really is red, not already grey")
        #expect(abs(after.r - after.g) < 12, "mono leaves red and green level: \(after)")
        #expect(abs(after.g - after.b) < 12, "and green and blue too: \(after)")
    }

    @Test func aLookActuallyChangesThePixels() throws {
        let source = redSquare()
        let filtered = try #require(MediaFilterRenderer.apply(.noir, to: source))
        let before = try #require(centrePixel(of: source))
        let after = try #require(centrePixel(of: filtered))

        #expect(before != after, "a look that returns the source unchanged is a mis-wired filter")
    }

    /// ⚠️ THE TRAP THIS GUARDS: `UIImage(cgImage:)` alone lands at scale 1 and
    /// `.up`, which doubles a Retina thumbnail's apparent size and rotates
    /// anything the camera recorded sideways.
    @Test func aFilteredImageKeepsTheSourcesScale() throws {
        let source = redSquare(scale: 3)
        let filtered = try #require(MediaFilterRenderer.apply(.chrome, to: source))

        #expect(filtered.scale == source.scale, "scale \(filtered.scale) vs \(source.scale)")
        #expect(filtered.imageOrientation == source.imageOrientation)
    }

    // MARK: - The row

    @Test func theRowOffersEveryLookAndStartsOnTheOriginal() {
        let row = MediaFilterRowView()

        #expect(row.debugFilters == MediaFilter.allCases)
        #expect(row.debugSelected == .original)
    }

    @Test func pickingALookAnnouncesItAndRingsIt() {
        let row = MediaFilterRowView()
        var picked: [MediaFilter] = []
        row.onPick = { picked.append($0) }

        row.debugTap(.noir)

        #expect(picked == [.noir])
        #expect(row.debugSelected == .noir)
    }

    /// ⚠️ **THE RING IS WHITE, AND EVERY OTHER ROW IN THE BAND AGREES.** It was
    /// `.tintColor` — blue — while the transitions and the per-piece looks
    /// beside it ringed their choice in white, so one band showed two kinds of
    /// chosen. Asked for in those words: *"l'élément sélectionné a un contour
    /// bleu alors que je souhaite un contour blanc"*.
    @Test func theChosenLookIsRingedInWhite() throws {
        let row = MediaFilterRowView()

        row.debugTap(.noir)

        let chosen = try #require(row.debugRing(for: .noir))
        let other = try #require(row.debugRing(for: .chrome))
        #expect(chosen.width == 2, "the chosen chip wears no ring")
        #expect(other.width == 0, "an unchosen chip wears one")
        let ink = try #require(chosen.colour)
        var white: CGFloat = 0, alpha: CGFloat = 0
        #expect(ink.getWhite(&white, alpha: &alpha), "the ring is not a grey at all: \(ink)")
        #expect(white == 1 && alpha == 1, "the ring is \(ink), not white")
    }

    /// ⚠️ RESTORING A CHOICE MUST BE SILENT. `setSelected` is what a swipe to
    /// another picture calls; if it announced, arriving at an item would look
    /// like the viewer had just chosen its look and would re-render the canvas
    /// for nothing.
    @Test func restoringASelectionDoesNotAnnounceIt() {
        let row = MediaFilterRowView()
        var picked: [MediaFilter] = []
        row.onPick = { picked.append($0) }

        row.setSelected(.fade)

        #expect(row.debugSelected == .fade)
        #expect(picked.isEmpty, "restoring is not choosing")
    }

    /// ⚠️ **THE HOLE EVERY OTHER TEST HERE LEAVES OPEN.** `debugTap` calls
    /// `pick()` directly and never touches the button, so a chip whose hit area
    /// has collapsed to nothing still passes all of them — the pictures draw from
    /// their own constraints while no touch reaches anything. That is exactly
    /// what a device showed: the row rendered, and tapping it did nothing.
    ///
    /// This asks the view tree the question a finger asks.
    @Test func aFingerLandingOnAChipFindsSomethingToPress() throws {
        let row = MediaFilterRowView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        row.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])
        window.layoutIfNeeded()

        #expect(row.frame.height > 0, "guard: the row itself must have been laid out")

        // ⚠️ **THE CENTRE OF A CHIP, NOT THE CENTRE OF THE ROW — AND THE FIRST
        // version of this test got that wrong.** The row scrolls, so its content
        // is offset by `contentInset`: with nine chips overflowing 402pt the inset
        // is 16 and the chips land at 16, 80, 144, 208… `row.bounds.midX` is 201,
        // which falls in the 8pt gutter between the third and fourth and hits the
        // bare stack view. The test failed against working code — the same mistake
        // as aiming a device tap at a computed point and blaming the view.
        //
        // Found by walking rather than computed, so a change of metrics moves the
        // target with it instead of silently missing.
        func firstChip(in view: UIView) -> UIView? {
            for sub in view.subviews {
                if "\(type(of: sub))".contains("FilterChip") { return sub }
                if let found = firstChip(in: sub) { return found }
            }
            return nil
        }
        let chip = try #require(firstChip(in: row), "no chip in the row at all")

        // ⚠️ **THE ORIGINAL DEFECT WAS A CHIP SHORTER THAN ITS OWN PICTURE**, and
        // aiming at the chip's centre alone would no longer catch it: a 34pt chip
        // still has a button over its own middle. What broke was the picture
        // overflowing the chip by 22pt, so the bottom of a thumbnail answered
        // nothing. Assert the chip covers its picture, then aim at the picture's
        // lower half — the part that was dead.
        let picture = try #require(
            chip.subviews.first { $0 is UIImageView },
            "a chip with no picture in it"
        )
        #expect(
            chip.bounds.height >= picture.bounds.height,
            "the chip must cover its own picture: chip \(chip.bounds.height) vs picture \(picture.bounds.height)"
        )

        let lowerHalf = picture.convert(
            CGPoint(x: picture.bounds.midX, y: picture.bounds.maxY - 6), to: row
        )
        let hit = row.hitTest(lowerHalf, with: nil)
        let control = try #require(hit, "nothing under the foot of a thumbnail at \(lowerHalf)")

        // Walking up rather than demanding the hit view IS the button: a label or
        // an image may legitimately sit on top, so long as a control is beneath.
        var node: UIView? = control
        var foundControl = false
        while let current = node, current !== row {
            if current is UIControl { foundControl = true; break }
            node = current.superview
        }
        #expect(foundControl, "a finger in the middle of the row found \(type(of: control)), no control above it")
    }

    /// ⚠️ **A DRAG THAT BEGINS ON A CHIP MUST SCROLL THE ROW.** Every chip carries
    /// a full-surface `UIButton` — that is what makes it tappable — and
    /// `UIScrollView.touchesShouldCancel(in:)` returns **false** for a `UIControl`
    /// by default, so the button keeps the touch and the row will not move. The
    /// symptom on a device is a row that scrolls from some places and not others:
    /// the places that work are the 8pt gutters, where the finger misses a button.
    ///
    /// ⚠️ AND IT MUST BE ASKED OF A CONTROL. The default already answers true for
    /// an ordinary view, so a version of this test aimed at the chip's container
    /// would pass with the override removed and prove nothing.
    @Test func aDragStartingOnAChipIsHandedToTheScroll() throws {
        let row = MediaFilterRowView()
        let chip = try #require(row.debugChips().first, "no chips in the row")
        let control = try #require(
            chip.subviews.compactMap { $0 as? UIControl }.first,
            "a chip with no control in it — this test would be vacuous"
        )

        #expect(
            row.debugScrollWinsADragOver(control),
            "the scroll must take a drag away from \(type(of: control)), or the row only moves between chips"
        )
    }

    /// ⚠️ **THE ROW MUST OUTRANK PANS THAT LIVE ABOVE IT.** The sheet's dismissal
    /// pan and the stack's back-swipe both sit on ancestors, and losing that race
    /// is why the row sometimes would not move. Making them wait for the row's own
    /// pan is the priority it needs.
    /// ⚠️ **THE QUESTION THAT DECIDES WHETHER THE RULE IS EVEN REACHED.**
    /// `UIScrollView` adopts `UIGestureRecognizerDelegate` and is normally its own
    /// pan's delegate — but "normally" is an assumption, and a priority rule that
    /// UIKit never consults would be dead code wearing the shape of a fix. The
    /// two tests below assert the DECISION; this one asserts it is asked for.
    @Test func theRowIsItsOwnPansDelegateSoTheRuleIsConsulted() {
        let row = MediaFilterRowView()

        #expect(
            row.debugScroller.panGestureRecognizer.delegate === row.debugScroller,
            "if UIKit asks someone else, the priority rule below never runs"
        )
    }

    @Test func anOutsidePanIsMadeToWaitForTheRow() {
        let row = MediaFilterRowView()
        let elsewhere = UIView()
        let sheetLikePan = UIPanGestureRecognizer()
        elsewhere.addGestureRecognizer(sheetLikePan)

        #expect(row.debugRowIsAskedBefore(sheetLikePan))
    }

    /// ⚠️ **A RECOGNISER WITH NO VIEW STILL HAS TO BE ANSWERED.** `other.view` is
    /// optional and the rule takes an early exit on nil; nothing exercised that
    /// branch, so it could have been inverted without a single test noticing.
    @Test func aRecogniserWithNoViewIsTreatedAsAnOutsider() {
        let row = MediaFilterRowView()
        let homeless = UIPanGestureRecognizer()

        #expect(homeless.view == nil, "guard: the whole point of this case is the nil")
        #expect(row.debugRowIsAskedBefore(homeless))
    }

    // ⚠️ **THE RULE'S FIRST GUARD — "only answer for the row's own pan" — IS NOT
    // COVERED, AND DELIBERATELY SO.** A test for it has to call the method with a
    // DIFFERENT recogniser as the subject, and the method lives on the private
    // `ChipScrollView`; `debugScroller` is typed `UIScrollView`, which does not
    // declare it, so the call does not compile from here (it cost a build: "value
    // of type 'UIScrollView' has no member 'gestureRecognizer'"). The existing
    // `debugRowIsAskedBefore` always passes the row's own pan as the subject, so it
    // cannot reach that branch either. Widening production API purely to cover a
    // guard is the wrong trade; this note is the honest alternative to a test that
    // would have to be written around the obstacle rather than through it.

    /// ⚠️ **AND THE ROW'S OWN RECOGNISERS MUST NOT BE.** Returning true for
    /// everything would satisfy the test above while making a chip's button wait
    /// on a scroll that never begins — the taps would die to fix the scrolling.
    @Test func theRowsOwnRecognisersKeepTheirNormalRelationship() throws {
        let row = MediaFilterRowView()
        let chip = try #require(row.debugChips().first)
        let control = try #require(chip.subviews.compactMap { $0 as? UIControl }.first)
        let itsOwn = try #require(
            control.gestureRecognizers?.first,
            "a control with no recogniser — this half would be vacuous"
        )

        #expect(row.debugRowIsAskedBefore(itsOwn) == false)
    }

    @Test func oneSourceImageDressesEveryChip() {
        let row = MediaFilterRowView()
        row.frame = CGRect(x: 0, y: 0, width: 390, height: MediaFilterRowView.height)

        #expect(row.debugAllChipsHaveAPicture == false, "guard: they start bare")
        row.show(redSquare())

        #expect(row.debugAllChipsHaveAPicture, "every look renders from the one picture it was given")
    }
}
