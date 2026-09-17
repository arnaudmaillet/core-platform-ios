import MediaPlayback
import StickerKit
import Testing
import UIKit
@testable import Upload

/// The sticker sheet: what each shelf offers, what a search keeps, and what a
/// pick says.
@MainActor
struct MediaStickerPickerTests {
    private func picker() -> MediaStickerPickerViewController {
        let picker = MediaStickerPickerViewController()
        picker.loadViewIfNeeded()
        return picker
    }

    @Test func theStickersShelfOffersTheChatsStickers() {
        #expect(picker().debugItems == StickerCatalog.stickers.map(\.id))
    }

    @Test func theEmojiShelfIsGroupedAndEveryGroupIsFilled() {
        let picker = picker()
        picker.debugShow(.emoji)
        #expect(picker.debugSections.count > 1, "one group: \(picker.debugSections)")
        #expect(picker.debugItems.count == Set(EmojiCatalog.all.map(\.glyph)).count,
                "\(picker.debugItems.count) emoji shown of \(EmojiCatalog.all.count)")
    }

    @Test func aSearchKeepsOnlyWhatMatches() {
        let picker = picker()
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
