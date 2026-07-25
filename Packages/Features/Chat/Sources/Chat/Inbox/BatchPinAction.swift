import CoreModels

/// What the batch pin button should offer for a given multi-selection.
///
/// A single button cannot honestly describe a MIXED selection: "Pin" would
/// silently leave the already-pinned rows alone, and "Unpin" would silently
/// drop pins the viewer never asked to lose. Rather than guess, the button
/// withdraws — Delete stays, and the viewer narrows the selection to say what
/// they mean. Pure so that rule is stated once and tested directly.
enum BatchPinAction: Equatable {
    /// Every selected row is unpinned: pinning them all is unambiguous.
    case pin
    /// Every selected row is pinned: unpinning them all is unambiguous.
    case unpin
    /// Nothing selected, or a mix of pinned and unpinned rows. The button is
    /// not shown at all.
    case unavailable

    var title: String? {
        switch self {
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .unavailable: nil
        }
    }

    static func resolve(
        selected: [ConversationID],
        isPinned: (ConversationID) -> Bool
    ) -> BatchPinAction {
        guard !selected.isEmpty else { return .unavailable }
        let pinnedCount = selected.filter(isPinned).count
        if pinnedCount == 0 { return .pin }
        if pinnedCount == selected.count { return .unpin }
        return .unavailable
    }
}
