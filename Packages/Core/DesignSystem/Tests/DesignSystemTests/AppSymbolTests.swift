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
        for (outline, filled) in [
            (AppSymbol.like, AppSymbol.liked), (.save, .saved), (.comment, .commentFilled), (.crown, .crownFilled),
            (.settings, .settingsFill),
            (.bell, .bellFill), (.bellSlash, .bellSlashFill),
            (.send, .sendFill),
            (.camera, .cameraFill), (.gallery, .galleryFill),
            (.trash, .trashFill), (.mic, .micFill), (.bookmark, .bookmarkFill),
        ] {
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

    /// ⚠️ ONE BOX PER FAMILY (#2433, #2457): the owner's gear and bell swap
    /// outline, fill, slash and badge in place — the same box, so the glyph
    /// never moves or resizes.
    @Test(arguments: [
        [AppSymbol.settings, .settingsFill],
        [.bell, .bellFill, .bellSlash, .bellSlashFill, .bellBadge],
        [.send, .sendFill],
        [.camera, .cameraFill], [.gallery, .galleryFill],
        [.trash, .trashFill], [.mic, .micFill], [.bookmark, .bookmarkFill],
    ])
    func aFamilySharesOneBox(_ family: [AppSymbol]) throws {
        let configuration = AppSymbol.fixed(17)
        let first = try #require(family[0].image(configuration))
        for symbol in family.dropFirst() {
            let image = try #require(symbol.image(configuration))
            #expect(abs(image.size.height - first.size.height) <= 0.34, "\(symbol) \(image.size) vs \(family[0]) \(first.size)")
            #expect(abs(image.size.width - first.size.width) <= 0.34, "\(symbol) \(image.size) vs \(family[0]) \(first.size)")
        }
    }

    /// The badged bell draws its badge in the palette's first colour, as the
    /// system's `bell.badge` (`NotificationsBell` bakes it in the accent).
    @Test func theBadgedBellsFirstPaletteColourIsTheBadge() throws {
        let configuration = AppSymbol.fixed(40).applying(UIImage.SymbolConfiguration(paletteColors: [.red, .black]))
        let image = try #require(AppSymbol.bellBadge.image(configuration))
        let size = image.size
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(at: .zero) }
        guard let cg = rendered.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            Issue.record("no bitmap"); return
        }
        var red = 0, black = 0
        let stride = cg.bytesPerRow, step = cg.bitsPerPixel / 8
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                // RGBA or BGRA: red is the one bright outer channel.
                let at = y * stride + x * step
                let c0 = bytes[at], c1 = bytes[at + 1], c2 = bytes[at + 2]
                guard bytes[at + 3] > 200 else { continue }
                if max(c0, c2) > 200 && min(c0, c2) < 60 && c1 < 60 { red += 1 } else if max(c0, c1, c2) < 60 { black += 1 }
            }
        }
        #expect(red > 0 && black > red, "badge \(red) px red, bell \(black) px black")
    }

    /// VoiceOver reads the play and the pause as what they do.
    @Test func thePlayAndPauseReadAsWhatTheyDo() {
        #expect(AppSymbol.play.accessibilityLabel == "Play")
        #expect(AppSymbol.pause.accessibilityLabel == "Pause")
        #expect(AppSymbol.playCircle.accessibilityLabel == "Play")
        #expect(AppSymbol.pause.image()?.accessibilityLabel == "Pause")
    }

    /// The owner's megaphone (#2415): the outline, derived from the fill,
    /// stands in the fill's box, so a site swapping one for the other never
    /// moves; and the fill paints more.
    @Test func theMegaphonesShareOneBox() throws {
        let configuration = AppSymbol.fixed(17)
        let fill = try #require(AppSymbol.megaphoneFill.image(configuration))
        let outline = try #require(AppSymbol.megaphone.image(configuration))
        #expect(abs(fill.size.width - outline.size.width) <= 0.34 && abs(fill.size.height - outline.size.height) <= 0.34,
                "\(fill.size) vs \(outline.size)")
        #expect(inked(fill) > inked(outline))
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
        (.play, "play.fill"), (.pause, "pause.fill"), (.playCircle, "play.circle.fill"),
        (.megaphoneFill, "megaphone.fill"), (.megaphone, "megaphone"),
        (.login, "person.crop.circle.badge.plus"),
        (.map, "map"), (.mapFill, "map.fill"),
        (.settings, "gearshape"), (.settingsFill, "gearshape.fill"),
        (.search, "magnifyingglass"),
        (.bell, "bell"), (.bellFill, "bell.fill"), (.bellSlash, "bell.slash"), (.bellSlashFill, "bell.slash.fill"),
        (.bellBadge, "bell.badge"),
        (.send, "arrowshape.turn.up.forward"), (.sendFill, "arrowshape.turn.up.forward"),
        (.camera, "camera"), (.cameraFill, "camera.fill"),
        (.gallery, "photo.on.rectangle"), (.galleryFill, "photo.on.rectangle"),
        (.trash, "trash"), (.trashFill, "trash.fill"), (.mic, "mic"), (.micFill, "mic.fill"),
        (.bookmark, "pin"), (.bookmarkFill, "pin.fill"), (.bookmarkSlash, "pin.slash"),
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


/// What a glyph paints (#2581), measured on its bitmap at 3×: the box of
/// its solid ink, the area it covers and its ink's centre of mass, in points
/// from the image's top left.
struct SymbolInk: CustomStringConvertible {
    let box: CGRect
    let area: CGFloat
    let mass: CGPoint
    let size: CGSize

    init(_ image: UIImage) {
        // Drawn into a bitmap of our own, 8 bits a channel with alpha last: a
        // renderer's automatic format drew some symbols in a layout the
        // byte reads took for no ink at all.
        let scale: CGFloat = 3, pad: CGFloat = 4
        size = image.size
        let width = Int(ceil((image.size.width + 2 * pad) * scale))
        let height = Int(ceil((image.size.height + 2 * pad) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            box = .zero; area = 0; mass = .zero
            return
        }
        // UIKit's top-left origin, at 3×.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: pad, y: pad))
        UIGraphicsPopContext()
        guard let data = context.data else {
            box = .zero; area = 0; mass = .zero
            return
        }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var sum: CGFloat = 0, sumX: CGFloat = 0, sumY: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = CGFloat(bytes[(y * width + x) * 4 + 3]) / 255
                guard alpha > 0 else { continue }
                sum += alpha
                sumX += alpha * (CGFloat(x) + 0.5)
                sumY += alpha * (CGFloat(y) + 0.5)
                guard alpha >= 0.5 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        box = maxX < 0 ? .zero : CGRect(
            x: CGFloat(minX) / scale - pad, y: CGFloat(minY) / scale - pad,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
        area = sum / (scale * scale)
        mass = sum > 0 ? CGPoint(x: sumX / sum / scale - pad, y: sumY / sum / scale - pad) : .zero
    }

    /// The ink's centre of mass from the image's centre: right and down.
    var massOffset: UIOffset { UIOffset(horizontal: mass.x - size.width / 2, vertical: mass.y - size.height / 2) }

    var description: String {
        let numbers = [box.width, box.height, area, massOffset.horizontal, massOffset.vertical]
        let shown = numbers.map { String(format: "%.2f", Double($0)) }
        return "ink \(shown[0])×\(shown[1]) pt, \(shown[2]) pt², mass (\(shown[3]), \(shown[4])) from the centre"
    }
}

/// Share in a bubble (#2581): the plane reads the like pill's heart's size by
/// its drawn ink, and stands by its ink's centre of mass.
extension AppSymbolSizeTests {
    /// The like pill's heart as drawn: `SnapActionColumn.heartConfiguration`
    /// (15 pt semibold) at the `.large` scale a `UIButton.Configuration`
    /// gives a symbol that names none (`ShareBubbleGlyphTests` holds the pill
    /// to it). 20.7 × 17.7 pt of ink, the owner's measure on a device.
    static let drawnHeartConfiguration = AppSymbol.fixed(15, weight: .semibold)
        .applying(UIImage.SymbolConfiguration(scale: .large))

    /// Area and box (the box's mean side, √(w·h)) within 8 %. The plane's box
    /// is square and the heart's wide, so the box compares by its mean side.
    @Test func shareInABubbleIsAsLargeAsTheHeartBesideIt() throws {
        let share = SymbolInk(try #require(ShareBubbleGlyph.image()))
        let heart = SymbolInk(try #require(AppSymbol.like.image(Self.drawnHeartConfiguration)))
        print("[share-ink] share \(share) · heart \(heart)")
        let area = share.area / heart.area - 1
        let box = ((share.box.width * share.box.height) / (heart.box.width * heart.box.height)).squareRoot() - 1
        #expect(abs(area) <= 0.08, "Share paints \(share.area) pt², the heart \(heart.area) (\(area))")
        #expect(abs(box) <= 0.08, "Share's ink box is \(share.box.size), the heart's \(heart.box.size) (\(box))")
        // The composer's old 17 pt read a quarter narrower than the heart.
        let old = SymbolInk(try #require(AppSymbol.send.image(AppSymbol.fixed(17, weight: .semibold))))
        #expect(old.area / heart.area - 1 < -0.08, "the old size already matched: \(old)")
    }

    /// The move brings the ink's centre of mass within a quarter point of the
    /// image's centre; unmoved, the plane stands over a point off.
    @Test func shareInABubbleStandsByItsInk() throws {
        let ink = SymbolInk(try #require(ShareBubbleGlyph.image()))
        let move = ShareBubbleGlyph.offset()
        let left = UIOffset(horizontal: ink.massOffset.horizontal + move.horizontal, vertical: ink.massOffset.vertical + move.vertical)
        print("[share-ink] \(ShareBubbleGlyph.pointSize) pt: \(ink); moved \(move) → \(left)")
        #expect(hypot(left.horizontal, left.vertical) <= 0.25, "the ink stands \(left) off the centre")
        #expect(hypot(ink.massOffset.horizontal, ink.massOffset.vertical) > 1, "the plane is centred unmoved: the offset is stale")
    }

    /// A configured glass button wearing Share at `contentInsets(_:for:)`
    /// stands its image `offset()` off its centre: the button centres the
    /// image's alignment rectangle, which the insets take into account.
    @Test(arguments: [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft])
    func aConfiguredButtonStandsShareByItsInk(_ direction: UIUserInterfaceLayoutDirection) throws {
        let image = try #require(ShareBubbleGlyph.image())
        var configuration = UIButton.Configuration.glass()
        configuration.image = image
        configuration.contentInsets = ShareBubbleGlyph.contentInsets(configuration.contentInsets, for: image, direction: direction)
        let button = UIButton(configuration: configuration)
        button.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        button.frame = CGRect(x: 20, y: 20, width: 45, height: 45)
        window.addSubview(button)
        window.isHidden = false
        defer { window.isHidden = true }
        button.layoutIfNeeded()
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        let drawn = try #require(all(button).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        let frame = drawn.convert(drawn.bounds, to: button)
        // Drawn at the bubble size: the `.medium` scale keeps the button's own.
        #expect(abs(frame.width - image.size.width) < 0.01 && abs(frame.height - image.size.height) < 0.01, "\(frame.size)")
        let stands = UIOffset(horizontal: frame.midX - button.bounds.midX, vertical: frame.midY - button.bounds.midY)
        let move = ShareBubbleGlyph.offset()
        print("[share-button] \(direction == .leftToRight ? "ltr" : "rtl"): the image stands \(stands), wanted \(move)")
        // Within a device pixel: the button rounds the image's frame to the 3× grid.
        #expect(abs(stands.horizontal - move.horizontal) <= 0.34 && abs(stands.vertical - move.vertical) <= 0.34,
                "the image stands \(stands) off the centre, not \(move)")
    }
}
