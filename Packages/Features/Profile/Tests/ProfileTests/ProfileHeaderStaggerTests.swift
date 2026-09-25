import CoreModels
import MediaCore
import Testing
import UIKit
@testable import Profile

/// A staggered switch never lands after a newer render.
///
/// ⚠️ **The stats and the bio arrive 0.05 s and 0.10 s late, and used to carry
/// their own call's model regardless.** A render that landed inside that window
/// — a fresh fetch applied plainly — was overwritten by the older profile's
/// numbers and prose until the next render.
@MainActor
struct ProfileHeaderStaggerTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private static func model(_ name: String, bio: String, followers: Int64) -> ProfileDisplayModel {
        ProfileDisplayModel(profile: UserProfile(
            id: ProfileID(name), handle: name, displayName: name.capitalized, bio: bio,
            avatarURL: nil, websiteURL: nil, isVerified: false,
            followerCount: .exact(followers), followingCount: .exact(1),
            reactionCount: .exact(1), viewCount: .exact(1)
        ))
    }

    private static func texts(in view: UIView) -> [String] {
        ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap(texts(in:))
    }

    @Test func aRenderInsideTheStaggerIsNotOverwritten() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let header = ProfileHeaderView(imagePipeline: ImagePipeline(fetcher: SilentFetcher()))
        header.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        window.addSubview(header)
        window.isHidden = false
        header.configure(with: Self.model("ava", bio: "Bio of Ava", followers: 11))

        header.configure(with: Self.model("ben", bio: "Bio of Ben", followers: 22), staggered: true)
        header.configure(with: Self.model("cleo", bio: "Bio of Cleo", followers: 33))
        try await Task.sleep(for: .milliseconds(400))

        let shown = Self.texts(in: header)
        #expect(shown.contains("Bio of Cleo"), "the newest render's bio is gone: \(shown)")
        #expect(!shown.contains("Bio of Ben"), "a staggered group landed after a newer render")
        #expect(shown.contains("33"), "guard: a count renders as its bare number: \(shown)")
        #expect(!shown.contains("22"), "the older model's stats came back")
    }
}
