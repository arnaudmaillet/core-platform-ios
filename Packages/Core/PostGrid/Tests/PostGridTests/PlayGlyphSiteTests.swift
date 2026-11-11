import DesignSystem
import Testing
import UIKit
@testable import PostGrid

/// Every play the grid draws is the owner's (#2276): `UIImage(systemName:)`
/// finds no custom symbol, and the mark would draw nothing.
@MainActor
struct PlayGlyphSiteTests {
    /// A paused clip's 56 pt mark.
    @Test func aPausedClipsMarkIsTheOwnersPlay() throws {
        let mark = PausedClipMarkView()
        let image = try #require(mark.image)
        #expect(image.isSymbolImage)
        let owners = try #require(AppSymbol.play.image(UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold)))
        #expect(image.size == owners.size, "\(image.size), the owner's play is \(owners.size)")
    }

    /// History's square marks a clip with the owner's play.
    @Test func historysClipMarkIsTheOwnersPlay() throws {
        let cell = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 64))
        let image = try #require(cell.debugPlayImage)
        #expect(image.isSymbolImage)
        #expect(image.size == AppSymbol.play.image()?.size)
    }
}
