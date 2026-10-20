import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import PostGrid
import UIKit

/// How a stake row opens its post (#1476, #1477) — the hub's preview and the
/// Stakes screen alike: the feed flies out of the row the way a For You or
/// Profile card opens, the thumbnail for a media post, the card itself (the
/// text reveal) for a text post.
@MainActor
enum WalletStakeHero {
    /// The feed's window, from the tapped stake down.
    static let feedWindow = 20

    /// Opens the feed on `order` from `id` on, over `presenter`.
    ///
    /// ⚠️ **OVER THE SHEET, NOT INSIDE IT.** The feed flies with a navigation
    /// push, and a sheet's own stack would keep the feed in the sheet's
    /// shape. So a clear, full-screen stack is presented over the sheet
    /// without animation (`OverSheetFeedHost`), the feed is pushed onto IT,
    /// and the flight measures the row through the clear host — the sheet
    /// stays visible underneath for the whole trip. The host dismisses
    /// itself, unanimated, once the feed has flown home.
    ///
    /// The window is the list's own order from the tapped row down, so the
    /// feed pages through the stakes exactly as the list shows them; and a
    /// dismissal lands on the row that opened it, whatever the viewer paged
    /// to — the product rule of every ranked list in the app — crossfading
    /// when the page it closes is another post's.
    static func open(
        stake id: String, order: [String], posts: [PostID: GalleryPost], from presenter: UIViewController,
        list: UICollectionView, cell: @escaping (String) -> WalletStakeCell?,
        openFeedHero: @escaping WalletHubViewController.OpenFeedHero
    ) {
        guard presenter.presentedViewController == nil, let post = posts[PostID(id)],
              let start = order.firstIndex(of: id) else { return }
        let stream = Array(order[start...].compactMap { posts[PostID($0)] }.prefix(feedWindow))
        let flight = heroOrigin(for: post, stream: stream, list: list, cell: { cell(id) })
        OverSheetFeedHost.present(over: presenter) { host in
            openFeedHero(stream.map(\.id), host, flight)
        }
    }

    /// The row's thumbnail (media) or card (text), in `space` — nil once it
    /// has scrolled out of the list's visible part.
    private static func frame(
        of cell: WalletStakeCell?, card: Bool, list: UICollectionView, in space: UICoordinateSpace
    ) -> CGRect? {
        guard let cell else { return nil }
        let inList = cell.convert(cell.bounds, to: list)
        guard list.bounds.intersects(inList) else { return nil }
        return card ? cell.convert(cell.bounds, to: space) : cell.heroFrame(in: space)
    }

    private static func heroOrigin(
        for post: GalleryPost, stream: [GalleryPost], list: UICollectionView,
        cell: @escaping () -> WalletStakeCell?
    ) -> SnapFeedHeroOrigin {
        let flies = post.kind != .text
        // ⚠️ THE ROW IS NOT THE PAGE, so a text post's window needs a
        // stand-in at both ends — the map marker's case, not the For You
        // card's. A card's caption IS the page's caption, so its window can
        // show the real page from frame 0; this row is an author, a snippet
        // and a stake amount, and without a stand-in the window landed as a
        // blank white card that sat there until the row popped back in
        // (filmed: a third of a second). A picture of the row, taken now
        // while it is still drawn, is what the window crossfades to and from.
        let rowImage = cell()?.renderedImage()
        let standIn: () -> UIView? = {
            guard let rowImage else { return nil }
            let view = UIImageView(image: rowImage)
            // At its own size, pinned top-left: the window is the row's rect
            // only at the two ends, and a stretched row between them read as
            // a smear (filmed on the opening).
            view.contentMode = .topLeft
            view.clipsToBounds = true
            return view
        }
        return SnapFeedHeroOrigin(
            post: post,
            stream: stream,
            hasHero: flies,
            cover: cell()?.heroCover,
            // `.listMedia`: no counter chips riding the card (a tile's
            // furniture flashed over the 48pt thumbnail on landing), and the
            // same 12pt corner the thumbnail wears.
            style: .listMedia,
            frame: { [weak list] space in
                guard let list else { return nil }
                return frame(of: cell(), card: false, list: list, in: space)
            },
            isOnScreen: { [weak list] in
                guard let list else { return false }
                return frame(of: cell(), card: false, list: list, in: list) != nil
            },
            setConcealed: { concealed in cell()?.setHeroConcealed(concealed, wholeCard: false) },
            // No depth cue for the FLIGHT: the list it would recede is the
            // very surface the landing is measured on (see the PR).
            textReveal: flies ? nil : TextRevealOrigin(
                rowFrame: { [weak list] space in
                    guard let list else { return nil }
                    return frame(of: cell(), card: true, list: list, in: space)
                },
                captionEnd: nil,
                depthView: { [weak list] in list },
                makeDismissStandIn: { _ in standIn() },
                makePresentStandIn: standIn,
                alignsPageToSource: false,
                pageFit: .covering,
                cornerRadius: WalletSheetMetrics.rowCorner,
                fill: Surface.card,
                setConcealed: { concealed in cell()?.setHeroConcealed(concealed, wholeCard: true) }
            )
        )
    }
}
