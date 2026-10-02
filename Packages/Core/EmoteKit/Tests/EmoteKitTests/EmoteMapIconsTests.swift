import Foundation
import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// Emotes as map icon faces (`EmoteMapIcons`): which face a post wears, how
/// its id resolves, and — baked for real — that a face is never an empty disc.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteMapIconsTests {
    // MARK: - Which face

    /// The world's icon-face posts wear the emote their caption carries — the
    /// countries that drew an empty disc among them.
    @Test(arguments: [
        ("Pierogi count: lost track at twelve. :lol:", "lol"),                          // Poland
        ("Makroudh tasting: nine shops, nine winners. :blush:", "blush"),               // Tunisia
        ("Night market plan: one of everything. Status: ongoing. :lol:", "lol"),        // Taiwan
        ("The train to Ella left without me. Tea instead. :blush:", "blush"),           // Sri Lanka
        ("Four seasons before lunch, as promised. :weather:", "weather"),
        ("Samba lesson #1: my feet filed a complaint. 💃", "noto:1f483"),
    ])
    func aCaptionWearsItsOwnEmote(caption: String, id: String) {
        #expect(EmoteMapIcons.faceID(forCaption: caption) == id)
    }

    /// Morocco's caption ends on 🌙, which this build does not animate: no face
    /// from the caption, so the post takes one of the default faces.
    @Test func aCaptionWithoutAnAnimatedEmoteNamesNone() {
        #expect(EmoteMapIcons.faceID(forCaption: "Jemaa el-Fnaa at night: smoke, drums, a hundred stories. 🌙") == nil)
        #expect(EmoteMapIcons.faceID(forCaption: "Traffic report: yes.") == nil)
    }

    /// Every default face is a real emote and a FACE — a house emote or a
    /// smiley — never one of the map catalogue's geometric placeholders.
    @Test func theDefaultFacesAreFaces() {
        let faces = EmoteMapIcons.defaultFaceIDs
        #expect(faces.count >= 6, "\(faces)")
        for id in faces {
            let emote = EmoteCatalog.shared.emote(id: id)
            #expect(emote != nil, "\(id) is not an emote")
            #expect(emote.map { [.house, .smileys].contains($0.section) } == true, "\(id)")
            #expect(!id.contains("-spin") && !id.contains("-pulse") && !id.contains("-bob")
                    && !id.contains("-flicker"), "\(id) is a placeholder")
        }
    }

    // MARK: - Resolving

    /// An emote id resolves through the engine, at the marker's size; any
    /// other id through the baked catalogue, which here has nothing.
    @Test func anEmoteResolvesThroughTheEngine() async throws {
        let engine = EmoteEngine(diskCache: nil)
        let emote = try #require(engine.catalog.emote(id: "noto:1f602"))
        let art = EmoteStripTests.sheetArt(frames: 4, step: 0.1)
        engine.insert(art, for: emote, pixelSide: EmoteMapIcons.pixelSide, motion: .loop)
        let icons = EmoteMapIcons(engine: engine, catalogue: AnimatedIconCatalog(manifest: "absent-in-tests"))
        #expect(icons.cached("noto:1f602") == art)
        #expect(try await icons.art(for: "noto:1f602") == art)
        #expect(icons.cached("15-petal-flicker") == nil)
        await #expect(throws: (any Error).self) { try await icons.art(for: "15-petal-flicker") }
    }

    @Test func aMarkerFaceIsBakedAtTheLargestSize() {
        #expect(EmoteMapIcons.pixelSide == EmoteEngine.pixelBuckets.last)
    }

    // MARK: - Never an empty disc

    /// How many colours a picture's SOLID pixels fall into, counting only
    /// those with at least 2% of them — a flat disc is one, a face is several.
    static func solidColours(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let (width, height) = (cgImage.width, cgImage.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var bins: [Int: Int] = [:]
        var solid = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 230 {
            solid += 1
            // 3 bits a channel: anti-aliasing and gradients stay in their bin.
            let key = Int(pixels[index] >> 5) << 6 | Int(pixels[index + 1] >> 5) << 3 | Int(pixels[index + 2] >> 5)
            bins[key, default: 0] += 1
        }
        guard solid > 0 else { return 0 }
        return bins.values.filter { Double($0) >= Double(solid) * 0.02 }.count
    }

    /// The probe tells the two apart: the placeholder that drew the empty
    /// disc (one flat colour) reads as one colour, a two-tone face as more.
    @Test func theProbeSeesAnEmptyDisc() {
        let side = CGSize(width: 64, height: 64)
        let disc = UIGraphicsImageRenderer(size: side).image { _ in
            UIColor(red: 0.95, green: 0.63, blue: 1, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: side).insetBy(dx: 8, dy: 8)).fill()
        }
        #expect(Self.solidColours(of: disc) == 1)
        let face = UIGraphicsImageRenderer(size: side).image { _ in
            UIColor.systemYellow.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: side).insetBy(dx: 8, dy: 8)).fill()
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(x: 20, y: 36, width: 24, height: 6)).fill()
            UIBezierPath(ovalIn: CGRect(x: 20, y: 20, width: 6, height: 8)).fill()
            UIBezierPath(ovalIn: CGRect(x: 38, y: 20, width: 6, height: 8)).fill()
        }
        #expect(Self.solidColours(of: face) >= 2)
    }

    /// The real thing, baked at the marker's size: every default face that
    /// the engine bakes itself draws something INSIDE its outline — never an
    /// empty disc. (`lol` and `blush` come from the app's map catalogue,
    /// which this target does not bundle.)
    @Test func bakedFacesAreNeverEmptyDiscs() async throws {
        var lines: [String] = []
        for id in EmoteMapIcons.defaultFaceIDs + ["noto:1f483", "weather"] {
            let engine = EmoteEngine(diskCache: nil)
            engine.bakeDelay = .zero
            let emote = try #require(engine.catalog.emote(id: id))
            if case .icon = emote.source { continue }
            let art = try #require(await engine.art(for: emote, pixelSide: EmoteMapIcons.pixelSide), "\(id)")
            let poster = try #require(Self.frame(art.posterFrame(), of: art), "\(id)")
            let colours = Self.solidColours(of: poster)
            #expect(colours >= 2, "\(id) (\(emote.glyph)) draws \(colours) colour(s): an empty disc")
            lines.append("\(emote.glyph) \(id) frames=\(art.frameCount) colours=\(colours)")
        }
        print("[map-faces]\n" + lines.joined(separator: "\n"))
    }

    /// One frame of a sheet, cropped out.
    static func frame(_ index: Int, of art: AnimatedIconArt) -> UIImage? {
        guard case .sheet(let sheet) = art, let cgImage = sheet.sheet.cgImage,
              sheet.frameRects.indices.contains(index) else { return art.firstFrame() }
        let rect = sheet.frameRects[index]
        let pixels = CGRect(
            x: rect.minX * CGFloat(cgImage.width), y: rect.minY * CGFloat(cgImage.height),
            width: rect.width * CGFloat(cgImage.width), height: rect.height * CGFloat(cgImage.height)
        ).integral
        return cgImage.cropping(to: pixels).map { UIImage(cgImage: $0) }
    }
}
