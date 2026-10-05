import CoreImage
import Testing
import UIKit
@testable import Feed

/// Decodes a QR out of an image the way a camera would — see Profile's
/// `ProfileQRCodeTests` for why this stays off the main actor.
private func decodeQR(in image: UIImage) -> String? {
    guard let cgImage = image.cgImage else { return nil }
    let detector = CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
    return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
}

/// The place's QR code, opened from its page's tray: what it draws scans
/// back to the place's link.
struct PlaceQRCodeTests {
    @MainActor
    private func codeImage(for url: URL) throws -> UIImage {
        let sheet = PlaceQRCodeViewController(name: "Paris", url: url)
        sheet.loadViewIfNeeded()
        return try #require(sheet.codeView.image)
    }

    @Test func theSheetsCodeDecodesBackToThePlaceLink() async throws {
        let url = try #require(URL(string: "https://wynn.cn/place/city:paris"))
        let image = try await codeImage(for: url)
        #expect(decodeQR(in: image) == url.absoluteString)
        #expect(image.size == CGSize(width: PlaceQRCodeViewController.codeSide, height: PlaceQRCodeViewController.codeSide))
    }
}
