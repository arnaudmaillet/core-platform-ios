import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// The header's identity block, at every width the app ships on.
///
/// ⚠️ **The failure this pins is a CLIPPED label, not a missing one**, which is
/// why it needs a test rather than a glance: a `UILabel` squashed below its line
/// height still reports its text, still says `isHidden == false`, and still
/// draws — with the top of every glyph cut off. On iPhone SE 3 the name resolved
/// to `114x9` for a title3 font, and the only symptom was a screenshot.
@MainActor
@Suite("Profile header fit")
struct ProfileHeaderFitTests {
    /// Widths in points, portrait, no split view.
    private enum DeviceWidth {
        /// iPhone SE 3 / 13 mini — the narrowest the app supports, and the one
        /// the clipping was reported on.
        static let narrow: CGFloat = 375
        /// iPhone 17 Pro.
        static let regular: CGFloat = 402
        /// iPhone 17 Pro Max.
        static let wide: CGFloat = 440
        static let all: [CGFloat] = [narrow, regular, wide]
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func header(width: CGFloat, displayName: String, bio: String) -> ProfileHeaderView {
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.configure(with: ProfileDisplayModel(profile: UserProfile(
            id: ProfileID("prof-1"),
            handle: "kenji.dev",
            displayName: displayName,
            bio: bio,
            avatarURL: nil,
            websiteURL: URL(string: "https://kenji.example"),
            isVerified: false,
            followerCount: .exact(4),
            followingCount: .exact(4),
            reactionCount: .exact(1_000),
            viewCount: .unavailable
        )))
        // ⚠️ The FULL tray, because the tray's width is what squeezes the
        // avatar and the avatar is what squeezed the name. Left at its default
        // the map-pin star is hidden, the tray is 44pt narrower, the avatar
        // grows into the slack and the bug does not reproduce — the first cut of
        // this suite passed against the very build it was written for.
        header.configureAction(.following)
        header.configureMapPin(.shown(categories: [], includesFriends: false))
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        header.frame.size.height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        header.setNeedsLayout()
        header.layoutIfNeeded()
        return header
    }

    /// Found by walking rather than through an accessor — the header keeps its
    /// labels private, and a test that forced them open would be pinning the
    /// seam instead of the layout.
    private func label(withText text: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == text { return label }
            if let found = label(withText: text, in: subview) { return found }
        }
        return nil
    }

    /// The name gets its whole line height, at every width.
    ///
    /// The avatar is tied to the identity column's height so the two read as one
    /// block — but the avatar is also square, so its height is its width, and
    /// its width is whatever the action tray leaves beside it. At 375pt the tray
    /// takes enough that the avatar resolves to 87pt against a column that needs
    /// ~101, and a tie that outranked the labels spent the difference on the
    /// name.
    @Test func theDisplayNameIsNeverSquashedAtAnyWidth() {
        for width in DeviceWidth.all {
            let header = header(
                width: width,
                displayName: "Kenji Tanaka",
                bio: "Building small tools for small teams. Coffee first, commits later."
            )
            guard let name = label(withText: "Kenji Tanaka", in: header) else {
                Issue.record("no name label at \(width)pt")
                continue
            }
            #expect(
                name.bounds.height >= name.font.lineHeight,
                "the name is \(name.bounds.height)pt tall for a \(name.font.lineHeight)pt line at \(width)pt"
            )
        }
    }

    /// The handle too — it is the shorter of the two, so it fails second.
    @Test func theHandleIsNeverSquashedAtAnyWidth() {
        for width in DeviceWidth.all {
            let header = header(width: width, displayName: "Kenji Tanaka", bio: "Short bio.")
            guard let handle = label(withText: "@kenji.dev", in: header) else {
                Issue.record("no handle label at \(width)pt")
                continue
            }
            #expect(handle.bounds.height >= handle.font.lineHeight)
        }
    }

    /// A long name has to truncate, not push the tray off the screen — the row
    /// beside the avatar is the width-critical one.
    @Test func aLongNameKeepsTheHeaderInsideItsWidth() {
        for width in DeviceWidth.all {
            let header = header(
                width: width,
                displayName: "Bartholomew Featherstonehaugh-Cholmondeley",
                bio: "Short bio."
            )
            guard let name = label(withText: "Bartholomew Featherstonehaugh-Cholmondeley", in: header)
            else {
                Issue.record("no name label at \(width)pt")
                continue
            }
            #expect(name.bounds.height >= name.font.lineHeight)
            let frame = name.convert(name.bounds, to: header)
            #expect(frame.maxX <= width, "the name overruns \(width)pt: maxX \(frame.maxX)")
        }
    }
}
