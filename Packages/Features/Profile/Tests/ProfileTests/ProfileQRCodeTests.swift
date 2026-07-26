import CoreImage
import CoreModels
import Testing
import UIKit
@testable import Profile

/// Decodes a QR out of an image the way a camera would.
///
/// Free function, and the generation suite below is deliberately NOT
/// `@MainActor`: QR rasterization plus a high-accuracy detector pass is
/// hundreds of milliseconds of work, and swift-testing runs suites in
/// parallel. Holding the main actor that long starves the wall-clock `settle()`
/// deadlines other suites poll on, which surfaces as an unrelated test failing
/// (`ProfileGalleryViewModelTests` did exactly that once — the hazard
/// `ci-and-branch-protection` documents). Only the tests that genuinely build
/// views take the main actor, and they render at low scale.
private func decodeQR(in image: UIImage) -> String? {
    guard let cgImage = image.cgImage else { return nil }
    let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
    return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
}

private func sampleCard(handle: String = "ada") -> ProfileViewModel.ShareCard {
    ProfileViewModel.ShareCard(
        displayName: "Ada Lovelace",
        handle: "@" + handle,
        avatarURL: nil,
        url: ProfileShareLink.url(handle: handle)
    )
}

/// These tests SCAN what the app generates rather than asserting on pixel
/// counts — "a scanner can read this" is the actual requirement, and no size
/// assertion could stand in for it.
struct ProfileQRCodeTests {
    @Test func generatedCodeDecodesBackToTheProfileLink() throws {
        let url = ProfileShareLink.url(handle: "ada")

        let image = try #require(ProfileQRCode.makeImage(for: url, side: 240, scale: 2))

        #expect(decodeQR(in: image) == url.absoluteString)
        #expect(image.size == CGSize(width: 240, height: 240))
    }

    /// Non-ASCII handles are encoded as UTF-8 bytes, not dropped — the reason
    /// the generator takes `Data` rather than handing the filter a string.
    @Test func encodesNonASCIIHandles() throws {
        let url = ProfileShareLink.url(handle: "ünïcode")

        let image = try #require(ProfileQRCode.makeImage(for: url, side: 240, scale: 2))

        #expect(decodeQR(in: image) == url.absoluteString)
    }

    @Test func refusesDegenerateSizes() {
        let url = ProfileShareLink.url(handle: "ada")

        #expect(ProfileQRCode.makeImage(for: url, side: 0, scale: 3) == nil)
        #expect(ProfileQRCode.makeImage(for: url, side: 240, scale: 0) == nil)
    }
}

@MainActor
struct ProfileShareCardTests {
    /// The reason error correction is pinned to level H. If someone lowers it,
    /// or widens `ProfileQRCardView.avatarFraction`, this is what fails.
    @Test func codeStillDecodesWithTheAvatarPunchedThroughIt() throws {
        let card = sampleCard()
        let view = ProfileQRCardView(imagePipeline: nil)
        view.configure(with: card)

        let rendered = ProfileShareCard.render(view, width: 320, scale: 2)

        #expect(decodeQR(in: rendered) == card.url.absoluteString)
    }

    @Test func rendersACardImageSizedToItsContent() {
        let view = ProfileQRCardView(imagePipeline: nil)
        view.configure(with: sampleCard())

        let rendered = ProfileShareCard.render(view, width: 320, scale: 1)

        #expect(rendered.size.width == 320)
        // The card is a square code plus an identity block, so it is always
        // taller than it is wide — a collapsed height would mean the renderer's
        // double layout pass stopped working and the code never got generated.
        #expect(rendered.size.height > 320)
    }

    /// The card paints a LITERAL colour rather than `.secondarySystemBackground`,
    /// which resolves translucent inside an iOS 26 sheet. On screen that merely
    /// tinted the card with whatever was behind it; rendered into the opaque
    /// context used here, a translucent background composites toward black.
    @Test func renderedCardIsOpaqueAndLight() throws {
        let view = ProfileQRCardView(imagePipeline: nil)
        view.configure(with: sampleCard())

        let rendered = ProfileShareCard.render(view, width: 320, scale: 1)
        let cgImage = try #require(rendered.cgImage)

        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Sample the card's padding: inside the corner radius, outside the code.
        context.draw(cgImage, in: CGRect(x: -12, y: -12, width: 320, height: rendered.size.height))

        #expect(pixel[3] == 255)
        #expect(pixel[0] > 200)
        #expect(pixel[1] > 200)
        #expect(pixel[2] > 200)
    }

    @Test func shareCardCarriesTheIdentityAndTheCanonicalLink() async {
        let viewModel = ProfileViewModel(repository: QRStubProvider())
        #expect(viewModel.shareCard == nil) // nothing to share before the load

        viewModel.viewDidLoad()
        // Polled, not slept — see the note on `ProfileViewModelTests.settle`.
        for _ in 0..<60 where viewModel.shareCard == nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let card = viewModel.shareCard
        #expect(card?.displayName == "Ada Lovelace")
        #expect(card?.handle == "@ada")
        #expect(card?.url == ProfileShareLink.url(handle: "ada"))
    }
}

private actor QRStubProvider: ProfileProviding {
    func currentUserProfile() async throws -> UserProfile {
        UserProfile(
            id: ProfileID("prof-1"),
            handle: "ada",
            displayName: "Ada Lovelace",
            bio: "",
            avatarURL: nil,
            websiteURL: nil,
            isVerified: false,
            followerCount: .unavailable,
            followingCount: .unavailable,
            reactionCount: .unavailable,
            viewCount: .unavailable
        )
    }
    func profile(id: ProfileID) async throws -> UserProfile { try await currentUserProfile() }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        .other(isFollowing: false, isBlocked: false)
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        try await currentUserProfile()
    }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { try await currentUserProfile() }
}
