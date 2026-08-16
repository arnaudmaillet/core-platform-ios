import Testing
import UIKit
@testable import Maps

/// The hierarchy ring palette: a marker's border says which depth it speaks
/// for, and the mapping is pinned here so a palette tweak is a deliberate
/// edit rather than a drive-by.
struct MapMarkerRingTests {
    @Test func eachLevelWearsItsColor() {
        #expect(MapMarkerRing.color(for: .city) == .systemBlue)
        #expect(MapMarkerRing.color(for: .region) == .systemPurple)
        #expect(MapMarkerRing.color(for: .country) == MapMarkerRing.amber)
        #expect(MapMarkerRing.color(for: nil) == .systemBackground)
    }

    /// The four rings must be tellable apart in BOTH appearances — resolve
    /// each dynamic color under each style and require pairwise-distinct
    /// results, which is the actual "recognizable at a glance" contract.
    @Test func thePaletteIsDistinctInLightAndDark() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let resolved = [MapPlace.Kind.city, .region, .country].map {
                MapMarkerRing.color(for: $0).resolvedColor(with: traits)
            } + [MapMarkerRing.color(for: nil).resolvedColor(with: traits)]
            for (i, a) in resolved.enumerated() {
                for b in resolved.dropFirst(i + 1) {
                    #expect(a != b, "two ring colors collide under \(style)")
                }
            }
        }
    }

    /// Amber is bespoke (systemYellow washes out on the light map): darker
    /// than its dark-mode variant, so it holds contrast on the light map and
    /// doesn't sink into a dark one.
    @Test func amberDeepensInLightMode() {
        var lightBrightness: CGFloat = 0
        var darkBrightness: CGFloat = 0
        MapMarkerRing.amber
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getHue(nil, saturation: nil, brightness: &lightBrightness, alpha: nil)
        MapMarkerRing.amber
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getHue(nil, saturation: nil, brightness: &darkBrightness, alpha: nil)
        #expect(lightBrightness < darkBrightness)
    }

    /// Semantic rings are heavier than neutral ones — depth reads by weight
    /// even where a color is ambiguous against the map beneath.
    @Test func semanticRingsAreHeavier() {
        #expect(MapMarkerRing.width(for: nil) == PinCardView.ringWidth)
        for kind in [MapPlace.Kind.city, .region, .country] {
            #expect(MapMarkerRing.width(for: kind) == MapMarkerRing.hierarchyWidth)
            #expect(MapMarkerRing.width(for: kind) > MapMarkerRing.width(for: nil))
        }
    }
}
