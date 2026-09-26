import AVFoundation

extension VideoPlaybackController {
    /// What a player's current arrangement laid for its sound.
    ///
    /// ⚠️ **TIED TO THE ITEM, WEAKLY, NOT ONLY TO THE PLAYER.** The same player
    /// shows the file as shot while a trim handle is held (`showAsShot`), and
    /// that item has no song; a mix naming the song's track would be handed to
    /// an item that does not have it. The binding answers only while the item
    /// it was made for is the one playing.
    struct SoundBinding {
        weak var item: AVPlayerItem?
        let layout: VideoExporter.SoundtrackLayout
    }

    /// Lets the clip in `view` be heard, or silences it again. Returns whether
    /// a player took it.
    ///
    /// ⚠️ **EVERY PLAYER IS MUTED WHEN IT IS BOUND, UNDER AN `.ambient`
    /// SESSION** — `bindFresh` mutes whatever it binds — so a song laid under an
    /// edit could never be heard without this. A swapped item keeps the
    /// player's choice; a fresh bind starts silent again.
    ///
    /// ⚠️ **AND THE SESSION IS `.playback` WHILE ANY PLAYER HERE IS HEARD.** An
    /// `.ambient` session is silenced by the ring switch, so an author with the
    /// phone on silent would pick a song and hear nothing, with nothing on
    /// screen to say why. It goes back to `.ambient` — the category this
    /// controller sets for the whole app — when the last heard player is
    /// silenced or given back.
    @discardableResult
    public func setMuted(_ muted: Bool, in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        player.isMuted = muted
        let key = ObjectIdentifier(player)
        if muted {
            audiblePlayers.remove(key)
        } else {
            audiblePlayers.insert(key)
        }
        settleAudioSession()
        return true
    }

    /// Makes whatever plays in `view` the one clip the viewer hears, and
    /// silences the one heard before; nil silences it and hears nothing.
    ///
    /// A SURFACE, not a player, because the feed knows which page owns the
    /// screen and never which player is behind it: players are lent, parked,
    /// joined and handed between surfaces, and a fresh bind starts muted.
    /// Whatever arrives in `view` later is made audible as it is bound.
    ///
    /// ⚠️ **UNDER THE APP'S `.ambient` SESSION, ON PURPOSE.** Unlike
    /// `setMuted`, this never switches the session to `.playback`: a feed that
    /// starts talking on its own respects the ring switch and mixes with the
    /// music the viewer already has on. `setMuted` is for sound somebody asked
    /// for — an author auditioning the song they just picked.
    public func setAudibleSurface(_ view: VideoRenderView?) {
        audibleSurface = view
        refreshAudibleSurface()
    }

    /// The surface `setAudibleSurface` last named, if it is still alive.
    public var currentAudibleSurface: VideoRenderView? { audibleSurface }

    /// Re-applies the audible surface to the player behind it now. Called by
    /// `setAudibleSurface` and by every bind to that surface.
    func refreshAudibleSurface() {
        let target = audibleSurface.flatMap { watchedPlayer(in: $0) }
        // The one heard before goes quiet — unless somebody asked for it by
        // name (`setMuted`), which this does not get to overrule.
        if let previous = surfaceHeardPlayer, previous !== target,
           !audiblePlayers.contains(ObjectIdentifier(previous)) {
            previous.isMuted = true
        }
        target?.isMuted = false
        surfaceHeardPlayer = target
    }

    /// Whether the clip in `view` is silenced; nil when nothing is bound.
    public func isMuted(in view: VideoRenderView) -> Bool? {
        watchedPlayer(in: view)?.isMuted
    }

    /// Whether the item playing in `view` carries a song.
    public func carriesSoundtrack(in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        return binding(for: player) != nil
    }

    /// Sets the song's level and the film's own, live, on the arrangement
    /// playing in `view` — both 0...1. Returns whether an arrangement took them:
    /// false when nothing is bound, or the item carries no song.
    ///
    /// ⚠️ **THE ITEM'S `audioMix` IS REPLACED, NOT EDITED.** An item copies the
    /// mix it is given, so the only way to change a level is a new mix — built
    /// from the same layout the arrangement was, so the film's dips come back at
    /// the new level, and with constant levels only.
    @discardableResult
    public func setMixLevels(music: Double, original: Double, in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view), let item = player.currentItem,
              let layout = binding(for: player)
        else { return false }
        item.audioMix = layout.mix(music: music, original: original)
        return true
    }

    /// Records what `player`'s new item laid for its sound — nil when it laid
    /// no song. Called by `load` once the item is in.
    func adoptSound(_ layout: VideoExporter.SoundtrackLayout?, on player: AVPlayer) {
        let key = ObjectIdentifier(player)
        guard let layout, let item = player.currentItem else {
            soundBindings.removeValue(forKey: key)
            return
        }
        soundBindings[key] = SoundBinding(item: item, layout: layout)
    }

    /// Forgets everything about `player`'s sound, and silences it. Called by
    /// `retire`: a pooled player is lent to the next clip muted, and a player
    /// given back is no longer a reason for the session to play through the
    /// ring switch.
    func forgetSound(of player: AVPlayer) {
        let key = ObjectIdentifier(player)
        soundBindings.removeValue(forKey: key)
        player.isMuted = true
        if surfaceHeardPlayer === player { surfaceHeardPlayer = nil }
        if audiblePlayers.remove(key) != nil {
            settleAudioSession()
        }
    }

    private func binding(for player: AVPlayer) -> VideoExporter.SoundtrackLayout? {
        guard let bound = soundBindings[ObjectIdentifier(player)], let item = bound.item,
              item === player.currentItem
        else { return nil }
        return bound.layout
    }

    private func settleAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let wanted: AVAudioSession.Category = audiblePlayers.isEmpty ? .ambient : .playback
        guard session.category != wanted else { return }
        try? session.setCategory(wanted, mode: .moviePlayback)
    }
}
