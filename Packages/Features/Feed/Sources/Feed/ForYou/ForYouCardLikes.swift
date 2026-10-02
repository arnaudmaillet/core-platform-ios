import Foundation

/// EXPERIMENT (2026-10-02): a LIKE on For You's compact cards — the paired
/// half-width cards and the chunk tiles of the Discover list, the tiles of the
/// pushed Discover gallery, and the Following row's TEXT cards. The list's
/// full cards always had theirs, in their closing line; these had none.
///
/// The like is the app's stake (likes and points are one thing): a tap
/// stakes `WalletStore.Policy.defaultStakeAmount`, a hold raises `StakeMenu`
/// (the ×100 cartridges, the Shop's door), the heart turns red once the viewer
/// has staked. It is the list card's own machinery — `PostCardStaking` for the
/// wallet, `ActionAffordance` for the press — drawn by `PostStakeChipView`.
///
/// **Where it sits: the card's bottom-right, at the end of its lowest line.**
/// A tile has no words, so the heart is its corner — exactly where its likes
/// count has always been, in the same ink, now pressable. A Following card
/// (paired or text) closes its author line with it: on a text card that line
/// IS the foot, so the heart is in the same corner as a tile's; on a picture
/// the author line sits above the caption's two lines, and the heart with it
/// — the caption keeps the card's full width rather than wrapping around a
/// control (see the PR that added this for the alternatives).
///
/// Off by default: without the launch argument no compact card has a like.
enum ForYouCardLikes {
    /// The launch argument that turns the experiment on.
    static let launchArgument = "-foryou-card-likes"

    /// Whether `arguments` ask for the experiment. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for it — what For You builds its surfaces
    /// with.
    static var isEnabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }
}
