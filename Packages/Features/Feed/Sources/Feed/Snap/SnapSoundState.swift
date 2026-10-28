import CoreModels
import DesignSystem
import FeedInterface
import Foundation

/// The page's sound, without the screen: which sound a post is set to, what
/// its attribution and its sound bubble draw, whether its song may be heard,
/// whether the record turns, and what the sound sheet opens with.
///
/// The session's mute is `FeedSound`'s and Low Power Mode, followed, is
/// `LowPowerMode`'s — both process-wide, so both are READ through
/// injected closures: the screen passes the real ones (the defaults), tests
/// their own, and no test ever forces the shared answer.
///
/// The screen keeps the audible surface and Picture in Picture (the playback
/// pool's wiring), the song player, the spin timer, the sheet's presentation
/// and every redraw.
///
/// Unit-tested without a screen (`SnapSoundStateTests`).
@MainActor
struct SnapSoundState {
    /// What the sound sheet opens with for a page.
    struct SheetInputs: Equatable {
        /// The sound the page is set to.
        var sound: PostSound
        /// The posts set to it, per section — empty when nobody can be asked.
        var rankings: PostSoundRankings
        /// The sound's original post, when known: the provider's answer, or —
        /// with nobody to ask — the page itself for a clip's own sound.
        var original: PostID?
        var authorHandle: String
        /// An original sound stands for the post it came from; a named song
        /// with no artwork keeps the sheet's neutral note rather than
        /// borrowing somebody's photo.
        var fallbackArtworkURL: URL?
        /// Only a sound the device HOLDS can go under a new clip: the editor
        /// lays it from a file. A clip's own sound streamed from the fleet is
        /// not one yet, and the button is not offered for it.
        var offersUseSound: Bool
    }

    /// See `FeedFeatureBuilder.soundProvider`.
    let provider: (any PostSoundProviding)?
    private let readsSoundOn: @MainActor () -> Bool
    private let flipsSound: @MainActor () -> Void
    private let readsLowPowerMode: @MainActor () -> Bool

    init(
        provider: (any PostSoundProviding)?,
        isOn: @escaping @MainActor () -> Bool = { FeedSound.isOn },
        toggle: @escaping @MainActor () -> Void = { FeedSound.toggle() },
        lowPowerMode: @escaping @MainActor () -> Bool = { LowPowerMode.savesBattery }
    ) {
        self.provider = provider
        self.readsSoundOn = isOn
        self.flipsSound = toggle
        self.readsLowPowerMode = lowPowerMode
    }

    // MARK: - Mute

    /// Whether the feed is heard (`FeedSound`).
    var isOn: Bool { readsSoundOn() }

    /// The bubble's hold, and the composer slot's: mutes, or unmutes.
    func toggle() { flipsSound() }

    // MARK: - Which sound

    /// A carousel: a post of several pages (#1849). Its pages are its media;
    /// its sound is the POST's, one track across every page, and its clips
    /// play muted.
    static func isCarousel(_ model: FeedItemDisplayModel) -> Bool {
        !model.extraMedia.isEmpty
    }

    /// A post made of one clip: it is heard with that clip's own audio, from
    /// the clip's player.
    static func isSingleClip(_ model: FeedItemDisplayModel) -> Bool {
        model.mediaKind == .video && model.mediaURL != nil && !isCarousel(model)
    }

    /// The sound `model` is set to — ONE per post, whatever page is on screen
    /// (#1849): the provider's answer, or — with nobody to ask — a single
    /// clip's own "original sound", played from the clip itself when a player
    /// can open it. A carousel never takes a sound from one of its media.
    func sound(for model: FeedItemDisplayModel) -> PostSound? {
        if let known = provider?.sound(forPost: model.id) { return known }
        guard Self.isSingleClip(model), let url = model.mediaURL else { return nil }
        let playable = url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        return PostSound(
            id: "original-\(model.id.rawValue)", title: nil, artist: nil,
            previewURL: playable ? url : nil, artworkURL: model.thumbnailURL, duration: nil
        )
    }

    /// Whether a clip of `model` is heard through its own player: a single
    /// clip only. A carousel's clips are muted: the post's track is its only
    /// sound (#1849).
    static func clipIsHeard(in model: FeedItemDisplayModel) -> Bool {
        !isCarousel(model)
    }

    // MARK: - What it draws

    /// The attribution's second line: the track, or the author's original
    /// sound. Nil for a post with nothing to hear.
    static func line(for sound: PostSound?, of model: FeedItemDisplayModel) -> String? {
        guard let sound else { return nil }
        guard let title = sound.title else {
            return "Original sound · \(sound.artist ?? "@\(handle(of: model))")"
        }
        return [title, sound.artist].compactMap { $0 }.joined(separator: " · ")
    }

    /// "@handle" off the meta line ("@handle · 3m"), the author's name
    /// otherwise.
    static func handle(of model: FeedItemDisplayModel) -> String {
        let first = model.metaText.components(separatedBy: " · ").first ?? ""
        return first.hasPrefix("@") ? String(first.dropFirst()) : model.authorName
    }

    /// The cover that is the SOUND's — its artwork, a note for a song that has
    /// none, and the post's own picture only for a sound with neither.
    static func cover(for sound: PostSound?) -> SnapMediaAttributionView.Cover {
        switch (sound?.artworkURL, sound?.isOriginal) {
        case (let artwork?, _): .artwork(artwork)
        case (nil, false): .note
        default: .post
        }
    }

    /// What the attribution draws for `model`: the sound's line, and its cover.
    func attribution(
        for model: FeedItemDisplayModel
    ) -> (sound: SnapMediaAttributionView.SoundCredit, cover: SnapMediaAttributionView.Cover) {
        let postSound = sound(for: model)
        return (Self.line(for: postSound, of: model).map { .sound($0) } ?? .none, Self.cover(for: postSound))
    }

    /// What the sound bubble and the composer's rail slot draw for `model`
    /// (#671): the sound's cover and the mute state — and for a MEDIA post
    /// with no sound, a greyed `music.note.slash` that keeps the slot (#683).
    ///
    /// ⚠️ NIL FOR A TEXT POST WITH NO SOUND (#1790, the owner 2026-10-27):
    /// such a post can have no sound at all, so the slot would carry nothing.
    /// No slot, no bubble: the comment field widens into its place.
    func face(for model: FeedItemDisplayModel) -> SnapSoundFace? {
        let postSound = sound(for: model)
        guard Self.hasSoundSlot(isText: Self.isText(model), sound: postSound) else { return nil }
        return SnapSoundFace(
            coverURL: SnapMediaAttributionView.coverURL(for: model, cover: Self.cover(for: postSound)),
            isAvailable: postSound != nil,
            isMuted: !isOn
        )
    }

    /// Whether a post keeps a sound slot (#1790): every media post does
    /// (greyed with no sound, #683); a text post only with a sound. Pure.
    static func hasSoundSlot(isText: Bool, sound: PostSound?) -> Bool {
        !isText || sound != nil
    }

    /// A text post: no picture, no clip — the page draws it as a card.
    static func isText(_ model: FeedItemDisplayModel) -> Bool {
        model.mediaURL == nil && model.extraMedia.isEmpty
    }

    // MARK: - What is heard

    /// The track the feed's song player plays for `model` — the post's sound
    /// heard OUTSIDE a clip's own player — or nil.
    /// - **A carousel** (#1849): the post's sound, on every page, pictures and
    ///   clips alike, whenever the feed is heard. ⚠️ Low Power Mode, followed,
    ///   does NOT silence it (the owner, 2026-10-28): it is the post's sound,
    ///   as a clip's own is, and only the feed's mute stops it.
    /// - **A single clip**: nil. Its sound is its own player's.
    /// - **A photograph, a text post**: its song, and ⚠️ NOTHING IN LOW POWER
    ///   MODE, FOLLOWED (#580, #1808): a clip there does not start on its own,
    ///   and a photograph's song is the same thing without a picture.
    func song(for model: FeedItemDisplayModel) -> URL? {
        if Self.isCarousel(model) {
            return isOn ? sound(for: model)?.previewURL : nil
        }
        guard Self.pageSongPlays(soundOn: isOn, lowPowerMode: readsLowPowerMode()),
              model.mediaKind != .video
        else { return nil }
        return sound(for: model)?.previewURL
    }

    /// Whether a page's song may be heard at all: the feed's sound on, and
    /// Low Power Mode not followed (#580, #1808).
    static func pageSongPlays(soundOn: Bool, lowPowerMode: Bool) -> Bool {
        soundOn && !lowPowerMode
    }

    // MARK: - The sound sheet

    /// What the sound sheet opens with for `model`; nil for a page with
    /// nothing to hear.
    ///
    /// The sheet lists EVERY post set to this sound, not only this feed's
    /// (`SoundSheetSections`): popular — only when the provider gives the
    /// sound one; the sound's original post first when it is a media
    /// post, then the page it was opened from — then recent: every post
    /// the popular row does not show, newest first.
    func sheetInputs(for model: FeedItemDisplayModel) -> SheetInputs? {
        guard let postSound = sound(for: model) else { return nil }
        let ranked = provider?.rankings(using: postSound) ?? .empty
        // With nobody to ask, a single clip's own sound (`sound(for:)`) is
        // this page's: it is its own original.
        let original = provider?.originalPostID(of: postSound)
            ?? (postSound.id == "original-\(model.id.rawValue)" ? model.id : nil)
        return SheetInputs(
            sound: postSound,
            rankings: ranked,
            original: original,
            authorHandle: Self.handle(of: model),
            fallbackArtworkURL: postSound.isOriginal ? (model.thumbnailURL ?? model.avatarURL) : nil,
            offersUseSound: postSound.previewURL?.isFileURL == true
        )
    }
}
