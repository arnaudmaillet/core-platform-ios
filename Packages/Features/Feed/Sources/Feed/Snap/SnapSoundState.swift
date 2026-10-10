import CoreModels
import DesignSystem
import FeedInterface
import Foundation

/// The page's sound, without the screen: which sound a post is set to, what
/// its attribution and its sound bubble draw, whether its song may be heard,
/// whether the record turns, and what the sound sheet opens with.
///
/// The session's mute is `FeedSound`'s and Power Saving is
/// `PowerSavingPreference`'s — both process-wide, so both are READ through
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
    private let readsPowerSaving: @MainActor () -> Bool

    init(
        provider: (any PostSoundProviding)?,
        isOn: @escaping @MainActor () -> Bool = { FeedSound.isOn },
        toggle: @escaping @MainActor () -> Void = { FeedSound.toggle() },
        powerSaving: @escaping @MainActor () -> Bool = { PowerSavingPreference.isOn }
    ) {
        self.provider = provider
        self.readsSoundOn = isOn
        self.flipsSound = toggle
        self.readsPowerSaving = powerSaving
    }

    // MARK: - Mute

    /// Whether the feed is heard (`FeedSound`).
    var isOn: Bool { readsSoundOn() }

    /// The bubble's hold, and the composer slot's: mutes, or unmutes.
    func toggle() { flipsSound() }

    // MARK: - Which sound

    /// The clip a post's sound belongs to: the one on screen when this is the
    /// active page (a collection's pages are different clips, with different
    /// sounds), else its head, or its first clip page.
    ///
    /// - Parameter playingClip: the clip the active page's cell is showing —
    ///   nil for every other page.
    static func clip(of model: FeedItemDisplayModel, playingClip: URL?) -> URL? {
        if let playingClip { return playingClip }
        if model.mediaKind == .video, let url = model.mediaURL { return url }
        return model.extraMedia.first { $0.videoURL != nil }?.videoURL
    }

    /// The sound `model` is set to: the provider's answer, or — with nobody to
    /// ask — the clip's own "original sound", played from the clip itself
    /// when a player can open it.
    func sound(for model: FeedItemDisplayModel, playingClip: URL?) -> PostSound? {
        let clipURL = Self.clip(of: model, playingClip: playingClip)
        if let known = provider?.sound(forPost: model.id, clip: clipURL) { return known }
        guard let url = clipURL else { return nil }
        let playable = url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        return PostSound(
            id: "original-\(model.id.rawValue)", title: nil, artist: nil,
            previewURL: playable ? url : nil, artworkURL: model.thumbnailURL, duration: nil
        )
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
        for model: FeedItemDisplayModel, playingClip: URL?
    ) -> (sound: SnapMediaAttributionView.SoundCredit, cover: SnapMediaAttributionView.Cover) {
        let postSound = sound(for: model, playingClip: playingClip)
        return (Self.line(for: postSound, of: model).map { .sound($0) } ?? .none, Self.cover(for: postSound))
    }

    /// What the sound bubble and the composer's rail slot draw for `model`
    /// (#671): the sound's cover and the mute state — and for a post with no
    /// sound, media or text, a greyed `music.note.slash` that keeps the slot
    /// (#683).
    func face(for model: FeedItemDisplayModel, playingClip: URL?) -> SnapSoundFace {
        let postSound = sound(for: model, playingClip: playingClip)
        return SnapSoundFace(
            coverURL: SnapMediaAttributionView.coverURL(for: model, cover: Self.cover(for: postSound)),
            isAvailable: postSound != nil,
            isMuted: !isOn
        )
    }

    // MARK: - What is heard

    /// The song of a page with no clip — a photograph, a collection of them,
    /// a text post — when the page may be heard at all; nil for a clip page,
    /// whose sound is the clip's own.
    ///
    /// ⚠️ **NOTHING UNDER POWER SAVING (#580).** A clip under Power Saving
    /// does not start on its own; a photograph's song is the same thing
    /// without a picture, so it is silent too — the viewer's decision.
    func song(for model: FeedItemDisplayModel, playingClip: URL?) -> URL? {
        guard Self.pageSongPlays(soundOn: isOn, powerSaving: readsPowerSaving()),
              !(model.mediaKind == .video || model.extraMedia.contains { $0.videoURL != nil })
        else { return nil }
        return sound(for: model, playingClip: playingClip)?.previewURL
    }

    /// Whether a page's song may be heard at all: the feed's sound on, and
    /// Power Saving off (#580).
    static func pageSongPlays(soundOn: Bool, powerSaving: Bool) -> Bool {
        soundOn && !powerSaving
    }

    /// The sound bubble's record turns while the post plays AUDIBLY: the
    /// player's play and pause, and the mute (#683).
    func isAudible(playing: Bool) -> Bool {
        playing && isOn
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
    func sheetInputs(for model: FeedItemDisplayModel, playingClip: URL?) -> SheetInputs? {
        guard let postSound = sound(for: model, playingClip: playingClip) else { return nil }
        let ranked = provider?.rankings(using: postSound) ?? .empty
        // With nobody to ask, a clip's own sound (`sound(for:)`) is this
        // page's: it is its own original.
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
