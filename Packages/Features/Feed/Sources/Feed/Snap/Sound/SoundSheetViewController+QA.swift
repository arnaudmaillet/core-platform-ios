#if DEBUG
import CoreModels
import DesignSystem
import PostGrid
import UIKit

/// `-sound-sheet-open <text|media|media>text|text>media> [close]`: opens a
/// tile of the sheet `-snap-sound-sheet` presented, the way a finger would —
/// the only route to a tile's hero on a simulator, which injects no taps.
///
/// - `text` / `media`: the first loaded tile of that kind whose tile is on
///   screen.
/// - `media>text` / `text>media`: one whose NEXT post in the feed is of the
///   other kind; the feed is then paged once (`debugFlingPages`) before the
///   close, which is the close the rows' #314 and this sheet's window exist for.
/// - `close` (any second value): pops the feed with the chevron once it has
///   landed (and paged), so the flight home is filmed too.
///
/// Every step waits on state through `QAWait` and says so when it gives up.
extension SoundSheetViewController {
    /// The over-sheet stack the last tile's feed was pushed onto.
    static weak var debugFeedHost: UIViewController?
    private static var didDebugOpenTile = false

    func debugOpenTileIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !Self.didDebugOpenTile,
              let position = arguments.firstIndex(of: "-sound-sheet-open"),
              arguments.indices.contains(position + 1)
        else { return }
        Self.didDebugOpenTile = true
        let mode = arguments[position + 1]
        let closes = arguments.indices.contains(position + 2) && !arguments[position + 2].hasPrefix("-")
        let parts = mode.split(separator: ">").map(String.init)
        let wantsText = parts.first == "text"
        let nextIsText: Bool? = parts.count > 1 ? parts[1] == "text" : nil
        let label = "-sound-sheet-open \(mode)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            QAWait.until(label, { [weak self] in
                self?.debugTileToOpen(text: wantsText, nextIsText: nextIsText) != nil
            }) { [weak self] in
                guard let self,
                      let (id, order) = debugTileToOpen(text: wantsText, nextIsText: nextIsText)
                else { return }
                print("[qa] \(label): opening \(id.rawValue)")
                debugSelect(id, order: order)
                Self.debugDriveFeed(label: label, pages: nextIsText == nil ? 0 : 1, closes: closes)
            }
        }
    }

    /// The first tile the mode asks for, in the order a section feeds, and
    /// that order.
    private func debugTileToOpen(text: Bool, nextIsText: Bool?) -> (PostID, [PostID])? {
        guard let galleryPost else { return nil }
        for section in sections {
            let order = section.kind.isRow ? section.all : section.ids
            for (index, id) in order.enumerated() {
                guard section.ids.contains(id),
                      let post = galleryPost(id), (post.kind == .text) == text,
                      tiles.first(where: { $0.postID == id })?.isLoaded == true,
                      debugTileIsOnScreen(id)
                else { continue }
                if let nextIsText {
                    guard order.indices.contains(index + 1),
                          let next = galleryPost(order[index + 1]),
                          (next.kind == .text) == nextIsText
                    else { continue }
                }
                return (id, order)
            }
        }
        return nil
    }

    /// Asked of the origin a tap would build, so "on screen" means what the
    /// flight will measure.
    private func debugTileIsOnScreen(_ id: PostID) -> Bool {
        guard let tile = tiles.first(where: { $0.postID == id }), let post = galleryPost?(id) else {
            return false
        }
        return heroOrigin(for: tile, post: post, stream: [], source: .sheet).frame(view) != nil
    }

    /// Pages the opened feed `pages` times once it has landed, then closes it
    /// with the chevron when asked to.
    private static func debugDriveFeed(label: String, pages: Int, closes: Bool) {
        func feed() -> SnapFeedViewController? {
            guard let nav = debugFeedHost?.navigationController, nav.transitionCoordinator == nil else {
                return nil
            }
            return nav.topViewController as? SnapFeedViewController
        }
        QAWait.until("\(label) landed", { feed() != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if pages > 0 {
                    print("[qa] \(label): paging \(pages)")
                    feed()?.debugFlingPages(pages)
                }
                guard closes else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + (pages > 0 ? 2.5 : 1.0)) {
                    QAWait.until("\(label) close", { feed() != nil }) {
                        print("[qa] \(label): closing")
                        feed()?.navigationController?.popViewController(animated: true)
                    }
                }
            }
        }
    }
}
#endif
