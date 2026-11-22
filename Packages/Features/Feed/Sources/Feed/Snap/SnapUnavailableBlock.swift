import DesignSystem
import MediaPlayback
import UIKit

/// What the unavailable block asks of its page (#2521): the content view it
/// covers, the chrome and the column it stands down, the playback it stops,
/// and the page's media ground.
@MainActor
protocol SnapUnavailableBlockHost: AnyObject {
    var contentView: UIView { get }
    var mediaCard: SnapMediaCardView { get }
    var chrome: SnapChromeView { get }
    var videoPlayback: VideoPlaybackController? { get }
    var playback: SnapCellPlayback { get }
    var pageHasMedia: Bool { get }
    func setPauseGlyphVisible(_ visible: Bool)
    func updatePlayheadFeed()
}

/// A post the server shows the viewer no more (#447, #1409), out of
/// `SnapFeedCell` (#2521): the "This post isn't available" block over
/// everything the page draws, and what stands down when it goes up.
@MainActor
final class SnapUnavailableBlock {
    private unowned let host: any SnapUnavailableBlockHost

    init(host: any SnapUnavailableBlockHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var contentView: UIView { host.contentView }
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var chrome: SnapChromeView { host.chrome }
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }
    private var playback: SnapCellPlayback { host.playback }
    private var pageHasMedia: Bool { host.pageHasMedia }
    private func setPauseGlyphVisible(_ visible: Bool) { host.setPauseGlyphVisible(visible) }
    private func updatePlayheadFeed() { host.updatePlayheadFeed() }

    /// Whether the represented post is one the server shows the viewer no
    /// more (#447) — taken down, deleted, withheld. Its page then reads
    /// "This post isn't available" over the page's ground, with nothing to
    /// act on: the chrome (caption, streams, reactions rail, the comments'
    /// entry points) and the like / sound column stand down, and no clip
    /// plays. The screen says so — at configure, from what it has learnt,
    /// so paging away and back keeps it; in place, the moment it learns it.
    private(set) var isPostUnavailable = false

    /// The block, over everything the page draws. Opaque and touchable, so
    /// the picture under it takes no tap; the pager's own pan still pages.
    private lazy var unavailableBlock: UIView = {
        let ground = UIView()
        ground.backgroundColor = .systemBackground
        let block = EmptyStateView()
        block.configure(symbolName: "eye.slash", title: PostDetailViewModel.unavailableMessage)
        block.pin(to: ground)
        // VoiceOver reads the block, never the post under it.
        ground.accessibilityViewIsModal = true
        ground.isHidden = true
        contentView.addSubview(ground)
        ground.pin(to: contentView)
        return ground
    }()

    func setPostUnavailable(_ unavailable: Bool) {
        guard unavailable != isPostUnavailable else { return }
        isPostUnavailable = unavailable
        chrome.isHidden = unavailable
        chrome.actionColumn.setActionColumnShown(!unavailable)
        if unavailable {
            // What was playing stops where it stands, and nothing starts it
            // again: every start asks `isPostUnavailable`, and a resume a hold
            // or a sheet still owed is void. The player stays the page's,
            // released by the usual doors (resign, reuse).
            videoPlayback?.setPaused(true, in: mediaCard.renderView)
            if mediaCard.showsCollection, let surface = mediaCard.currentPageSurface {
                videoPlayback?.setPaused(true, in: surface)
            }
            playback.forgetOwedResumes()
            setPauseGlyphVisible(false)
            // The clip bar's feed, the occlusion and the comment streams
            // stand down with it.
            updatePlayheadFeed()
            chrome.commentSurfaces.setTickerActive(false)
            chrome.setSubtitlesActive(false)
            // A media page's ground is dark whatever the system says; a text
            // page's follows it.
            unavailableBlock.overrideUserInterfaceStyle = pageHasMedia ? .dark : .unspecified
            contentView.bringSubviewToFront(unavailableBlock)
        }
        unavailableBlock.isHidden = !unavailable
    }

    #if DEBUG
    /// Whether the page shows "This post isn't available", for a test.
    var debugShowsUnavailableBlock: Bool { isPostUnavailable && !unavailableBlock.isHidden }
    #endif
}
