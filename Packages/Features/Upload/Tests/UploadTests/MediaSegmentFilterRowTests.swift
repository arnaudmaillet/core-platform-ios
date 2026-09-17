import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **THE PIECE'S FILTER ROW IS THE TRANSITIONS ROW WITH PICTURES** — the same
/// cards, rests, fade and glass (`MediaTransitionRowTests` asks those of the
/// shared row); what is its own is asked here.
@MainActor
struct MediaSegmentFilterRowTests {
    private func row(width: CGFloat = 390) -> MediaSegmentFilterRowView {
        let row = MediaSegmentFilterRowView()
        row.frame = CGRect(x: 0, y: 0, width: width, height: MediaSegmentFilterRowView.height)
        row.layoutIfNeeded()
        return row
    }

    private func swatch(_ colour: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @Test func noneComesFirstThenEveryLook() {
        #expect(row().debugLabels == [
            "None", "Chrome", "Fade", "Instant", "Mono", "Noir", "Process", "Tonal", "Transfer"
        ])
    }

    @Test func theChosenCardIsRingedAndAPickIsHeard() {
        let row = row()
        var picked: [MediaFilter?] = []
        row.onPick = { picked.append($0) }
        #expect(row.debugChosen == ["None"])

        row.debugTap(.noir)

        #expect(picked == [.noir])
        #expect(row.debugChosen == ["Noir"])
    }

    /// Each card shows the picture it was given — and only its own.
    @Test func aPictureLandsOnItsOwnCard() {
        let row = row()
        let red = swatch(.red)
        let blue = swatch(.blue)

        row.setPicture(red, for: .mono)
        row.setPicture(blue, for: nil)

        let pictures = row.debugPictures
        #expect(pictures[0] === blue, "None does not show its picture")
        #expect(pictures[4] === red, "Mono does not show its picture")
        #expect(pictures.enumerated().filter { $0.element != nil }.map(\.offset) == [0, 4])
    }

    /// The word sits inside its card, along the bottom, on a card as wide as a
    /// transition card.
    @Test func theWordSitsAlongTheBottomOfItsCard() {
        let row = row()
        for (card, caption) in zip(row.debugCardFrames, row.debugCaptionFrames) {
            #expect(abs(card.width - 56) < 0.01, "a card is \(card.size)")
            #expect(card.contains(caption), "the word spills: \(card) \(caption)")
            #expect(caption.midY > card.midY, "the word is not along the bottom: \(card) \(caption)")
        }
    }

    @Test func theCloseButtonSaysWhatItCloses() {
        #expect(row().debugCloseButton.accessibilityLabel == "Close filters")
    }
}
