import Foundation
import MediaCore

/// The seed set (#971): the most used emotes, baked ahead of time and shipped
/// in the bundle, so their first frame never waits on a bake, a disk cache
/// iOS may have purged, or anything else outside the app.
///
/// ## The choice
///
/// The first twenty emotes of `Noto/manifest.json`, whose order is Unicode's
/// emoji frequency ranking: 😂 ❤️ 🤣 👍 😭 🙏 😘 🥰 😍 😊 🎉 😁 💕 🥺 😅 🔥 ☺️ ♥️
/// 🙄 😆. One loop each, at the 64 px bucket only: body text at 3x, a comment
/// and every picker and strip tile (`EmoteTileView.pixelSide`) draw at 64, so
/// one bucket covers nearly every place an emote first appears. Other buckets
/// and Reduce Motion stills bake as before.
///
/// ## The cost
///
/// Each seed is in the file format a disk hit reads (`EmoteSheetFile`: the
/// cut, then the picture), written by the engine's own bake, with the PNG
/// re-encoded as LOSSLESS WebP (`Scripts/compress-emote-seeds.py`): the same
/// pixels for half the bytes, read by the same decoder. About 1.8 MB in the
/// bundle for the twenty (`EmoteSeedTests.bundleBudget`), next to the 1.6 MB
/// of the Noto subset itself. Decoded, they cost memory only once shown, like
/// any baked sheet.
///
/// ⚠️ **REGENERATE WHEN THE BAKE CHANGES.** A seed carries its own cut, so an
/// old one still plays correctly, but it is the old bake. `EmoteSeedTests`
/// fails when a seed's grid no longer matches `EmoteBakePlan`; regenerate the
/// set with `EmoteSeedGenerator` (its comment gives the commands).
struct EmoteSeeds: Sendable {
    /// The one bucket seeds are baked at.
    static let side = 64
    static let subdirectory = "Seeds"
    static let fileExtension = "emotesheet"

    /// The seeded emotes, most used first.
    static let ids: [String] = [
        "noto:1f602", "noto:2764_fe0f", "noto:1f923", "noto:1f44d", "noto:1f62d",
        "noto:1f64f", "noto:1f618", "noto:1f970", "noto:1f60d", "noto:1f60a",
        "noto:1f389", "noto:1f601", "noto:1f495", "noto:1f97a", "noto:1f605",
        "noto:1f525", "noto:263a_fe0f", "noto:2665_fe0f", "noto:1f644", "noto:1f606"
    ]

    /// The set this package ships.
    static let bundled = EmoteSeeds(bundle: EmoteCatalog.resources)

    let bundle: Bundle

    /// The seed's file name, without its extension.
    static func resourceName(emoteID: String) -> String {
        EmoteDiskCache.fileStem(emoteID: emoteID, side: side, still: false)
            .replacingOccurrences(of: "@", with: "-")
    }

    private static let seeded = Set(ids)

    /// Whether `emote` at this size and motion is seeded. Cheap: no I/O.
    func covers(_ emote: Emote, pixelSide: Int, motion: EmoteEngine.Motion) -> Bool {
        pixelSide == Self.side && motion == .loop && Self.seeded.contains(emote.id)
    }

    /// The seed's bytes, or nil when `emote` at this size and motion has none.
    func data(for emote: Emote, pixelSide: Int, motion: EmoteEngine.Motion) -> Data? {
        guard covers(emote, pixelSide: pixelSide, motion: motion) else { return nil }
        guard let url = bundle.url(
            forResource: Self.resourceName(emoteID: emote.id), withExtension: Self.fileExtension,
            subdirectory: Self.subdirectory
        ) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// The seed decoded, ready to install. Call it off the main thread.
    func art(for emote: Emote, pixelSide: Int, motion: EmoteEngine.Motion) -> AnimatedIconArt? {
        data(for: emote, pixelSide: pixelSide, motion: motion).flatMap(EmoteSheetFile.art(from:))
    }
}
