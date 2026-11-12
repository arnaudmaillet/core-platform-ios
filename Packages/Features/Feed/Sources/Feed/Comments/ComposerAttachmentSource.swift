import UIKit

/// Something the reader can attach from the composer's input row (#2305): an
/// entry in the ORDERED LIST a host declares in its composer contract
/// (`ComposerConfiguration.attachments`, #2308), never a kind of media the
/// composer knows.
///
/// A conversation declares `[camera, library]`; a post's comments declare
/// none (#2310 is on hold). The composer draws every entry's glyph in ONE
/// glass capsule (#2344), in the list's order, between the field and its
/// own bubble, and folds it into the own bubble while the reader writes. What a tap does — open the camera, the
/// library, later a GIF picker — is the host's: the composer only calls
/// `action`, and never uploads anything itself. A new source is one more
/// entry, with no change to the composer.
struct ComposerAttachmentSource {
    /// Stable, by function ("conversation.camera"): the bubble's
    /// accessibility identifier, and what tells a list that only changed its
    /// actions from one that changed its entries.
    let id: String
    /// The SF Symbol the bubble wears.
    let symbol: String
    /// What VoiceOver says ("Camera").
    let accessibilityLabel: String
    /// The tap: the host's.
    let action: @MainActor () -> Void
}
