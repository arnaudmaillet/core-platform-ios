import CoreModels
import MediaCore
import Testing
import UIKit
@testable import ShareSheet

/// The share sheet a profile and a place share. Its row of people to send
/// to stands only when there is someone in it (user, 5 October 2026): no
/// source of people (a place), a viewer who follows nobody, or a guest —
/// no row, and no Search with it.
@MainActor
struct ShareSheetTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private struct Targets: ShareTargeting {
        let people: [ShareTarget]
        func shareTargets(limit: Int) async -> [ShareTarget] { Array(people.prefix(limit)) }
        func searchTargets(query: String, limit: Int) async -> [ShareTarget] { [] }
    }

    private static let card = ShareCard(
        displayName: "Paris", handle: "France", avatarURL: nil,
        url: URL(string: "https://wynn.cn/place/city:paris")!
    )

    private func sheet(targeting: (any ShareTargeting)?, card: ShareCard = Self.card) -> ShareSheetViewController {
        let sheet = ShareSheetViewController(
            card: card, imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            targeting: targeting, deviceCornerRadius: 0, fallbackWidth: 402
        )
        sheet.loadViewIfNeeded()
        return sheet
    }

    /// Lets the targets' load land.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func noSourceOfPeopleDrawsNoRow() {
        #expect(!sheet(targeting: nil).debugShowsTargetsRow)
    }

    /// Nobody followed, or a guest with no graph: the row goes once the
    /// empty answer lands.
    @Test func anEmptyListTakesTheRowAway() async {
        let sheet = sheet(targeting: Targets(people: []))
        await settle { !sheet.debugShowsTargetsRow }
        #expect(!sheet.debugShowsTargetsRow)
    }

    @Test func someoneToSendToKeepsTheRow() async throws {
        let ada = ShareTarget(id: ProfileID("prof-1"), displayName: "Ada", handle: "@ada", avatarURL: nil)
        let sheet = sheet(targeting: Targets(people: [ada]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sheet.debugShowsTargetsRow)
    }

    /// A picture in hand — a place's round flag — is the card's centre, no
    /// fetch.
    @Test func aPictureInHandIsTheCardsCentre() {
        let flag = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { _ in }
        let card = ShareCard(
            displayName: "Paris", handle: "France", avatarURL: nil, avatarImage: flag,
            url: URL(string: "https://wynn.cn/place/city:paris")!
        )
        let view = ShareQRCardView(imagePipeline: nil)
        view.configure(with: card)
        let images = view.allSubviews.compactMap { ($0 as? UIImageView)?.image }
        #expect(images.contains { $0 === flag })
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap(\.allSubviews) }
}
