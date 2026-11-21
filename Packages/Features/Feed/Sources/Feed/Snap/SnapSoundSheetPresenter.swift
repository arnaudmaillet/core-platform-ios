import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import PostSurfaces
import UIKit

/// What the full-screen feed's sound sheet asks of its screen (#2514): the
/// page in front and the pages it holds, the pager a tile scrolls, the cell
/// the sheet covers, the sound that yields to the sheet's own track, and the
/// warms of the posts it lists.
///
/// A view controller: the sheet is presented from it.
@MainActor
protocol SnapSoundSheetPresenterHost: UIViewController {
    /// The settled page's model.
    var activeModel: FeedItemDisplayModel? { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var orderedIDs: [PostID] { get }
    var lifecycle: SnapLifecycleDispatcher { get }
    var collectionView: UICollectionView! { get }
    var imagePipeline: ImagePipeline { get }
    var bookmarks: PostBookmarkStore { get }
    var activeSnapCell: SnapFeedCell? { get }
    var soundPlayback: SnapSoundPlayback { get }
    var postOpenWarm: PostOpenWarm? { get }
    func updateActiveItem()
    func updateViewportPlayback()
}

/// The full-screen feed's sound sheet (#2514): the sheet the attribution's
/// tap raises for the sound the page is set to, its sections and a tile for
/// each post in them, what it covers and pauses while it plays, and the post
/// a tile brings to the screen.
///
/// What is HEARD stays the sound's (`SnapSoundPlayback`, which holds the
/// sheet weakly for its track); the inputs are `SnapSoundState`'s and the
/// dealing `SoundSheetSections`'. This builds the sheet from them and wires it.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: the sheet rises in the caller's turn, as it
/// did; only the placeholders' loading waits.
@MainActor
final class SnapSoundSheetPresenter {
    private unowned let host: any SnapSoundSheetPresenterHost
    /// The page's sound and the sheet's inputs (`SnapSoundState`).
    private let soundState: SnapSoundState
    private let savedSounds: SavedSoundStore
    private let videoPlayback: VideoPlaybackController?
    /// See `FeedFeatureBuilder.useSound`.
    private let useSound: (@MainActor (PostSound) -> Void)?
    /// Opens a new feed with the hero — the sound sheet's grid uses it.
    private let openFeedHero: (@MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?
    private let galleryPost: (@MainActor (PostID) -> GalleryPost?)?
    /// Loads posts into the repository's cache, after which `galleryPost`
    /// answers for them — the sound sheet's tiles outside this feed.
    private let prewarmPosts: (@Sendable ([PostID]) async -> Void)?
    #if DEBUG
    /// The sheet the last `presentSoundSheet` raised, for the QA hooks.
    private(set) weak var debugPresentedSoundSheet: SoundSheetViewController?
    #endif

    init(
        host: any SnapSoundSheetPresenterHost,
        soundState: SnapSoundState,
        savedSounds: SavedSoundStore,
        videoPlayback: VideoPlaybackController?,
        useSound: (@MainActor (PostSound) -> Void)?,
        openFeedHero: (@MainActor ([PostID], UIViewController, SnapFeedHeroOrigin) -> Void)?,
        galleryPost: (@MainActor (PostID) -> GalleryPost?)?,
        prewarmPosts: (@Sendable ([PostID]) async -> Void)?
    ) {
        self.host = host
        self.soundState = soundState
        self.savedSounds = savedSounds
        self.videoPlayback = videoPlayback
        self.useSound = useSound
        self.openFeedHero = openFeedHero
        self.galleryPost = galleryPost
        self.prewarmPosts = prewarmPosts
    }

    /// The attribution's tap: the sound the page is set to, in a sheet.
    func presentSoundSheet() {
        guard host.presentedViewController == nil, let model = host.activeModel,
              let inputs = soundState.sheetInputs(for: model)
        else { return }
        // The sheet lists EVERY post set to this sound, not only this feed's
        // (`SnapSoundState.sheetInputs`).
        let rankings = inputs.rankings
        let original = inputs.original
        let current = model.id
        let content = soundSheetContent(current: current, original: original, rankings: rankings)
        // The sheet's own track (the owner, 2026-10-31): a clip's original
        // sound is the clip itself, which the pool opens even where a bare
        // player cannot (`mock://`) — the sheet resolves it through the pool.
        var sound = inputs.sound
        if sound.previewURL == nil, SnapSoundState.isSingleClip(model), let clip = model.mediaURL {
            sound = PostSound(
                id: sound.id, title: sound.title, artist: sound.artist,
                previewURL: clip, artworkURL: sound.artworkURL, duration: sound.duration
            )
        }
        let sheet = SoundSheetViewController(
            sound: sound,
            authorHandle: inputs.authorHandle,
            fallbackArtworkURL: inputs.fallbackArtworkURL,
            sections: content.sections,
            tiles: content.tiles,
            imagePipeline: host.imagePipeline,
            savedSounds: savedSounds,
            bookmarks: host.bookmarks,
            // The tiles play on the app's one pool, beside this page (#884).
            videoPlayback: videoPlayback,
            // This post: set to the sound, counted, shown nowhere (#1147).
            watchedPosts: 1
        )
        // Only a sound the device HOLDS can go under a new clip.
        if inputs.offersUseSound, let useSound {
            sheet.onUseSound = { sound in useSound(sound) }
        }
        // The cell that is covered now is the one to uncover, whatever the
        // feed does meanwhile.
        weak var covered = host.activeSnapCell
        // The record is the sheet's own track (the owner, 2026-10-31): its
        // preview covers the page while it plays (`onCoverChanged`), and the
        // page playing again stops it (`refreshCoverSpin`).
        host.soundPlayback.soundSheet = sheet
        sheet.onCoverChanged = { [weak self] covering in
            covered?.setCoveredBySheet(covering)
            self?.host.soundPlayback.yieldAudio(covering)
        }
        sheet.onDismissed = { [weak self] in
            covered?.setCoveredBySheet(false)
            self?.host.soundPlayback.yieldAudio(false)
        }
        // The expanded sheet pauses the post, and its collapse or its going
        // plays it again: the sheet declares itself a cover (#1970), and
        // `viewportShare` hears it — nothing to wire here.
        sheet.onSelectPost = { [weak self] id in self?.showPost(id) }
        sheet.openFeedHero = openFeedHero
        sheet.galleryPost = galleryPost
        // Inside a navigation controller, for the toolbar its actions live in.
        host.present(sheet.wrappedInSheet(), animated: true)
        // Its posts open full screen: their first comments are warmed, in
        // the sheet's order, and dropped from the queue when it goes (#2002).
        host.postOpenWarm?.warmLater(content.tiles.map(\.postID), owner: sheet)
        #if DEBUG
        debugPresentedSoundSheet = sheet
        #endif
        // ⚠️ THE SHEET RISES AT ONCE, never after an await: the posts this
        // feed does not hold are placeholders, filled in when the repository
        // has loaded them — and a post it cannot load leaves the sheet, since
        // its tile would lead nowhere; the sections are dealt again without
        // it.
        let pending = content.tiles.filter { !$0.isLoaded }.map(\.postID)
        guard !pending.isEmpty, let prewarmPosts else { return }
        Task { @MainActor [weak self, weak sheet] in
            await prewarmPosts(pending)
            guard let self, let sheet else { return }
            let loaded = soundSheetContent(
                current: current, original: original, rankings: rankings, droppingUnknown: true
            )
            sheet.update(sections: loaded.sections, tiles: loaded.tiles)
        }
    }

    /// The sound sheet's sections, and a tile for each post in them, from
    /// what the feed knows of each post NOW: its own page, else the
    /// repository's cache (a post shown elsewhere, or loaded for the sheet),
    /// else nothing yet — a placeholder. `droppingUnknown` leaves out the
    /// posts still unknown (the loading is over: they could not be loaded),
    /// the page watched excepted.
    private func soundSheetContent(
        current: PostID, original: PostID?, rankings: PostSoundRankings, droppingUnknown: Bool = false
    ) -> (sections: [SoundSheetSection], tiles: [SoundSheetViewController.Tile]) {
        let galleryPost = galleryPost
        typealias Known = (thumbnailURL: URL?, caption: String?, isMedia: Bool, likes: Int64?, video: URL?)
        let known: (PostID) -> Known? = { [modelsByID = host.modelsByID] id in
            if let model = modelsByID[id] {
                return (
                    model.thumbnailURL, model.caption, model.mediaURL != nil, model.likeCount,
                    model.mediaKind == .video ? model.mediaURL : nil
                )
            }
            if let post = galleryPost?(id) {
                return (
                    post.thumbnailURL, post.caption.isEmpty ? nil : post.caption,
                    post.kind != .text, post.reactionCount,
                    post.hasPlayableVideo ? post.videoURL : nil
                )
            }
            return nil
        }
        let everyPost = Set(rankings.popular + rankings.recent + [original].compactMap { $0 })
        let dropped = Self.soundSheetExclusions(
            everyPost, current: current, droppingUnknown: droppingUnknown, isMedia: { known($0)?.isMedia }
        )
        let dealt = SoundSheetSections.make(
            rankings: rankings, current: current, original: original,
            isMedia: { known($0)?.isMedia }, excluding: dropped
        )
        var seen = Set<PostID>()
        let ids = dealt.sections.flatMap(\.all).filter { seen.insert($0).inserted }
        let tiles = ids.map { id in
            let post = known(id)
            return SoundSheetViewController.Tile(
                postID: id, thumbnailURL: post?.thumbnailURL, caption: post?.caption,
                isOriginal: id == dealt.original, isLoaded: post != nil,
                likeCount: post?.likes, videoURL: post?.video,
                // The post as the repository has it — author included — for
                // the standard tile's words (#1280).
                post: galleryPost?(id)
            )
        }
        return (dealt.sections, tiles)
    }

    /// The posts the sound sheet leaves out:
    /// - ⚠️ every TEXT post (#1999): a text post has no sound, so none is set
    ///   to this one, whatever an older post or a server still says;
    /// - once the loading is over (`droppingUnknown`), every post still
    ///   unknown, the page watched excepted.
    /// `isMedia`: nil for a post not known yet.
    nonisolated static func soundSheetExclusions(
        _ posts: Set<PostID>, current: PostID, droppingUnknown: Bool, isMedia: (PostID) -> Bool?
    ) -> Set<PostID> {
        posts.filter { id in
            switch isMedia(id) {
            case false?: true
            case nil: droppingUnknown && id != current
            case true?: false
            }
        }
    }

    /// Brings `id` to the screen — a tile of the sound sheet.
    private func showPost(_ id: PostID) {
        guard let index = host.orderedIDs.firstIndex(of: id), index != host.lifecycle.activeIndex else { return }
        UIView.transition(with: host.collectionView, duration: 0.25, options: .transitionCrossDissolve) {
            self.host.collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
        }
        host.updateActiveItem()
        host.updateViewportPlayback()
    }
}
