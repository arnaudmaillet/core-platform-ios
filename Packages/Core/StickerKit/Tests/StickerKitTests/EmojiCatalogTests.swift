import CoreText
import Synchronization
import Testing
import UIKit
@testable import StickerKit

/// The emoji a picker offers: every one draws as ONE Apple Color Emoji
/// picture, and a name finds it.
struct EmojiCatalogTests {
    /// Checked here with the test's own Core Text reading, not the catalogue's
    /// filter, so a filter that lets anything through is caught.
    private static func glyphs(of text: String) -> (count: Int, fonts: Set<String>) {
        let font = UIFont(name: "AppleColorEmoji", size: 40)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let fonts = runs.compactMap { run in
            ((CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.font] as? UIFont)?.fontName
        }
        return (CTLineGetGlyphCount(line), Set(fonts))
    }

    @Test func emojiOnlyRenderable() throws {
        let all = EmojiCatalog.all
        #expect(all.count > 1000, "\(all.count) entries")
        #expect(Set(all.map(\.glyph)).count == all.count)

        let grinning = try #require(all.first { $0.glyph == "😀" })
        #expect(grinning.name == "grinning face")
        #expect(grinning.section == .faces)
        let france = try #require(all.first { $0.glyph == "🇫🇷" })
        #expect(france.name == "flag: France")
        #expect(france.section == .flags)
        // A text-default emoji wears the emoji presentation selector.
        let sun = try #require(all.first { $0.glyph == "\u{2600}\u{FE0F}" })
        #expect(sun.section == .symbols)

        #expect(!all.contains { $0.glyph.unicodeScalars.contains { $0.properties.isEmojiModifier } })
        let loneIndicators = all.filter { emoji in
            emoji.glyph.unicodeScalars.count == 1
                && (0x1F1E6...0x1F1FF).contains(emoji.glyph.unicodeScalars.first!.value)
        }
        #expect(loneIndicators.isEmpty)

        for emoji in all {
            let drawn = Self.glyphs(of: emoji.glyph)
            #expect(drawn.count == 1 && drawn.fonts == ["AppleColorEmoji"], "\(emoji.name) draws \(drawn)")
        }
    }

    @Test func theGlyphTestRefusesWhatIsNotOnePicture() {
        #expect(EmojiCatalog.drawsAsOneEmojiGlyph("😀"))
        #expect(EmojiCatalog.drawsAsOneEmojiGlyph("🇯🇵"))
        #expect(EmojiCatalog.drawsAsOneEmojiGlyph("\u{2600}\u{FE0F}"))
        // Two letters, one plain letter, a region with no flag, and a
        // private-use character the emoji font does not have.
        #expect(!EmojiCatalog.drawsAsOneEmojiGlyph("AB"))
        #expect(!EmojiCatalog.drawsAsOneEmojiGlyph("a"))
        #expect(!EmojiCatalog.drawsAsOneEmojiGlyph("🇦🇦"))
        #expect(!EmojiCatalog.drawsAsOneEmojiGlyph("\u{E000}"))
    }

    @Test func sectionsFollowTheCatalogue() {
        let sectioned = EmojiCatalog.Section.allCases.flatMap { EmojiCatalog.emoji(in: $0) }
        #expect(sectioned == EmojiCatalog.all)
        #expect(EmojiCatalog.emoji(in: .travel).contains { $0.glyph == "🚗" })
        #expect(EmojiCatalog.emoji(in: .flags).count > 200)
    }

    @Test func searchFindsByName() {
        let grin = EmojiCatalog.search("Grin")
        #expect(grin.contains { $0.glyph == "😀" })
        #expect(!grin.contains { $0.glyph == "🚗" })

        // Every word must start a word of the name, in any order.
        #expect(EmojiCatalog.search("face grinning").contains { $0.glyph == "😀" })
        #expect(!EmojiCatalog.search("grinning car").contains { $0.glyph == "😀" })
        #expect(EmojiCatalog.search("automob").map(\.glyph) == ["🚗", "🚘"])
        #expect(EmojiCatalog.search("oncoming automob").map(\.glyph) == ["🚘"])

        #expect(EmojiCatalog.search("FRANCE").map(\.glyph) == ["🇫🇷"])
        // Accents are ignored on both sides: "Réunion".
        #expect(EmojiCatalog.search("reunion").contains { $0.glyph == "🇷🇪" })
        #expect(EmojiCatalog.search("RÉUNION").contains { $0.glyph == "🇷🇪" })

        #expect(EmojiCatalog.search("  ").count == EmojiCatalog.all.count)
        #expect(EmojiCatalog.search("zzqx").isEmpty)
    }
}

/// #827: the catalogue is built once, off the main actor, and asking whether
/// it is ready never builds it.
struct EmojiCatalogLoaderTests {
    /// Every build the loader ran, and whether it ran on the main thread.
    private final class BuildProbe: Sendable {
        private let threads = Mutex<[Bool]>([])
        var builds: Int { threads.withLock { $0.count } }
        var anyOnMain: Bool { threads.withLock { $0.contains(true) } }
        func record() { threads.withLock { $0.append(Thread.isMainThread) } }
    }

    private static func loader(_ probe: BuildProbe) -> EmojiCatalogLoader {
        EmojiCatalogLoader {
            probe.record()
            return EmojiCatalog.search("grinning")
        }
    }

    @MainActor
    @Test func askingFromTheMainActorBeforeAnyBuildBuildsNothing() {
        let probe = BuildProbe()
        let loader = Self.loader(probe)

        #expect(loader.ready == nil)
        #expect(probe.builds == 0, "reading `ready` ran the build")
    }

    @MainActor
    @Test func aLoadFromTheMainActorBuildsOffIt() async {
        let probe = BuildProbe()
        let loader = Self.loader(probe)

        let built = await loader.load()

        #expect(!built.isEmpty)
        #expect(probe.builds == 1)
        #expect(!probe.anyOnMain, "the build ran on the main thread")
        #expect(loader.ready == built)
    }

    @Test func concurrentLoadsShareOneBuild() async {
        let probe = BuildProbe()
        let loader = Self.loader(probe)
        loader.prewarm()

        async let first = loader.load()
        async let second = loader.load()
        let third = await loader.load()
        let all = await [first, second, third]

        #expect(all.allSatisfy { $0 == third })
        #expect(probe.builds == 1, "\(probe.builds) builds")
        #expect(await loader.load() == third)
        #expect(probe.builds == 1, "a load after the build ran it again")
    }

    /// The shared loader builds the real catalogue.
    @Test func theSharedLoaderLoadsTheWholeCatalogue() async {
        #expect(await EmojiCatalog.load() == EmojiCatalog.all)
        #expect(EmojiCatalog.ready == EmojiCatalog.all)
    }

    @Test func aSearchOverALoadedListMatchesTheCataloguesOwn() {
        let entries = EmojiCatalog.all
        #expect(EmojiCatalog.search("grin fa", in: entries) == EmojiCatalog.search("grin fa"))
        #expect(EmojiCatalog.search("  ", in: entries).count == entries.count)
    }
}
