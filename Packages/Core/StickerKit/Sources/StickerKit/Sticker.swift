import Foundation

/// One animated dotLottie sticker bundled with the app, plus the emoji it
/// stands for.
///
/// The emoji is not decoration. In Chat it is what a tap actually inserts:
/// `chat.v1` `SendMessage` carries a text body and nothing else (no sticker id,
/// no media ref), so a sticker cannot travel the wire as itself. The twelve
/// bundled stickers are all animated renderings of standard emoji, which gives
/// an honest mapping — and a stand-in to draw while the animation loads.
public struct Sticker: Hashable, Sendable, Identifiable {
    /// Resource name inside `Resources/Stickers`, without the extension. Also
    /// what `FrameOverlay.Content.sticker(id:)` stores.
    public let id: String
    /// The emoji the sticker animates.
    public let emoji: String
    /// Spoken name, for VoiceOver.
    public let label: String

    public init(id: String, emoji: String, label: String) {
        self.id = id
        self.emoji = emoji
        self.label = label
    }
}
