import Testing
import UIKit
@testable import DesignSystem

/// The app's custom glyphs (#1128): every one resolves and draws, at every
/// weight and size it is asked for.
@MainActor
struct AppSymbolTests {
    /// The share of a glyph's square that it paints, light on white.
    private func inked(_ image: UIImage) -> CGFloat {
        let size = CGSize(width: 64, height: 64)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.withTintColor(.black, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
        guard let cg = rendered.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        var dark = 0
        let stride = cg.bytesPerRow, step = cg.bitsPerPixel / 8
        for y in 0..<cg.height {
            for x in 0..<cg.width where bytes[y * stride + x * step] < 128 { dark += 1 }
        }
        return CGFloat(dark) / CGFloat(cg.width * cg.height)
    }

    /// ⚠️ A name that does not resolve draws nothing and errors nowhere.
    @Test(arguments: AppSymbol.allCases)
    func everyGlyphResolvesAndDraws(_ symbol: AppSymbol) throws {
        for weight in [UIImage.SymbolWeight.ultraLight, .regular, .black] {
            let image = try #require(symbol.image(AppSymbol.fixed(20, weight: weight)), "\(symbol) at \(weight)")
            #expect(image.isSymbolImage)
            let ink = inked(image)
            #expect(ink > 0.05 && ink < 0.9, "\(symbol) paints \(ink) of its square")
        }
    }

    /// A filled glyph paints more than its outline.
    @Test func theFilledGlyphsAreFilled() throws {
        for (outline, filled) in [(AppSymbol.like, AppSymbol.liked), (.save, .saved), (.comment, .commentFilled), (.crown, .crownFilled)] {
            let a = inked(try #require(outline.image(AppSymbol.fixed(20))))
            let b = inked(try #require(filled.image(AppSymbol.fixed(20))))
            #expect(b > a, "\(filled) (\(b)) is not fuller than \(outline) (\(a))")
        }
    }

    /// A glyph beside text grows with it, and stops at the ceiling.
    @Test func aTextGlyphFollowsItsText() throws {
        let small = try #require(AppSymbol.like.image(
            AppSymbol.textStyle(.body).applying(UIImage.SymbolConfiguration(
                font: .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .small))
            ))
        ))
        let large = try #require(AppSymbol.like.image(UIImage.SymbolConfiguration(
            font: .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge))
        )))
        #expect(large.size.height > small.size.height)
    }

    /// ⚠️ The owner's play and pause (#2276) resolve at every size a site
    /// draws them — 13 pt (the timeline), 16 (the compact voice), 22 (the
    /// sound sheet), 56 (a paused clip): `UIImage(systemName:)` would find
    /// nothing, and the control would draw nothing.
    @Test(arguments: [AppSymbol.play, .pause, .playCircle])
    func thePlayAndPauseResolveAtEverySize(_ symbol: AppSymbol) throws {
        for size in [CGFloat(13), 16, 22, 56] {
            let image = try #require(symbol.image(AppSymbol.fixed(size, weight: .semibold)), "\(symbol) at \(size) pt")
            #expect(image.isSymbolImage)
            #expect(image.size.width > 0 && image.size.height > 0, "\(symbol) at \(size) pt is \(image.size)")
            #expect(inked(image) > 0.05, "\(symbol) at \(size) pt paints nothing")
            #expect(UIImage.symbol(named: symbol.rawValue, configuration: AppSymbol.fixed(size)) != nil)
        }
    }

    /// ⚠️ ONE BOX FOR PLAY AND PAUSE (#2276): a swap between them never moves
    /// the glyph — the same width, the same line, the same margins.
    @Test func thePlayAndThePauseShareOneBox() throws {
        for size in [CGFloat(13), 16, 22, 56] {
            let configuration = AppSymbol.fixed(size, weight: .semibold)
            let play = try #require(AppSymbol.play.image(configuration))
            let pause = try #require(AppSymbol.pause.image(configuration))
            // Within one device pixel: the bitmaps round each glyph's box to
            // the pixel grid on its own (12.67 vs 12.33 pt at 13 pt, 3×) —
            // a sixth of a point at the centre, not a jump.
            #expect(abs(play.size.width - pause.size.width) <= 0.34, "at \(size) pt: \(play.size) vs \(pause.size)")
            #expect(abs(play.size.height - pause.size.height) <= 1, "at \(size) pt: \(play.size) vs \(pause.size)")
            #expect(abs(play.alignmentRectInsets.left - pause.alignmentRectInsets.left) < 0.01)
            #expect(abs(play.alignmentRectInsets.right - pause.alignmentRectInsets.right) < 0.01)
            let playBaseline = play.baselineOffsetFromBottom ?? 0, pauseBaseline = pause.baselineOffsetFromBottom ?? 0
            #expect(abs(playBaseline - pauseBaseline) <= 1, "at \(size) pt: baselines \(playBaseline) vs \(pauseBaseline)")
        }
    }

    /// VoiceOver reads the play and the pause as what they do.
    @Test func thePlayAndPauseReadAsWhatTheyDo() {
        #expect(AppSymbol.play.accessibilityLabel == "Play")
        #expect(AppSymbol.pause.accessibilityLabel == "Pause")
        #expect(AppSymbol.playCircle.accessibilityLabel == "Play")
        #expect(AppSymbol.pause.image()?.accessibilityLabel == "Pause")
    }

    /// VoiceOver reads the star as Save, not as a favourite.
    @Test func theStarReadsAsSave() {
        #expect(AppSymbol.save.accessibilityLabel == "Save")
        #expect(AppSymbol.saved.accessibilityLabel == "Saved")
        #expect(AppSymbol.saved.image()?.accessibilityLabel == "Saved")
    }
}

/// The custom glyphs sit at the system's size (#1128): a heart that swapped
/// in for `heart.fill` must not grow the line it sits on.
@MainActor
struct AppSymbolSizeTests {
    @Test(arguments: [
        (AppSymbol.liked, "heart.fill"), (.save, "star"), (.comment, "ellipsis.message"),
        (.repost, "arrow.trianglehead.2.clockwise.rotate.90"), (.crownFilled, "crown.fill"),
        (.share, "square.and.arrow.up"),
        (.play, "play.fill"), (.pause, "pause.fill"), (.playCircle, "play.circle.fill"),
    ])
    func aGlyphIsAsTallAsTheSystemsOwn(_ pair: (AppSymbol, String)) throws {
        let configuration = AppSymbol.fixed(12, weight: .semibold)
        let custom = try #require(pair.0.image(configuration))
        let system = try #require(UIImage(systemName: pair.1, withConfiguration: configuration))
        print("[symbol-size] \(pair.0) \(custom.size) insets \(custom.alignmentRectInsets) vs \(pair.1) \(system.size) insets \(system.alignmentRectInsets) baseline \(custom.baselineOffsetFromBottom ?? -1) vs \(system.baselineOffsetFromBottom ?? -1)")
        #expect(abs(custom.size.height - system.size.height) <= max(1, system.size.height * 0.08),
                "\(pair.0) is \(custom.size.height) tall, \(pair.1) \(system.size.height)")
    }
}

