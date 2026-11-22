import CoreModels
import Foundation

// The gallery's snapshot (#2522): every page of the pager at once.
extension ProfileViewModel {
    /// Every page at once — the pager renders every page (neighbors are
    /// visible mid-swipe), so the view model always answers for all of them.
    /// The source filter is a global modifier: it is already applied to each
    /// page's content here.
    public nonisolated struct GallerySnapshot: Equatable, Sendable {
        /// Posts: every post, the list laid out like For You (#631).
        public var activity: GalleryPageState
        /// The media among them — the gallery Posts' "View all" pushes.
        public var media: GalleryPageState
        /// Whether no further page is coming, under the active source. What
        /// lets the Posts list settle its tail chunk (`MosaicChunkPlanner`).
        public var isComplete: Bool = true
        /// The viewer's saved pile on their own profile; on anyone else's,
        /// the server's list of what they saved — empty unless its owner
        /// shows the tab (#837, #411).
        public var saved: GalleryPageState = .empty(message: "")
        /// The posts the profile liked (engagement `ListLikesByProfile`,
        /// #411) — empty for anyone but the owner while the owner hides it.
        public var reactions: GalleryPageState = .empty(message: "")
        /// The profile's reposts and the posts that tag it, each its own page
        /// (#696; your own profile too since #772).
        public var reposts: GalleryPageState = .empty(message: "")
        public var tagged: GalleryPageState = .empty(message: "")
        /// The posts the viewer viewed (#1344), on their own profile only.
        public var history: GalleryPageState = .empty(message: "")
        /// History's groups by day, over its posts in order — what the page
        /// titles (#1344). Empty: one untitled list.
        public var historyGroups: [HistoryGroup] = []
        /// When the viewer viewed each History post — written at the end of
        /// its row's first line (#2170). Keyed by post, so a date stays on
        /// its row through a removal or a refresh.
        public var historyViewedAt: [PostID: Date] = [:]
        /// Whether no further page is coming for Reposts and for Tagged: each
        /// follows its own corpus, apart from `isComplete`.
        public var repostsComplete = true
        public var taggedComplete = true
        /// Every page with nothing in it says the profile is private
        /// instead (#447): the server withholds them from the viewer. A page
        /// that HAS posts (Tagged — other people's) shows them plainly: the
        /// lock appears only when there is nothing to show (#1445, the
        /// owner's 2026-10-19 call, replacing #1422's lock line).
        /// A private profile known not to be followed (#1900): the pages
        /// the server withholds — every one but Tagged, which holds other
        /// people's posts (#1445) — are locked while they are still on their
        /// way, with no bones and no wait. Tagged locks only when empty.
        mutating func restrictWithheldPages() {
            let locked = GalleryPageState.restricted(title: ProfileViewModel.restrictedTitle, message: ProfileViewModel.restrictedMessage)
            for page in [\GallerySnapshot.activity, \.media, \.saved, \.reactions, \.reposts, \.history] {
                switch self[keyPath: page] {
                case .loading, .empty: self[keyPath: page] = locked
                default: break
                }
            }
            if case .empty = tagged { tagged = locked }
        }

        mutating func restrictEmptyPages() {
            let locked = GalleryPageState.restricted(title: ProfileViewModel.restrictedTitle, message: ProfileViewModel.restrictedMessage)
            for page in [\GallerySnapshot.activity, \.media, \.saved, \.reactions, \.reposts, \.tagged, \.history] {
                if case .empty = self[keyPath: page] { self[keyPath: page] = locked }
            }
        }

        public func state(for tab: ProfileTab) -> GalleryPageState {
            switch tab {
            case .format(.activity): activity
            case .format(.media): media
            // No page since #631: its text posts are cards on Posts.
            case .format(.short): .empty(message: "")
            case .saved: saved
            case .reactions: reactions
            case .reposts: reposts
            case .tagged: tagged
            case .history: history
            // Not posts (#2232): its page draws the profile's channels,
            // which `ProfileChannelsViewModel` reads.
            case .channels: .empty(message: "")
            }
        }

        /// Whether `tab`'s list has every page it will get.
        public func isComplete(for tab: ProfileTab) -> Bool {
            switch tab {
            case .reposts: repostsComplete
            case .tagged: taggedComplete
            default: isComplete
            }
        }
    }
}
