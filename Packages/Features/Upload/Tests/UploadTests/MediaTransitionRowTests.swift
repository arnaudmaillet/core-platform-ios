import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE ROW OF TRANSITIONS, AND ITS GLASS CLOSE BUTTON.**
///
/// Asked for in these words: *"une icône de croix à droite fixe (dans un liquid
/// glass natif) … les éléments de la scrollview des transitions se fadent
/// lorsqu'ils passent par derrière ce bouton"*, and *"un choix nul/vide pour
/// supprimer toute transition"*.
@MainActor
struct MediaTransitionRowTests {
    private func row(width: CGFloat = 390) -> MediaTransitionRowView {
        let row = MediaTransitionRowView()
        row.frame = CGRect(x: 0, y: 0, width: width, height: MediaTransitionRowView.height)
        row.layoutIfNeeded()
        return row
    }

    @Test func noneComesFirst() {
        #expect(row().debugLabels == [
            "None", "Black", "White", "Zoom", "Dissolve", "Swipe", "Bars", "Scan", "Flash", "Swirl",
            "Page", "Curl", "Ripple", "Fold", "Crumble"
        ])
    }

    @Test func theChosenChipIsTheWhiteOne() {
        let row = row()
        var picked: [VideoTransitionKind?] = []
        row.onPick = { picked.append($0) }
        #expect(row.debugChosen == ["None"], "a bare cut: \(row.debugChosen)")

        row.show(kind: .dipToWhite)
        #expect(row.debugChosen == ["White"])
        #expect(picked.isEmpty, "stating a choice announced it")

        row.debugTap(.zoom)
        row.debugTap(nil)
        #expect(picked == [.zoom, nil])
        #expect(row.debugChosen == ["None"])
    }

    /// ⚠️ **THE RAMP ENDS WHERE THE GLASS BEGINS, AND THE MASK STANDS STILL.**
    @Test func theChipsFadeUnderTheCloseButton() {
        let row = row()
        let stops = row.debugFadeStops
        let wanted = [0, 294.0 / 390, 346.0 / 390, 1]
        #expect(stops.count == 4 && zip(stops, wanted).allSatisfy { abs($0 - $1) < 0.001 }, "got \(stops)")
        #expect(abs(row.debugGlassFrame.minX - 346) < 0.01, "the glass begins at \(row.debugGlassFrame.minX)")
        #expect(row.debugMaskIsOnTheHost, "the mask is on the scroller")

        row.debugScroller.contentOffset.x = 40
        row.layoutIfNeeded()
        #expect(row.debugFadeFrame.minX == 0, "the mask moved with the chips: \(row.debugFadeFrame)")

        row.frame.size.width = 375
        row.layoutIfNeeded()
        let narrower = row.debugFadeStops
        let wantedNarrower = [0, 279.0 / 375, 331.0 / 375, 1]
        #expect(zip(narrower, wantedNarrower).allSatisfy { abs($0 - $1) < 0.001 }, "at 375: \(narrower)")
    }

    /// ⚠️ **SCROLLED TO THE END, THE LAST CARD IS WHOLE** — it rests before the
    /// ramp, never half dissolved inside it. Asked at a width where the four
    /// cards really scroll: on a phone they all fit, and the test would prove
    /// nothing there.
    @Test func theLastCardRestsPastTheRamp() throws {
        let row = row(width: 300)
        let scroller = row.debugScroller
        let furthest = scroller.contentSize.width + scroller.contentInset.right - scroller.bounds.width
        try #require(furthest > 0, "the row does not scroll at this width: \(furthest)")
        scroller.contentOffset.x = furthest
        row.layoutIfNeeded()

        let last = try #require(row.debugCardFrames.last)
        #expect(last.maxX <= 300 - 8 - 36 - 52 + 0.01, "the last card rests at \(last.maxX), inside the ramp")
    }

    /// On the narrowest phone, the first four cards rest whole before the ramp;
    /// the rest are scrolled to.
    @Test func theFirstFourCardsRestWholeBeforeTheRamp() throws {
        let row = row(width: 375)
        let scroller = row.debugScroller
        try #require(scroller.contentOffset.x == -scroller.contentInset.left, "guard: the row is not at rest")

        let cards = Array(row.debugCardFrames.prefix(4))
        try #require(cards.count == 4)
        #expect(cards.allSatisfy { $0.minX >= 8 - 0.01 && $0.maxX <= 375 - 8 - 36 - 52 + 0.01 }, "got \(cards)")
    }

    /// ⚠️ **A CUT CARRYING A FAR CARD OPENS ON IT.** Fifteen cards do not fit
    /// on a phone; the white card must be in view, before the ramp.
    @Test func aRowOpensOnTheChosenCard() throws {
        let row = row(width: 375)
        row.setOpen(false, animated: false)
        row.show(kind: .disintegrate)
        row.setOpen(true, animated: false)

        let chosen = try #require(row.debugCardFrames.last, "guard: no cards")
        #expect(chosen.minX >= 8 - 0.01 && chosen.maxX <= 375 - 8 - 36 - 52 + 0.01,
                "the chosen card rests at \(chosen)")
        // A near card leaves the row at its start.
        row.setOpen(false, animated: false)
        row.show(kind: .dipToBlack)
        row.setOpen(true, animated: false)
        let scroller = row.debugScroller
        #expect(scroller.contentOffset.x == -scroller.contentInset.left, "the row moved for a card in view")
    }

    // MARK: - Cards

    /// ⚠️ **ASKED FOR**: *"des cards avec l'icône et le texte en dessous dans la
    /// card"*. The words line up whatever the symbol above them.
    @Test func theChoicesAreCardsWithTheWordUnderTheSymbol() throws {
        let row = row()
        let cards = row.debugCardFrames
        let glyphs = row.debugGlyphFrames
        let captions = row.debugCaptionFrames
        let choices = MediaTransitionCatalog.choices.count
        try #require(choices == 15, "guard: \(choices) choices")
        try #require(cards.count == choices && glyphs.count == choices && captions.count == choices)
        for ((card, glyph), caption) in zip(zip(cards, glyphs), captions) {
            #expect(abs(card.width - 56) < 0.01 && abs(card.height - MediaTransitionRowView.height) < 0.01,
                    "a card is \(card.size)")
            #expect(abs((caption.minY - glyph.maxY) - 2) < 0.01, "the word is not under the symbol: \(glyph) \(caption)")
            #expect(abs(glyph.midX - card.midX) < 0.5 && abs(caption.midX - card.midX) < 0.5,
                    "not centred: \(card) \(glyph) \(caption)")
            #expect(card.contains(glyph) && card.contains(caption), "the contents spill: \(card) \(glyph) \(caption)")
        }
        let tops = Set(captions.map { ($0.minY * 100).rounded() })
        #expect(tops.count == 1, "the words sit at \(captions.map(\.minY))")
    }

    /// The card drawn by the CPU renderer at 3x over a ground, read as RGBA.
    private func pixels(
        of row: MediaTransitionRowView, over ground: UIColor
    ) -> (CGFloat, CGFloat) -> (r: Int, g: Int, b: Int) {
        let host = UIView(frame: row.bounds)
        host.backgroundColor = ground
        host.addSubview(row)
        let scale: CGFloat = 3
        let width = Int(host.bounds.width * scale)
        let height = Int(host.bounds.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            host.layer.render(in: context)
        }
        return { x, y in
            let column = min(max(Int(x * scale), 0), width - 1)
            let line = min(max(Int(y * scale), 0), height - 1)
            let at = (line * width + column) * 4
            return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
        }
    }

    private func luminance(_ grey: Int) -> Double {
        let c = Double(grey) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Every pixel of `frame`, as grey levels.
    private func greys(
        in frame: CGRect, _ read: (CGFloat, CGFloat) -> (r: Int, g: Int, b: Int)
    ) -> [Int] {
        var found: [Int] = []
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX
            while x < frame.maxX {
                let pixel = read(x, y)
                found.append((pixel.r + pixel.g + pixel.b) / 3)
                x += 1.0 / 3
            }
            y += 1.0 / 3
        }
        return found
    }

    /// ⚠️ **A DARK CARD OVER WHITE FOOTAGE, AND ITS WORD STAYS READABLE** — the
    /// case a card without a fill loses.
    @Test func anUnchosenCardIsADarkCardOverWhiteFootage() throws {
        let row = row()
        row.setOpen(true, animated: false)
        row.layoutIfNeeded()
        let read = pixels(of: row, over: .white)
        let card = try #require(row.debugCardFrames.dropFirst().first, "the Black card")
        let caption = try #require(row.debugCaptionFrames.dropFirst().first)

        let body = read(card.minX + 3, card.midY)
        let grey = (body.r + body.g + body.b) / 3
        #expect(grey <= 128 && grey >= 64, "the card over white reads \(body)")
        let brightest = try #require(greys(in: caption, read).max())
        #expect(brightest >= 245, "the word is not white: \(brightest)")
        let contrast = (luminance(brightest) + 0.05) / (luminance(grey) + 0.05)
        #expect(contrast >= 4.5, "the word reads at \(contrast):1")
    }

    @Test func anUnchosenCardShowsItsEdgeOverBlackFootage() throws {
        let row = row()
        row.setOpen(true, animated: false)
        row.layoutIfNeeded()
        let read = pixels(of: row, over: .black)
        let card = try #require(row.debugCardFrames.dropFirst().first)

        let rim = read(card.minX + 0.1, card.midY)
        let body = read(card.minX + 3, card.midY)
        #expect((rim.r + rim.g + rim.b) / 3 >= 40, "no edge over black: \(rim)")
        #expect((body.r + body.g + body.b) / 3 <= 10, "the card is not dark: \(body)")
    }

    /// ⚠️ **OVER BLACK**, so a row that drew nothing cannot pass by showing the
    /// ground.
    @Test func theChosenCardIsWhiteWithBlackInk() throws {
        let row = row()
        row.setOpen(true, animated: false)
        row.show(kind: .dipToWhite)
        row.layoutIfNeeded()
        let read = pixels(of: row, over: .black)
        let cards = row.debugCardFrames
        let white = cards[2]
        let none = cards[0]

        let body = read(white.minX + 3, white.midY)
        #expect((body.r + body.g + body.b) / 3 >= 250, "the chosen card is not white: \(body)")
        let darkest = try #require(greys(in: row.debugCaptionFrames[2], read).min())
        #expect(darkest <= 10, "the chosen word is not black: \(darkest)")
        let bare = read(none.minX + 3, none.midY)
        #expect((bare.r + bare.g + bare.b) / 3 <= 10, "None is still drawn chosen: \(bare)")
    }

    /// ⚠️ **NO TOUCH UNTIL THE ROW HAS LANDED** — a double tap on a cut's +
    /// would choose the card fading in under the second tap.
    @Test func theRowTakesNoTouchUntilItHasOpened() async throws {
        let row = row()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        window.addSubview(row)
        window.isHidden = false
        defer { window.isHidden = true }

        row.setOpen(true, animated: true)
        #expect(!row.debugTakesTouches, "the row took touches while fading in")
        for _ in 0..<100 where !row.debugTakesTouches { try await Task.sleep(for: .milliseconds(10)) }
        #expect(row.debugTakesTouches, "the row never took touches")

        let still = self.row()
        still.setOpen(true, animated: false)
        #expect(still.debugTakesTouches, "a row opened without animation takes no touch")
    }

    /// Voice Control is asked by what is written on the card.
    @Test func eachCardAnswersToItsWord() {
        let row = row()
        for (card, word) in zip(row.debugCards, row.debugLabels) {
            #expect(card.accessibilityUserInputLabels?.first == word, "\(word) answers to \(card.accessibilityUserInputLabels ?? [])")
        }
    }

    @Test func theCloseButtonIsGlassOnlyWhileOpen() {
        let row = row()
        #expect(row.isHidden && !row.debugHasGlass, "the row was born open")

        row.setOpen(true, animated: false)
        #expect(!row.isHidden && row.debugHasGlass, "the open row has no glass")

        row.setOpen(false, animated: false)
        #expect(row.isHidden && !row.debugHasGlass, "the glass outlived the row")
    }

    @Test func theCloseButtonIsAFingerWide() {
        let row = row()
        var closed = 0
        row.onClose = { closed += 1 }
        row.setOpen(true, animated: false)
        let glass = row.debugGlassFrame

        #expect(row.hitTest(CGPoint(x: glass.minX - 4, y: glass.midY), with: nil) === row.debugCloseButton,
                "4pt beside the glass misses the button")
        #expect(row.hitTest(CGPoint(x: glass.midX, y: glass.midY), with: nil) === row.debugCloseButton)
        #expect(row.hitTest(CGPoint(x: 40, y: glass.midY), with: nil) !== row.debugCloseButton,
                "the button swallows the cards")
        let first = row.debugCardFrames[0]
        for point in [CGPoint(x: first.midX, y: first.midY), CGPoint(x: first.minX + 2, y: first.minY + 2)] {
            #expect(row.hitTest(point, with: nil) === row.debugCards[0], "the card is not its own target at \(point)")
        }

        row.debugTapClose()
        #expect(closed == 1)
    }

    /// ⚠️ **EXACTLY THE ROOM THE LINE FREES**, inside the track's own frame.
    @Test func theRowIsExactlyTheRoomTheLineFrees() {
        #expect(MediaTransitionRowView.height
                == MediaTimelineTrackView.height - MediaTimelineTrackView.compactHeight - Spacing.sm)
        let tools = MediaTimelineToolsView()
        tools.frame = CGRect(x: 0, y: 0, width: 390, height: MediaTimelineTrackView.height)
        tools.layoutIfNeeded()
        let track = tools.track.frame
        let row = tools.transitions.frame
        #expect(abs(row.minY - (track.minY + MediaTimelineTrackView.compactHeight + Spacing.sm)) < 0.01,
                "the row begins at \(row.minY)")
        #expect(abs(row.maxY - track.maxY) < 0.01 && row.minX == track.minX && row.width == track.width,
                "the row is \(row), the track \(track)")
    }
}
