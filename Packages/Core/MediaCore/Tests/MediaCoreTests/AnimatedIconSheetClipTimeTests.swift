import Foundation
import Testing
import UIKit
@testable import MediaCore

/// A video preview sheet knows where in its clip it was cut from (#625), so a
/// frame on the marker can be named as a time in the clip, and back.
struct AnimatedIconSheetClipTimeTests {
    private func sheet(startTime: TimeInterval?) -> AnimatedIconSheet {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in }
        return AnimatedIconSheet(sheet: image, frameCount: 8, columns: 4, frameDuration: 0.1, startTime: startTime)
    }

    @Test("Frame n is the clip's start plus n steps")
    func framesAreClipTimes() {
        let art = sheet(startTime: 1.8)
        #expect(art.clipTime(ofFrame: 0) == 1.8)
        #expect(abs((art.clipTime(ofFrame: 5) ?? 0) - 2.3) < 1e-9)
    }

    @Test("A clip time maps back to the frame on screen then, inside the sheet's window only")
    func clipTimesAreFrames() {
        let art = sheet(startTime: 1.8)
        #expect(art.frame(atClipTime: 1.8) == 0)
        #expect(art.frame(atClipTime: 2.149) == 3)
        #expect(art.frame(atClipTime: 2.59) == 7)
        #expect(art.frame(atClipTime: 1.79) == nil, "before the window")
        #expect(art.frame(atClipTime: 2.6) == nil, "past the last frame")
    }

    @Test("A sheet baked before #539, or an icon, has no clip to line up on")
    func noStartNoClip() {
        let art = sheet(startTime: nil)
        #expect(art.clipTime(ofFrame: 3) == nil)
        #expect(art.frame(atClipTime: 2) == nil)
    }

    @Test("The manifest's startMS is the contract with IconBaker, and it is optional")
    func theManifestCarriesTheStart() throws {
        let json = """
        [{"id":"a","kind":"sheet","asset":"a.heic","frameCount":8,"frameMS":100,"cellPX":172,"startMS":1833},
         {"id":"b","kind":"sheet","asset":"b.heic","frameCount":8,"frameMS":100,"cellPX":172}]
        """
        let entries = try JSONDecoder().decode([AnimatedIconCatalog.Entry].self, from: Data(json.utf8))
        #expect(entries[0].startMS == 1833)
        #expect(entries[1].startMS == nil)
    }
}
