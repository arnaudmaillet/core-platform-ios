import CoreModels
import LaunchArguments
import MediaCore
import PostSurfaces
import ThreadKit
import UIKit

/// What the settled page's chrome asks of the screen (#2514): the pages and
/// their models, the author pill and the follow graph, the bars' theme, the
/// toolbar, the active cell's sound bubble and the open panel's rail slot.
@MainActor
protocol SnapSettledPageChromeHost: AnyObject {
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var imagePipeline: ImagePipeline { get }
    var authorBar: SnapAuthorBar { get }
    var authorIdentityView: SnapAuthorIdentityView { get }
    var followStore: SnapAuthorFollowStore { get }
    var toolbarComposer: SnapToolbarComposer { get }
    var activeSnapCell: SnapFeedCell? { get }
    var commentsContentVC: UIViewController? { get }
    func applyChromeTheme(hasMedia: Bool)
    func soundFace(for model: FeedItemDisplayModel) -> SnapSoundFace?
    func slotSharesPost(_ model: FeedItemDisplayModel) -> Bool
    func applyRailSlot(to panel: UIViewController?, hostedByPage: Bool)
}

/// What the bars and the page's own chrome wear for the settled page
/// (#2514): the author in the pill and the neighbours' faces and covers
/// warmed, the follow graph asked, the bars' theme and shadows, the toolbar's
/// save, post actions and sound, the page's sound bubble and the panel's rail
/// slot.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: the activation, the render and a
/// carousel's page change call it in their turn, where they called the
/// screen before.
@MainActor
final class SnapSettledPageChrome {
    private unowned let host: any SnapSettledPageChromeHost
    /// The page's sound, for the attribution's cover (`SnapSoundState`).
    private let soundState: SnapSoundState

    init(host: any SnapSettledPageChromeHost, soundState: SnapSoundState) {
        self.host = host
        self.soundState = soundState
    }

    func updateBarChrome(at index: Int) {
        guard host.orderedIDs.indices.contains(index),
              let model = host.modelsByID[host.orderedIDs[index]] else { return }
        // Usually a no-op for the pill: the scroll that brought this page in
        // already swapped it when the picture changed owner
        // (`updateViewportPlayback`). A page reached without a scroll (a jump,
        // a landing) swaps here (#1791).
        host.authorBar.showAuthor(model)
        // The neighbours' faces, so the pill paged to next arrives wearing one.
        for neighbour in [index - 1, index + 1] where host.orderedIDs.indices.contains(neighbour) {
            if let url = host.modelsByID[host.orderedIDs[neighbour]]?.avatarURL {
                SnapAuthorIdentityView.warmFace(url, pipeline: host.imagePipeline)
            }
        }
        #if DEBUG
        if LaunchArgument.pillProbe.isPassed() {
            host.authorIdentityView.debugProbe("setAuthor \(model.authorName)")
        }
        #endif
        // The neighbours' covers, so the sound bubble paged to next arrives
        // wearing its own.
        for neighbour in [index - 1, index + 1] where host.orderedIDs.indices.contains(neighbour) {
            if let next = host.modelsByID[host.orderedIDs[neighbour]] {
                SnapMediaAttributionView.warmCover(
                    for: next, cover: attributionContent(for: next).cover, pipeline: host.imagePipeline
                )
            }
        }
        // And where the viewer stands with this author and the neighbours', so
        // the pill's follow badge is decided before the page is.
        for neighbour in [index, index - 1, index + 1] where host.orderedIDs.indices.contains(neighbour) {
            if let author = host.modelsByID[host.orderedIDs[neighbour]]?.authorID {
                host.followStore.resolve(for: author)
            }
        }
        // The bars float over the PAGE, so their text has to know what kind
        // of ground it is floating over. A media page is arbitrary and dark
        // enough to want white-and-shadowed; a text page follows the system
        // appearance, where white text on a white ground is just gone.
        let overMedia = model.mediaURL != nil
        host.applyChromeTheme(hasMedia: overMedia)
        // The SHADOWS are not a theme question: they exist because the bars
        // float over an arbitrary photo with no background of their own, and
        // a text page's own ground makes them unnecessary. The colours now
        // come from the theme above.
        host.authorBar.authorOverMedia = overMedia
        host.authorIdentityView.setOverMedia(overMedia)
        host.toolbarComposer.refreshBookmarkGlyph(for: model.id)
        host.toolbarComposer.applyToolbarPostActions(for: model.id)
        // The page's sound bubble and the panel's rail slot (#671).
        host.activeSnapCell?.setSoundFace(host.soundFace(for: model))
        host.activeSnapCell?.setSlotSharesPost(host.slotSharesPost(model), holdArmsShare: host.slotSharesPost(model))
        // The footer's sound follows the page in place (#1999).
        host.toolbarComposer.refreshFooterSound(for: model)
        host.applyRailSlot(to: host.commentsContentVC, hostedByPage: true)
    }

    /// What the attribution draws for `model`: the sound's line, and a cover
    /// that is the SOUND's (`SnapSoundState.attribution`).
    private func attributionContent(
        for model: FeedItemDisplayModel
    ) -> (sound: SnapMediaAttributionView.SoundCredit, cover: SnapMediaAttributionView.Cover) {
        soundState.attribution(for: model)
    }
}
