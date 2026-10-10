import MediaPlayback
import StickerKit
import Testing
import UIKit
@testable import Upload

/// The sticker sheet: what each shelf offers, what a search keeps, and what a
/// pick says.
@MainActor
struct MediaStickerPickerTests {
    private func picker(_ loader: EmojiCatalogLoader = EmojiCatalog.loader) -> MediaStickerPickerViewController {
        let picker = MediaStickerPickerViewController(emojiLoader: loader)
        picker.loadViewIfNeeded()
        return picker
    }

    /// A sheet whose catalogue is already built, as it is by the time anyone
    /// picks the Emoji shelf.
    private func pickerWithEmoji() async -> MediaStickerPickerViewController {
        _ = await EmojiCatalog.load()
        return picker()
    }

    @Test func theStickersShelfOffersTheChatsStickers() {
        #expect(picker().debugItems == StickerCatalog.stickers.map(\.id))
    }

    @Test func theEmojiShelfIsGroupedAndEveryGroupIsFilled() async {
        let picker = await pickerWithEmoji()
        picker.debugShow(.emoji)
        #expect(picker.debugSections.count > 1, "one group: \(picker.debugSections)")
        #expect(picker.debugItems.count == Set(EmojiCatalog.all.map(\.glyph)).count,
                "\(picker.debugItems.count) emoji shown of \(EmojiCatalog.all.count)")
    }

    /// #827: the sheet never builds the catalogue on the main actor. Opened
    /// before it is ready, the Emoji shelf stays empty, then fills when the
    /// off-main build lands.
    @Test func anEmojiShelfOpenedBeforeTheCatalogueFillsWhenItLands() async throws {
        _ = await EmojiCatalog.load()
        let sample = Array(EmojiCatalog.all.prefix(5))
        let picker = picker(EmojiCatalogLoader { sample })

        picker.debugShow(.emoji)
        #expect(picker.debugItems.isEmpty, "the shelf was filled before the load could land")
        #expect(picker.debugGridAccessibilityLabel == "Loading emoji")

        // On STATE, a look budget rather than a deadline.
        for _ in 0..<500 where picker.debugItems.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(picker.debugItems == sample.map(\.glyph))
        #expect(picker.debugGridAccessibilityLabel == nil, "the grid hides its cells from VoiceOver")
    }

    @Test func aSearchKeepsOnlyWhatMatches() async {
        let picker = await pickerWithEmoji()
        picker.debugShow(.emoji)
        picker.debugSearch("grinning")
        #expect(picker.debugItems.contains("😀"), "got \(picker.debugItems.prefix(10))")
        #expect(!picker.debugItems.contains("🍕"), "a pizza matched 'grinning'")
        #expect(picker.debugSections == ["results"])
    }

    @Test func aPickSaysWhatWasPicked() {
        let picker = picker()
        var picked: [FrameOverlay.Content] = []
        picker.onPick = { picked.append($0) }

        picker.debugPick("Idea")
        picker.debugShow(.emoji)
        picker.debugPick("😀")

        #expect(picked == [.sticker(id: "Idea"), .emoji("😀")])
    }
}
