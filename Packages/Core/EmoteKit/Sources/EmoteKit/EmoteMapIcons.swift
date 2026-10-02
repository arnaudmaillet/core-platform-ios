import Foundation
import MediaCore

/// Emotes as the map's icon faces.
///
/// A text post's map marker can wear an animated icon, which it resolves
/// through an `AnimatedIconProviding`. This one answers an EMOTE id (`lol`,
/// `weather`, `noto:1f602`) through `EmoteEngine` — the very art the post's
/// caption animates — and any other id from the baked map catalogue it wraps.
///
/// ⚠️ THE BAKED MAP CATALOGUE IS NOT A SET OF FACES. Beside three real faces it
/// holds sixteen GEOMETRIC PLACEHOLDERS — a star, a hexagon, a plain disc and a
/// plain squircle, made to measure decomposed playback
/// (`Tools/IconBaker/Fixtures/generate.py`). Handed out as posts' faces, every
/// disc and squircle drew an EMPTY DISC on the map, faint under the flicker
/// motion's 55% opacity — Morocco, Poland, Tunisia, Taiwan and Sri Lanka in
/// the mock world, at every zoom. The marker rendered the art exactly as
/// baked; the art was simply not a face. `EmoteCatalog.house` already refused
/// those placeholders as emotes, and `defaultFaceIDs` refuses them as faces.
@MainActor
public final class EmoteMapIcons: AnimatedIconProviding {
    private let engine: EmoteEngine
    /// Answers every id that is not an emote's.
    private let catalogue: AnimatedIconCatalog

    public init(engine: EmoteEngine = .shared, catalogue: AnimatedIconCatalog) {
        self.engine = engine
        self.catalogue = catalogue
    }

    /// The side art is baked at: a map marker's icon face is 44pt, which at 3x
    /// takes the engine's largest bucket.
    public static let pixelSide = EmoteEngine.pixelSide(forPoints: 44, scale: 3)

    public func cached(_ id: String) -> AnimatedIconArt? {
        guard let emote = engine.catalog.emote(id: id) else { return catalogue.cached(id) }
        return engine.cachedArt(for: emote, pixelSide: Self.pixelSide, motion: .loop)
    }

    public func art(for id: String) async throws -> AnimatedIconArt {
        guard let emote = engine.catalog.emote(id: id) else { return try await catalogue.art(for: id) }
        guard let art = await engine.art(for: emote, pixelSide: Self.pixelSide) else {
            throw URLError(.cannotDecodeContentData)
        }
        return art
    }

    // MARK: - Faces

    /// The faces handed out, in turn, to posts whose caption carries no
    /// animated emote: the house faces, then a few of Noto's smileys. Faces,
    /// every one — never a shape that could read as an empty marker.
    public static let defaultFaceIDs: [String] = [
        "lol", "blush", "noto:1f602", "noto:1f60d", "noto:1f973", "noto:1f60e", "noto:1f60b", "noto:1f917"
    ].filter { EmoteCatalog.shared.emote(id: $0) != nil }

    /// The face a post's caption names: the first animated emote it carries —
    /// what the author chose to say ("Pierogi count: lost track at twelve.
    /// :lol:" wears `:lol:`). Nil when it carries none.
    public nonisolated static func faceID(forCaption caption: String, catalog: EmoteCatalog = .shared) -> String? {
        EmoteParser.matches(in: caption, catalog: catalog).first?.emote.id
    }
}
