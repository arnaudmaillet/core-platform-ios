import Testing
import UIKit
@testable import DesignSystem

/// A tab's two faces (#2073): the outline as its image, the fill as its
/// selected image, drawn as the glyph tabs' are — never a plain symbol image,
/// which the bar draws filled in both states.
@MainActor
struct TabFacesTests {
    /// The guest's Settings gear and the member's placeholder: an outline and
    /// a fill, templates, in one box at the glyphs' size.
    @Test(arguments: [("gearshape", "gearshape.fill"), ("person.crop.circle", "person.crop.circle.fill")])
    func aSymbolPairIsTwoTemplatesInOneBox(_ names: (String, String)) throws {
        let faces = try #require(TabFaces.system(outline: names.0, fill: names.1))
        #expect(faces.outline.renderingMode == .alwaysTemplate)
        #expect(faces.fill.renderingMode == .alwaysTemplate)
        #expect(faces.outline.size == faces.fill.size, "selecting the tab would resize it")
        #expect(!faces.outline.isSymbolImage && !faces.fill.isSymbolImage, "a symbol image is the bar's to draw")
        #expect(faces.outline.pngData() != faces.fill.pngData(), "the two faces are the same drawing")
    }

    /// The glyphs' size: the gear stands as tall as its neighbours.
    @Test func theGearStandsTheGlyphsSize() throws {
        let gear = try #require(TabFaces.system(outline: "gearshape", fill: "gearshape.fill"))
        let explore = try #require(TabGlyph.explore.symbol(selected: false, badged: false).image(TabGlyph.symbolConfiguration))
        #expect(abs(gear.outline.size.height - explore.size.height) <= 3,
                "gear \(gear.outline.size) beside the paper plane \(explore.size)")
    }

    /// The tab wears both: the outline as its image, the fill as its selected
    /// image; and a nil fill clears the selected face (an avatar after a gear).
    @Test func aTabWearsBothFacesAndLosesTheFill() throws {
        let faces = try #require(TabFaces.system(outline: "gearshape", fill: "gearshape.fill"))
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
        #expect(TabFaces.system(outline: "no.such.symbol", fill: "gearshape.fill") == nil)
    }
}
