import MediaPlayback
import UIKit

/// What the browse preview asks of its page (#2521): the media card, the
/// pool and the chrome whose filmstrip shows the preview.
@MainActor
protocol SnapBrowseMirrorHost: AnyObject {
    var mediaCard: SnapMediaCardView { get }
    var videoPlayback: VideoPlaybackController? { get }
    var chrome: SnapChromeView { get }
}

/// The clip's live preview in the filmstrip while a finger browses a
/// carousel's pages (#1734), out of `SnapFeedCell` (#2521): a passive surface
/// joined to the page's own player, so the tile shows the post's frames in
/// step, and taken down when the finger lets go.
@MainActor
final class SnapBrowseMirror {
    private unowned let host: any SnapBrowseMirrorHost

    init(host: any SnapBrowseMirrorHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var mediaCard: SnapMediaCardView { host.mediaCard }
    private var videoPlayback: VideoPlaybackController? { host.videoPlayback }
    private var chrome: SnapChromeView { host.chrome }

    /// A finger is sliding through the carousel's pages on the strip (#1734).
    var isBrowsingMedia = false
    /// The clip's preview while browsing: a passive surface bound to the
    /// page's own player, so the tile shows the post's frames in step.
    private var browseMirror: VideoRenderView?
    /// The page the mirror is drawing, nil when it draws nothing.
    private(set) var browseMirrorPage: Int?

    /// Puts the clip the post is playing into its preview — the same player
    /// (`attachSurface(_:alongsideSurface:)`), so the two cannot drift — or
    /// takes the preview's picture out when the page under the finger is a
    /// photograph, or its clip has no player yet (retried from the playhead).
    func refreshBrowseMirror() {
        let page = mediaCard.currentPage
        guard isBrowsingMedia, let videoPlayback, mediaCard.videoPageIndices.contains(page),
              let surface = mediaCard.currentPageSurface else { return tearDownBrowseMirror() }
        let mirror = browseMirror ?? {
            let view = VideoRenderView()
            // The tile's thumbnail shows through until the first frame.
            view.paintsOpaqueGround = false
            view.isUserInteractionEnabled = false
            browseMirror = view
            return view
        }()
        if browseMirrorPage != page || !videoPlayback.sharesPlayback(mirror, with: surface) {
            videoPlayback.detachSurface(mirror, reason: "browse-mirror")
            guard videoPlayback.attachSurface(mirror, alongsideSurface: surface) else {
                browseMirrorPage = nil
                chrome.mediaStrip.setBrowseLiveSurface(nil, page: page)
                return
            }
        }
        browseMirrorPage = page
        chrome.mediaStrip.setBrowseLiveSurface(mirror, page: page)
    }

    func tearDownBrowseMirror() {
        guard let mirror = browseMirror else { return }
        videoPlayback?.detachSurface(mirror, reason: "browse-mirror")
        browseMirrorPage = nil
        chrome.mediaStrip.setBrowseLiveSurface(nil, page: 0)
    }
}
