import Testing
import UIKit
@testable import Chat

/// The composer's favourites strip after its stickers moved to StickerKit.
///
/// ⚠️ **THE FILES LIVE IN ANOTHER PACKAGE'S BUNDLE NOW.** A strip that asked
/// Chat's own bundle would find nothing and quietly keep its emoji stand-ins —
/// a strip that still "works" — so this reads what the cells DRAW: pictures,
/// not letters.
@MainActor
struct FavoriteStickerStripTests {
    @Test func theStripDrawsTheStickersAsPictures() async throws {
        let strip = FavoriteStickerStripView()
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 36))
        host.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            strip.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        strip.setPreferredWidth(320)
        host.layoutIfNeeded()

        #expect(FavoriteStickerCatalog.favorites.count == 12)
        let cells = Self.subviews(of: strip).compactMap { $0 as? UICollectionViewCell }
        #expect(cells.contains { $0.accessibilityLabel == "Laughing" })

        try #require(!cells.isEmpty)
        var pictures = Self.pictures(in: strip)
        let deadline = ContinuousClock.now + .seconds(30)
        while pictures.count < cells.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            pictures = Self.pictures(in: strip)
        }
        #expect(pictures.count == cells.count, "\(pictures.count) pictures for \(cells.count) stickers")
        for picture in pictures {
            #expect(Self.inkedPixels(in: try #require(picture.cgImage)) > 0)
        }
    }

    /// The images the strip shows. A cell shows its emoji, and keeps its image
    /// view hidden, until the sticker's first frame is drawn.
    private static func pictures(in strip: UIView) -> [UIImage] {
        subviews(of: strip).compactMap { view in
            guard let imageView = view as? UIImageView, !imageView.isHidden else { return nil }
            return imageView.image
        }
    }

    private static func subviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    private static func inkedPixels(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: bytes.count, by: 4).count { bytes[$0] > 0 }
    }
}
