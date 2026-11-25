import Testing
import UIKit
@testable import DesignSystem

/// A tab's two faces (#2073): the outline as its image, the fill as its
/// selected image, drawn as the glyph tabs' are — never a plain symbol image,
/// which the bar draws filled in both states.
@MainActor
struct TabFacesTests {
    /// The member's placeholder and the guest's Settings gear (the owner's,
    /// #2433): an outline and a fill, templates, in one box at the glyphs' size.
    enum Pair: CaseIterable { case placeholder, gear }

    @Test(arguments: Pair.allCases)
    func aSymbolPairIsTwoTemplatesInOneBox(_ pair: Pair) throws {
        let faces = try #require(pair == .gear
            ? TabFaces.app(outline: .settings, fill: .settingsFill)
            : TabFaces.system(outline: "person.crop.circle", fill: "person.crop.circle.fill"))
        #expect(faces.outline.renderingMode == .alwaysTemplate)
        #expect(faces.fill.renderingMode == .alwaysTemplate)
        #expect(faces.outline.size == faces.fill.size, "selecting the tab would resize it")
        #expect(!faces.outline.isSymbolImage && !faces.fill.isSymbolImage, "a symbol image is the bar's to draw")
        #expect(faces.outline.pngData() != faces.fill.pngData(), "the two faces are the same drawing")
    }

    /// The glyphs' size: the gear stands as tall as its neighbours.
    @Test func theGearStandsTheGlyphsSize() throws {
        let gear = try #require(TabFaces.app(outline: .settings, fill: .settingsFill))
        let explore = try #require(TabGlyph.explore.symbol(selected: false, badged: false).image(TabGlyph.symbolConfiguration))
        #expect(abs(gear.outline.size.height - explore.size.height) <= 3,
                "gear \(gear.outline.size) beside the map \(explore.size)")
    }

    /// The tab wears both: the outline as its image, the fill as its selected
    /// image; and a nil fill clears the selected face (an avatar after a gear).
    @Test func aTabWearsBothFacesAndLosesTheFill() throws {
        let faces = try #require(TabFaces.app(outline: .settings, fill: .settingsFill))
        let tab = UITab(title: "Settings", image: nil, identifier: "test") { _ in UIViewController() }
        tab.setFaces(outline: faces.outline, fill: faces.fill)
        #expect(tab.image === faces.outline)
        guard tab.responds(to: NSSelectorFromString("selectedImage")) else { return }
        #expect(tab.selectedFace === faces.fill)

        let avatar = UIImage()
        tab.setFaces(outline: avatar, fill: nil)
        #expect(tab.image === avatar)
        #expect(tab.selectedFace == nil, "the gear's fill stayed as the selected face")
    }

    /// An unknown name: no faces rather than a blank tab.
    @Test func anUnknownSymbolGivesNoFaces() {
        #expect(TabFaces.system(outline: "no.such.symbol", fill: "person.crop.circle.fill") == nil)
    }
}
