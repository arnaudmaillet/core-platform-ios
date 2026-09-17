import AVFoundation

extension VideoExporter {
    /// Lays `soundtrack` under an arranged film, and returns the mix that
    /// replaces the film's own — or nil to keep it.
    ///
    /// ⚠️ **CALLED AFTER EVERY COMPOSITION-LEVEL `scaleTimeRange`.** That call
    /// rescales every track inside its range, so a song inserted before a rated
    /// piece is scaled would play at that piece's rate for its length.
    ///
    /// ⚠️ **A STUB THAT LAYS NOTHING AND RETURNS NIL.** The soundtrack slice (S11)
    /// fills it: the song inserted over `[0, composition.duration]` from
    /// `startSeconds`, clipped to the song; one constant volume for the song and
    /// one for `original`, whose `dips` are rebuilt from that level down to
    /// silence and back — constant levels only, per `export-volume-ramp-hang`.
    static func applySoundtrack(
        _ soundtrack: VideoSoundtrack?, to composition: AVMutableComposition,
        original: AVMutableCompositionTrack?, dips: [SoundDip]
    ) async throws -> AVAudioMix? {
        nil
    }
}
