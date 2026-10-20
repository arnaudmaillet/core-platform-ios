import Testing
import UIKit
@testable import DesignSystem

/// Avatar frames (#943): keyed by the catalogue's id, drawn on the face's
/// rim, the same for everyone in every appearance.
@MainActor
struct AvatarFrameTests {
    @Test func aFrameIsFoundByItsCatalogueID() {
        #expect(AvatarFrame(id: "frame.gold") == .gold)
        #expect(AvatarFrame(id: "frame.neon") == .neon)
        #expect(AvatarFrame(id: "frame.aurora") == .aurora)
        #expect(AvatarFrame(id: "frame.unknown") == nil, "an id this build has no art for draws nothing")
        #expect(AvatarFrame(id: "") == nil)
        #expect(AvatarFrame(id: nil) == nil)
        #expect(AvatarFrame.allCases.map(\.rawValue) == ["frame.gold", "frame.neon", "frame.aurora"])
    }

    /// The ring grows with the face and never vanishes on a small row.
    @Test func theRingFollowsTheDiameter() {
        #expect(AvatarFrame.ringWidth(forDiameter: 20) == 2)
        #expect(AvatarFrame.ringWidth(forDiameter: 36) == 3)
        #expect(AvatarFrame.ringWidth(forDiameter: 96) == 7)
    }

    /// Drawn in the avatar's bounds, its stops swept around; none draws
    /// nothing.
    @Test func theViewDrawsItsFrameInTheAvatarsBounds() {
        let view = AvatarFrameView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        #expect(view.isHidden, "no frame, nothing drawn")
        view.frameStyle = .gold
        view.layoutIfNeeded()
        #expect(!view.isHidden)
        #expect(view.drawnRingWidth == 7)
        #expect(view.drawnStops.count == Palette.frameGold.count)
        #expect(view.bounds.size == CGSize(width: 96, height: 96), "it changes no size")
        view.frameStyle = nil
        #expect(view.isHidden)
    }

    /// A frame is the same object for everyone: its colours do not follow
    /// the appearance or the accent theme.
    @Test func aFrameIgnoresTheAppearanceAndTheTheme() {
        for stops in [Palette.frameGold, Palette.frameNeon, Palette.frameAurora] {
            for stop in stops {
                let light = stop.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                let darkViolet = stop.resolvedColor(with: UITraitCollection(mutations: {
                    $0.userInterfaceStyle = .dark
                    $0.accentTheme = .violet
                }))
                #expect(light == darkViolet)
            }
        }
    }
}
