import Foundation

/// The ordered selection behind the grid's numbers and the tray's thumbnails.
///
/// A value type with no UIKit in it, because the part worth testing — what the
/// numbering does when an item in the middle is dropped, and what happens at the
/// cap — should not need a window, a collection view or a photo library to ask.
struct MediaPickerSelection: Equatable {
    /// Twenty, a product decision rather than a contract limit: `post.v1`
    /// carries an array of attachments and a `carousel` kind, and since
    /// 2026-09-12 `PostComposing.publish(media:caption:as:)` takes `[ComposeMedia]`
    /// and uploads them in order, so a full selection reaches the wire.
    ///
    /// ⚠️ One gap remains and it is the library seam's, not this cap's:
    /// `MediaLibraryReading` vends images only, so a chosen VIDEO has nothing to
    /// upload. The new-post screen marks them and says so rather than dropping
    /// them silently.
    static let limit = 20

    private(set) var ids: [String] = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    var isFull: Bool { ids.count >= Self.limit }

    /// 1-based — the number the grid stamps on a chosen cell. Nil when the item
    /// is not chosen.
    func order(of id: String) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// What a tap on a cell did, so the screen knows whether to say anything.
    enum Outcome: Equatable {
        case added(order: Int)
        case removed
        /// The cap refused it, and nothing changed.
        case refused
    }

    @discardableResult
    mutating func toggle(_ id: String) -> Outcome {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            return .removed
        }
        guard !isFull else { return .refused }
        ids.append(id)
        return .added(order: ids.count)
    }

    mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
    }

    /// Takes the order a finished drag left the tray in.
    ///
    /// ⚠️ A PERMUTATION OR NOTHING. The tray reports the order it now shows, and
    /// a report that has lost, gained or duplicated an item is a bug upstream —
    /// applying it would silently drop a chosen photo from a selection the
    /// viewer can still see on screen. Refusing leaves the model as it was, and
    /// the tray is re-rendered from it.
    @discardableResult
    mutating func setOrder(_ newOrder: [String]) -> Bool {
        guard newOrder.count == ids.count, Set(newOrder) == Set(ids) else { return false }
        ids = newOrder
        return true
    }
}
