import MediaPlayback
import UIKit

/// How each transition is shown to the author: the symbol on its card and on
/// the cut that carries it, and the word under it.
///
/// ⚠️ **ONE PLACE, BECAUSE THREE VIEWS DRAW THE SAME CHOICE.** The row's card
/// offers a kind, and the disc on a cut and the held cap standing on it state
/// it; a symbol spelled twice is a cut that shows a different picture from the
/// card that set it.
extension VideoTransitionKind {
    /// The SF Symbol drawn for this kind.
    var glyph: String {
        switch self {
        case .dipToBlack: "moon.fill"
        case .dipToWhite: "sun.max.fill"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// The word on the card.
    var label: String {
        switch self {
        case .dipToBlack: "Black"
        case .dipToWhite: "White"
        case .zoom: "Zoom"
        }
    }

    /// What VoiceOver says for it.
    var spokenLabel: String {
        switch self {
        case .dipToBlack: "Fade through black"
        case .dipToWhite: "Fade through white"
        case .zoom: "Zoom"
        }
    }
}

/// The symbols that belong to no kind.
enum MediaTransitionCatalog {
    /// A cut with nothing on it yet.
    static let addGlyph = "plus"
    /// The card that takes a transition away.
    static let noneGlyph = "circle.slash"
    /// The button that leaves the transitions.
    static let closeGlyph = "xmark"
    /// The word on the card that takes a transition away.
    static let noneLabel = "None"

    /// Every choice the row offers, in order: nothing first.
    static let choices: [VideoTransitionKind?] = [nil] + VideoTransitionKind.allCases.map { $0 }

    static func glyph(for kind: VideoTransitionKind?) -> String { kind?.glyph ?? noneGlyph }
    /// The symbol a CUT shows — on its disc or on a held cap: `+` while it
    /// carries nothing, where a card says "None".
    static func markGlyph(for kind: VideoTransitionKind?) -> String { kind?.glyph ?? addGlyph }
    static func label(for kind: VideoTransitionKind?) -> String { kind?.label ?? noneLabel }
}

#if DEBUG
extension MediaTransitionCatalog {
    /// Internal for tests: which mark symbol `image` draws — read off the image
    /// itself (`symbol(system: plus) …`), never off the state that asked for it.
    static func debugSymbol(drawnIn image: UIImage?) -> String? {
        let names = VideoTransitionKind.allCases.map(\.glyph) + [addGlyph]
        let drawn = image?.description ?? ""
        return names.first { drawn.contains("system: \($0))") }
    }
}
#endif
