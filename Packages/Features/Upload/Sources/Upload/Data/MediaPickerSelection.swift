import Foundation

/// The ordered selection behind the grid's numbers and the tray's thumbnails.
///
/// A value type with no UIKit in it, because the part worth testing — what the
/// numbering does when an item in the middle is dropped, and what happens at the
/// cap — should not need a window, a collection view or a photo library to ask.
struct MediaPickerSelection: Equatable {
    /// ⚠️ TWENTY HERE, AND THE PUBLISH PIPELINE STILL TAKES ONE.
    /// `post.v1` already carries an array of attachments and a `carousel` kind,
    /// so the cap is a product decision rather than a contract limit — but
    /// `PostComposing.publish(media:caption:as:)` accepts a single
    /// `ComposeMedia`, so the screen AFTER this one cannot yet carry a
    /// selection of twenty off the device. Raising that is its own piece of
    /// work; this screen is allowed to run ahead of it.
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
