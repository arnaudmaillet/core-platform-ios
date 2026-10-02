import MediaCore
import Testing
import UIKit
@testable import EmoteKit

/// The paper around a map icon goes; white inside its outline stays.
@Suite(.sharesMainThread)
struct EmoteIconMatteTests {
    /// Two 40 px frames on white paper: a black ring with a white centre.
    private func paperSheet() -> AnimatedIconSheet {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            for x in [0, 40] {
                UIColor.black.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: x + 8, y: 8, width: 24, height: 24))
                ring.lineWidth = 4
                ring.stroke()
            }
        }
        return AnimatedIconSheet(sheet: image, frameCount: 2, columns: 2, frameDuration: 0.1)
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        TestBitmap.rgba(image)[(y * image.width + x) * 4 + 3]
    }

    @Test func thePaperGoesAndTheInsideStays() throws {
        let matted = EmoteIconMatte.matted(.sheet(paperSheet()))
        guard case .sheet(let sheet) = matted else {
            Issue.record("expected a sheet")
            return
        }
        let image = try #require(sheet.sheet.cgImage)
        #expect(sheet.frameCount == 2)
        for frame in [0, 40] {
            #expect(alpha(image, x: frame + 1, y: 1) == 0, "paper in the corner of frame at \(frame)")
            #expect(alpha(image, x: frame + 20, y: 20) == 255, "white inside the ring of frame at \(frame)")
            #expect(alpha(image, x: frame + 20, y: 8) > 200, "the ring itself")
        }
    }
}
