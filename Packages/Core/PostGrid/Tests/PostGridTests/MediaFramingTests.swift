import AVFoundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import PostGrid

/// The vocabulary of a fitted page (`MediaFraming`), the backdrop it draws
/// (`MediaBackdrop`), and the carousel's per-page framing.
///
/// ⚠️ The carousel half is pinned in BOTH states, because the contract is
/// asymmetric: a `.card` carousel (the grid's) must go on filling whatever it
/// is shown, and only a carousel handed a rule may fit.
@MainActor
struct MediaFramingTests {
    // MARK: - Vocabulary

    @Test func eachFramingDrawsWithTheMatchingModes() {
        #expect(MediaFraming.fill.contentMode == .scaleAspectFill)
        #expect(MediaFraming.fill.videoGravity == .resizeAspectFill)
        #expect(MediaFraming.fitBlurred.contentMode == .scaleAspectFit)
        #expect(MediaFraming.fitBlurred.videoGravity == .resizeAspect)
        #expect(MediaFraming.fitBlack.contentMode == .scaleAspectFit)
        #expect(MediaFraming.fitBlack.videoGravity == .resizeAspect)
        #expect(!MediaFraming.fill.fits)
        #expect(MediaFraming.fitBlurred.fits && MediaFraming.fitBlack.fits)
    }

    // MARK: - Backdrop

    /// Reduced to a few dozen pixels: the upscale on screen IS the blur, and a
    /// full-resolution backdrop would be a full-resolution cost for nothing.
    @Test func theBackdropIsATinyImageOfThePicturesShape() throws {
        let backdrop = try #require(MediaBackdrop.blurred(Self.solid(.red, CGSize(width: 1440, height: 1920))))
        let pixels = try #require(backdrop.cgImage)
        #expect(max(pixels.width, pixels.height) == MediaBackdrop.reducedLongSide)
        #expect(abs(Double(pixels.width) / Double(pixels.height) - 0.75) < 0.05)
    }

    /// It is the picture's colour, darkened — not black, not the picture
    /// untouched. (A backdrop that rendered black read as a `.fitBlack` page
    /// on screen, which is exactly how a broken blur hides.)
    @Test func theBackdropKeepsThePicturesColourAndDarkensIt() throws {
        let backdrop = try #require(MediaBackdrop.blurred(Self.solid(.red, CGSize(width: 300, height: 400))))
        let (r, g, b) = try #require(Self.averageColour(backdrop))
        #expect(r > 0.55 && r < 0.9, "red channel \(r)")
        #expect(g < 0.1 && b < 0.1, "green \(g) blue \(b)")
    }

    /// Edges are EXTENDED, not faded: a uniform picture blurs to the same
    /// colour at its corner as at its centre, so the band's edge never darkens
    /// toward a vignette nobody asked for.
    @Test func theBlurDoesNotDarkenTheEdges() throws {
        let backdrop = try #require(MediaBackdrop.blurred(Self.solid(.green, CGSize(width: 400, height: 400))))
        let corner = try #require(Self.pixel(backdrop, x: 0, y: 0))
        let centre = try #require(Self.pixel(backdrop, x: 20, y: 20))
        #expect(abs(corner.g - centre.g) < 0.03)
    }

    /// One rendition per picture: the page and the hero that flies it must
    /// draw the SAME image, and a second render would be a second chance to
    /// differ.
    @Test func theBackdropIsCachedPerPicture() {
        let picture = Self.solid(.blue, CGSize(width: 200, height: 200))
        #expect(MediaBackdrop.blurred(picture) === MediaBackdrop.blurred(picture))
    }

    // MARK: - The carousel's pages

    @Test func aCardCarouselFillsEveryPageWhateverItsShape() {
        let carousel = MediaCarouselView(style: .card, frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        carousel.configure(with: Self.pages(2), imagePipeline: Self.pipeline)
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 1600, height: 900)), onPage: 0)
        #expect(carousel.currentPageFraming == .fill)
        #expect(carousel.currentPageBackdrop == nil)
        #expect(Self.coverModes(in: carousel).allSatisfy { $0 == .scaleAspectFill })
    }

    @Test func aPageCarouselFramesEachPageByItsOwnPicture() {
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        carousel.pageFraming = Self.rule
        carousel.configure(with: Self.pages(3), imagePipeline: Self.pipeline)
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 1080, height: 1350)), onPage: 0)
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 1600, height: 900)), onPage: 1)
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 1080, height: 1920)), onPage: 2)
        #expect(carousel.currentPageFraming == .fitBlurred)
        #expect(carousel.currentPageBackdrop != nil)
        #expect(carousel.currentPageAspect == CGSize(width: 1080, height: 1350))
        carousel.layoutIfNeeded()
        // A fitted page's cover sits in the picture's own rect and fills it;
        // a filling page's cover is the whole page.
        let covers = carousel.pageViews.map(\.cover)
        let page = carousel.pageViews[0].bounds
        #expect(Self.close(covers[0].frame, MediaFraming.fittedRect(aspect: CGSize(width: 1080, height: 1350), in: page)))
        #expect(Self.close(covers[1].frame, MediaFraming.fittedRect(aspect: CGSize(width: 1600, height: 900), in: page)))
        #expect(covers[2].frame == page)
        #expect(Self.coverModes(in: carousel) == [.scaleAspectFill, .scaleAspectFill, .scaleAspectFill])
    }

    /// ⚠️ The cover FILLS the clip's rect: a clip page's cover is its poster,
    /// a thumbnail that may be cropped square, and fitted on its own shape it
    /// would sit inset in the clip's rect until the first frame.
    @Test func aFittedClipPagesPosterFillsTheClipsRect() {
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        carousel.pageFraming = Self.rule
        carousel.configure(
            with: [GalleryPost.MediaPage(thumbnailURL: nil, videoURL: URL(string: "mock://video/a"))]
                + Self.pages(1),
            imagePipeline: Self.pipeline
        )
        carousel.setDeclaredAspects([CGSize(width: 4, height: 5), nil])
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 168, height: 168)), onPage: 0)
        carousel.layoutIfNeeded()
        let page = carousel.pageViews[0].bounds
        #expect(carousel.currentPageFraming == .fitBlurred)
        #expect(Self.close(carousel.pageViews[0].cover.frame,
                           MediaFraming.fittedRect(aspect: CGSize(width: 4, height: 5), in: page)))
        let surface = VideoRenderView()
        carousel.host(surface, onPage: 0)
        #expect(surface.posterAspect == CGSize(width: 4, height: 5))
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    /// A page with no picture and nothing declared fills: the head page's
    /// `MediaPage.aspectRatio` is a historical 1 and is NOT read as a shape.
    @Test func aPageWithNoPictureAndNoDeclarationFills() {
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        carousel.pageFraming = Self.rule
        carousel.configure(with: Self.pages(2), imagePipeline: Self.pipeline)
        #expect(carousel.currentPageFraming == .fill)
        #expect(carousel.currentPageAspect == nil)
        // …and what the host declares frames it before anything arrives.
        carousel.setDeclaredAspects([CGSize(width: 4, height: 5), nil])
        #expect(carousel.currentPageFraming == .fitBlurred)
        #expect(carousel.currentPageAspect == CGSize(width: 4, height: 5))
    }

    /// ⚠️ A clip page's cover is its POSTER, a thumbnail that may be cropped
    /// square — never its shape. The declared shape wins over it, and fills a
    /// portrait clip as the clip deserves.
    @Test func aClipPageIgnoresItsPostersShape() {
        let carousel = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        carousel.pageFraming = Self.rule
        carousel.configure(
            with: [GalleryPost.MediaPage(thumbnailURL: nil, videoURL: URL(string: "mock://video/a"))]
                + Self.pages(1),
            imagePipeline: Self.pipeline
        )
        carousel.setDeclaredAspects([CGSize(width: 9, height: 16), nil])
        carousel.debugSetCover(Self.solid(.red, CGSize(width: 168, height: 168)), onPage: 0)
        #expect(carousel.currentPageFraming == .fill)
        #expect(carousel.currentPageAspect == CGSize(width: 9, height: 16))
    }

    /// A playback surface hosted on a fitted page draws fitted; the same
    /// surface hosted by a grid's card carousel is put back to fill.
    @Test func aHostedSurfaceTakesItsPagesGravity() {
        let page = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        page.pageFraming = Self.rule
        page.configure(with: Self.pages(1) + Self.pages(1), imagePipeline: Self.pipeline)
        page.debugSetCover(Self.solid(.red, CGSize(width: 1600, height: 900)), onPage: 0)
        let surface = VideoRenderView()
        page.host(surface, onPage: 0)
        #expect(surface.videoGravity == .resizeAspect)
        // Its black ground would cover the page's bands; it is switched off…
        #expect(surface.paintsOpaqueGround == false)
        // …and back on as the surface leaves, so the next host decides.
        page.evictSurface(onPage: 0)
        #expect(surface.paintsOpaqueGround)

        let card = MediaCarouselView(style: .card, frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        card.configure(with: Self.pages(2), imagePipeline: Self.pipeline)
        card.host(surface, onPage: 0)
        #expect(surface.videoGravity == .resizeAspectFill)
        #expect(surface.paintsOpaqueGround)
    }

    /// A filling page never touches a surface's ground — a flight card's
    /// surface arrives with it OFF, and must keep it that way.
    @Test func aFillingPageLeavesASurfacesGroundAlone() {
        let page = MediaCarouselView(style: .page, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        page.pageFraming = Self.rule
        page.configure(with: Self.pages(2), imagePipeline: Self.pipeline)
        page.debugSetCover(Self.solid(.red, CGSize(width: 1080, height: 1920)), onPage: 0)
        let surface = VideoRenderView()
        surface.paintsOpaqueGround = false
        page.host(surface, onPage: 0)
        #expect(surface.videoGravity == .resizeAspectFill)
        #expect(surface.paintsOpaqueGround == false)
    }

    // MARK: - Helpers

    /// The feed's rule, restated so this module's suite does not depend on the
    /// feed: fill ≤ 2:3 < blurred ≤ 1:1 < black.
    private static let rule: (CGSize) -> MediaFraming = { size in
        let r = size.width / size.height
        return r <= 2.0 / 3.0 ? .fill : (r <= 1 ? .fitBlurred : .fitBlack)
    }

    private static let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())

    private static func pages(_ count: Int) -> [GalleryPost.MediaPage] {
        (0..<count).map { _ in GalleryPost.MediaPage(thumbnailURL: nil) }
    }

    private static func solid(_ colour: UIColor, _ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func pixel(_ image: UIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    private static func averageColour(_ image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
    }

    private static func coverModes(in carousel: MediaCarouselView) -> [UIView.ContentMode] {
        carousel.pageViews.map(\.cover.contentMode)
    }
}
