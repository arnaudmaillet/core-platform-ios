import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The profile's counter row (#687): the identity column's whole width in
/// four equal cells, Followers, Following and Likes centred in the first
/// three, the fourth empty — and a hidden counter leaves its cell empty.
@MainActor
struct ProfileCountersRowTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func header(
        width: CGFloat = 393, likes: CountEstimate = .exact(1_000),
        textSize: UIContentSizeCategory? = nil
    ) -> ProfileHeaderView {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        if let textSize { header.traitOverrides.preferredContentSizeCategory = textSize }
        header.chromeTopInset = 103
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"), handle: "kenji.dev", displayName: "Kenji Tanaka",
            bio: "Building small tools.", avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(4_200), followingCount: .exact(318), reactionCount: likes
        )))
        header.configureAction(.following)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return header
    }

    @Test(arguments: [CGFloat(375), 393, 440])
    func fourEqualCellsSpanTheIdentityColumnAndTheCountersAreCentred(width: CGFloat) throws {
        let header = header(width: width)
        let cells = header.debugStatCellFrames
        #expect(cells.count == 4)
        let row = header.debugStatsFrame
        let widths = cells.map(\.width)
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) < 0.5, "unequal cells: \(widths)")
        #expect(abs((cells.first?.minX ?? 0) - row.minX) < 0.5 && abs((cells.last?.maxX ?? 0) - row.maxX) < 0.5)
        // The row spans the column beside the avatar, from the name's edge.
        #expect(abs(row.minX - header.debugNameHalfFrame.minX) < 0.5)
        #expect(abs(row.maxX - header.debugNameHalfFrame.maxX) < 0.5)
        for (index, frame) in header.debugStatFrames.enumerated() {
            let stat = try #require(frame, "counter \(index) is hidden")
            #expect(abs(stat.midX - cells[index].midX) < 0.5, "counter \(index) is not centred in its cell")
            #expect(stat.minX >= cells[index].minX - 0.5 && stat.maxX <= cells[index].maxX + 0.5,
                    "counter \(index) spills out of its cell")
        }
    }

    /// A hidden like count leaves the third cell empty; the others stay.
    @Test func aHiddenCounterLeavesItsCellEmpty() {
        let shown = header()
        let hidden = header(likes: .unavailable)
        #expect(hidden.debugStatFrames[2] == nil)
        // Across the row nothing moves (an empty cell's height is moot).
        #expect(hidden.debugStatCellFrames.map { [$0.minX, $0.width] } == shown.debugStatCellFrames.map { [$0.minX, $0.width] },
                "the cells moved")
        #expect(hidden.debugStatFrames[0] == shown.debugStatFrames[0])
        #expect(hidden.debugStatFrames[1] == shown.debugStatFrames[1])
    }

    /// At the app's text-size ceiling (XXXL), on the narrowest phone (SE) and
    /// the 18 Pro, no counter spills out of its quarter (#687).
    @Test(arguments: [CGFloat(375), 402])
    func theCeilingTextSizeStaysInsideTheCells(width: CGFloat) throws {
        let header = header(width: width, likes: .exact(1_234_567), textSize: .extraExtraExtraLarge)
        let cells = header.debugStatCellFrames
        for (index, frame) in header.debugStatFrames.enumerated() {
            let stat = try #require(frame)
            #expect(stat.minX >= cells[index].minX - 0.5 && stat.maxX <= cells[index].maxX + 0.5,
                    "counter \(index) spills at XXXL on \(width): \(stat) vs \(cells[index])")
        }
    }
}
