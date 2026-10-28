import CoreModels
import DesignSystem
import Foundation
import PostGrid
import Testing
import UIKit
@testable import Profile

/// A row action that removes its row (#1775): the row wears the kit's loader
/// while the server works, then leaves — or comes back as it was, with the
/// error.
@MainActor
struct RowActionBusyTests {
    private struct Viewer: ProfileViewerResolving {
        func viewerProfileID() async -> ProfileID? { ProfileID("me") }
    }

    /// Two deleted posts; each restore waits for the test, then lands or fails.
    private actor GatedTrash: PostTrashManaging {
        private var held: [CheckedContinuation<Void, Never>] = []
        private let fails: Bool

        init(fails: Bool) { self.fails = fails }

        func deletePost(_ postID: PostID, author: ProfileID) async throws {}

        func recentlyDeleted(for author: ProfileID) async throws -> [DeletedPost] {
            ["a", "b"].map {
                DeletedPost(
                    post: GalleryPost(id: PostID($0), kind: .text, isRepost: false, thumbnailURL: nil, caption: $0, publishedAtMS: 1),
                    deletedAt: Date()
                )
            }
        }

        func restorePost(_ postID: PostID, author: ProfileID) async throws {
            await withCheckedContinuation { held.append($0) }
            if fails { throw PostRestoreError.transport(message: "down") }
        }

        var waiting: Int { held.count }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    private func open(_ trash: GatedTrash) async throws -> (RecentlyDeletedViewController, UIWindow) {
        let screen = RecentlyDeletedViewController(
            viewModel: RecentlyDeletedViewModel(trash: trash, viewer: Viewer()), imagePipeline: nil
        )
        screen.skeletonClock = ManualLoadingClock().clock
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = screen
        window.isHidden = false
        for _ in 0..<500 where !screen.debugRow(PostID("a")).shown { try await Task.sleep(for: .milliseconds(10)) }
        try #require(screen.debugRow(PostID("a")).shown, "the deleted posts never showed")
        return (screen, window)
    }

    @Test func aRestoredRowWearsTheLoaderThenLeaves() async throws {
        let trash = GatedTrash(fails: false)
        let (screen, window) = try await open(trash)
        _ = window

        screen.debugRestore(at: 0)
        #expect(screen.debugRow(PostID("a")).busy, "the row sat unchanged while its post came back")
        #expect(!screen.debugRow(PostID("b")).busy)
        while await trash.waiting == 0 { await Task.yield() }
        await trash.release()
        for _ in 0..<500 where screen.debugRow(PostID("a")).shown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!screen.debugRow(PostID("a")).shown, "the restored row stayed")
    }

    @Test func aFailedRestoreBringsTheRowBackAsItWas() async throws {
        let trash = GatedTrash(fails: true)
        let (screen, window) = try await open(trash)
        _ = window

        screen.debugRestore(at: 0)
        while await trash.waiting == 0 { await Task.yield() }
        await trash.release()
        for _ in 0..<500 where !(screen.presentedViewController is UIAlertController) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(screen.presentedViewController is UIAlertController, "the failure was not told")
        let row = screen.debugRow(PostID("a"))
        #expect(row.shown && !row.busy, "the row did not come back as it was")
    }
}
