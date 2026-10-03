import CoreModels
import CoreStorage
import Foundation
import Testing
@testable import Feed

/// The viewer's media-comment preferences (#410) applied where a post's band
/// and zone are built: switches, muted words and accounts, and the rule that
/// a band switched off hands every comment to the zone.
@MainActor
struct CommentPreferencesStreamTests {
    private func entry(_ id: String, _ body: String, handle: String = "ava") -> CommentEntry {
        CommentEntry(
            id: id, authorID: ProfileID("prof-\(handle)"), authorName: handle, authorHandle: handle,
            body: body, createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    /// Enough reaction-shaped comments to clear the band's gate, plus
    /// semantic ones that only the zone carries.
    private func entries() -> [CommentEntry] {
        let reactions = ["GG 🔥🔥", "lol", "W", "🔥🔥🔥", "so good", "insane 😭", "yesss", "goat 🐐"]
            .enumerated().map { entry("r\($0.offset)", $0.element) }
        let semantic = (0..<4).map { entry("s\($0)", "This is a longer thought number \($0) worth reading.") }
        return reactions + semantic
    }

    private func model(_ mutate: (inout MediaCommentPreferences) -> Void = { _ in }) -> (FeedViewModel, MediaCommentPreferencesStore) {
        let defaults = UserDefaults(suiteName: "comment-prefs-\(UUID().uuidString)")!
        let store = MediaCommentPreferencesStore(defaults: defaults)
        store.update(mutate)
        return (FeedViewModel(repository: StillFeedProvider(), commentPreferences: store), store)
    }

    @Test func byDefaultBothSurfacesRender() {
        let (viewModel, _) = model()
        let streams = viewModel.makeStreams(from: entries(), for: PostID("post-1"))
        #expect(!streams.reactions.isEmpty)
        #expect(streams.commentCount == 12)
    }

    @Test func aBandSwitchedOffRendersNothingAndTheZoneCarriesMore() {
        let (on, _) = model()
        let (off, _) = model { $0.showsReactionBand = false }
        let withBand = on.makeStreams(from: entries(), for: PostID("post-1"))
        let withoutBand = off.makeStreams(from: entries(), for: PostID("post-1"))
        #expect(withoutBand.reactions.isEmpty)
        #expect(withoutBand.subtitles.count >= withBand.subtitles.count)
    }

    @Test func subtitlesSwitchedOffNeverChangeTheBand() {
        let (on, _) = model()
        let (off, _) = model { $0.showsSubtitles = false }
        let withZone = on.makeStreams(from: entries(), for: PostID("post-1"))
        let withoutZone = off.makeStreams(from: entries(), for: PostID("post-1"))
        #expect(withoutZone.subtitles.isEmpty)
        #expect(withoutZone.reactions == withZone.reactions)
    }

    @Test func mutedWordsAndAccountsNeverRide() {
        var all = entries()
        all.append(entry("x1", "spoiler 🔥", handle: "ava"))
        all.append(entry("x2", "W", handle: "troll"))
        let (viewModel, _) = model {
            $0.mutedKeywords = ["spoiler"]
            $0.mutedHandles = ["troll"]
        }
        let streams = viewModel.makeStreams(from: all, for: PostID("post-1"))
        #expect(!streams.reactions.contains { $0.id == "x1" || $0.id == "x2" })
        #expect(!streams.subtitles.contains { $0.id == "x1" || $0.id == "x2" })
    }

    /// Muting enough reactions drops the post below the band's gate: the
    /// gate counts only what may actually ride.
    @Test func theGateCountsOnlyUnmutedReactions() {
        let (viewModel, _) = model { $0.mutedHandles = ["ava"] }
        #expect(viewModel.makeStreams(from: entries(), for: PostID("post-1")).reactions.isEmpty)
    }

    // MARK: - Preferences

    @Test func mutingMatchesCaseInsensitivelyAndHandlesWithOrWithoutAt() {
        let preferences = MediaCommentPreferences(mutedKeywords: ["spoiler"], mutedHandles: ["troll"])
        #expect(preferences.mutes(body: "Big SPOILER here", authorHandle: "ava"))
        #expect(preferences.mutes(body: "hi", authorHandle: "@Troll"))
        #expect(!preferences.mutes(body: "hi", authorHandle: "ava"))
        #expect(MediaCommentPreferences.normalizedHandle(" @@Maya ") == "maya")
        #expect(MediaCommentPreferences.normalizedKeyword("  Spoiler ") == "spoiler")
    }

    @Test func opacityIsClamped() {
        var preferences = MediaCommentPreferences(bandOpacity: 0.05)
        #expect(preferences.bandOpacity == MediaCommentPreferences.opacityRange.lowerBound)
        preferences.bandOpacity = 3
        #expect(preferences.bandOpacity == 1)
    }

    @Test func theStorePersistsAndAnnouncesOnlyRealChanges() {
        let defaults = UserDefaults(suiteName: "comment-prefs-\(UUID().uuidString)")!
        let store = MediaCommentPreferencesStore(defaults: defaults)
        var notices = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .mediaCommentPreferencesDidChange, object: store, queue: nil
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.update { $0.bandSpeed = .fast }
        store.update { $0.bandSpeed = .fast }
        #expect(notices == 1)
        #expect(MediaCommentPreferencesStore(defaults: defaults).preferences.bandSpeed == .fast)
    }

    @Test func theBandReadsSpeedAndOpacityFromTheStore() {
        let defaults = UserDefaults(suiteName: "comment-prefs-\(UUID().uuidString)")!
        let store = MediaCommentPreferencesStore(defaults: defaults)
        store.update {
            $0.bandSpeed = .slow
            $0.bandOpacity = 0.5
        }
        SnapCommentTickerView.refreshAppearance(from: store)
        defer { SnapCommentTickerView.refreshAppearance(from: MediaCommentPreferencesStore(defaults: UserDefaults(suiteName: "reset-\(UUID().uuidString)")!)) }
        #expect(SnapCommentTickerView.laneSpeeds == SnapCommentTickerView.baseLaneSpeeds.map { $0 * 0.7 })
        #expect(SnapCommentTickerView.bubbleOpacity == 0.5)
    }
}

private final class StillFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
