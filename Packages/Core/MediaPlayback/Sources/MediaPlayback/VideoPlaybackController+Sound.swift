extension VideoPlaybackController {
    /// Lets the clip in `view` be heard, or silences it again.
    ///
    /// ⚠️ **EVERY PLAYER IS MUTED TODAY, UNDER AN `.ambient` SESSION** —
    /// `bindFresh` mutes whatever it binds — so a song laid under an edit could
    /// never be heard in the preview without this.
    ///
    /// ⚠️ **A STUB THAT CHANGES NOTHING AND RETURNS FALSE.** The soundtrack slice
    /// (S11) fills it: the choice remembered per surface so a swapped item keeps
    /// it. Returns whether a player took it.
    @discardableResult
    public func setMuted(_ muted: Bool, in view: VideoRenderView) -> Bool {
        false
    }

    /// Sets the song's level and the film's own, live, on the arrangement
    /// playing in `view` — both 0...1.
    ///
    /// ⚠️ **A STUB THAT CHANGES NOTHING AND RETURNS FALSE.** The soundtrack slice
    /// (S11) fills it: the item's `audioMix` replaced with constant levels on the
    /// track IDs its arrangement was built with. Returns whether an arrangement
    /// took the levels.
    @discardableResult
    public func setMixLevels(music: Double, original: Double, in view: VideoRenderView) -> Bool {
        false
    }
}
