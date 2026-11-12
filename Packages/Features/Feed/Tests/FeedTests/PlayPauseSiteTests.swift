import DesignSystem
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// Every play and pause the feed draws is the owner's (#2276):
/// `UIImage(systemName:)` finds no custom symbol, and the control would
/// draw nothing.
@MainActor
struct PlayPauseSiteTests {
    /// The voice composer: the take button's pause while it records locked,
    /// the chip's play and pause once paused.
    @Test func theVoiceComposerShowsTheOwnersGlyphs() {
        let strip = VoiceRecordingStrip(frame: CGRect(x: 0, y: 0, width: 280, height: 44))
        strip.apply(.locked)
        strip.layoutIfNeeded()
        #expect(strip.debugTakeFace == AppSymbol.pause.rawValue)
        #expect(strip.debugTakeImage?.isSymbolImage == true)
        strip.apply(.paused(resumable: true, playing: false))
        #expect(strip.debugChipFace == AppSymbol.play.rawValue)
        #expect(strip.debugChipImage?.isSymbolImage == true)
        strip.apply(.paused(resumable: true, playing: true))
        #expect(strip.debugChipFace == AppSymbol.pause.rawValue)
        #expect(strip.debugChipImage?.isSymbolImage == true)
    }

    /// The browse strip marks a clip's tile with the owner's play.
    @Test func theBrowseStripMarksClipsWithTheOwnersPlay() {
        let strip = SnapBrowseStripView(frame: CGRect(x: 0, y: 0, width: 402, height: SnapBrowseStripView.height))
        strip.configure(thumbnails: [nil, nil, nil], videoPages: [1], pipeline: nil)
        #expect(!strip.debugVideoMarkImages.isEmpty)
        #expect(strip.debugVideoMarkImages.allSatisfy { $0?.isSymbolImage == true })
    }

    /// The comments preview's paused mark.
    @Test func theCommentsPreviewsPausedMarkIsTheOwnersPlay() {
        let preview = SnapCommentsPreview(content: UIView())
        #expect(preview.debugPausedMarkImage?.isSymbolImage == true)
        #expect(preview.debugPausedMarkImage?.size == AppSymbol.play.image()?.size)
    }

    /// A video in a conversation: the owner's play knocked out of
    /// play.circle.fill's disc, in the disc's white.
    @Test func aConversationsVideoWearsTheOwnersPlayOnItsDisc() throws {
        let view = ThreadMediaView()
        let image = try #require(view.debugPlayBadgeImage)
        #expect(image.renderingMode == .alwaysOriginal)
        #expect(image.size == AppSymbol.playCircle.image(UIImage.SymbolConfiguration(pointSize: 34, weight: .regular))?.size)
    }
}
