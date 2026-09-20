import AVFoundation

extension VideoExporter {
    /// Where an arrangement's sound lives: the song's track, the film's own —
    /// one track per lane — and how the film's sound crosses its transitions.
    ///
    /// ⚠️ **A VALUE KEPT BESIDE A PLAYING ITEM, SO ITS LEVELS CAN MOVE WITHOUT A
    /// NEW ITEM.** A slider dragged across the song's level would otherwise
    /// rebuild the player sixty times a second; `mix(music:original:)` is all a
    /// new level costs, and `VideoPlaybackController.setMixLevels` hands that to
    /// the item as it plays.
    struct SoundtrackLayout: Sendable, Equatable {
        /// The track the song is laid on.
        let music: CMPersistentTrackID
        /// The film's own sound, a track per lane — empty for a clip that has
        /// none.
        let originals: [CMPersistentTrackID]
        /// How the film's own sound crosses its transitions (`soundSteps`).
        let steps: [SoundStep]

        /// The song at `musicLevel` and the film at `originalLevel`, both 0...1.
        ///
        /// ⚠️ **CONSTANT LEVELS — THE SONG HAS NO RAMP AT ALL.** A volume ramp at
        /// the start of a piece played at 3x or 4x has frozen
        /// `AVAssetExportSession` for good (memory `export-volume-ramp-hang`),
        /// and a song runs under every piece. One level set at zero is the whole
        /// of its automation.
        ///
        /// ⚠️ **THE FILM'S CROSSINGS ARE REBUILT AT ITS OWN LEVEL**, between that
        /// level and silence, rather than from full volume: a film turned down to
        /// half under a song would otherwise jump to full at every transition.
        /// They are the steps `soundSteps` already chose, which never touch a
        /// rated piece.
        func mix(music musicLevel: Double, original originalLevel: Double) -> AVAudioMix {
            let song = AVMutableAudioMixInputParameters()
            song.trackID = music
            song.setVolume(Self.level(musicLevel), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [song] + SoundStep.parameters(
                steps, tracks: originals, level: Self.level(originalLevel), stated: true
            )
            return mix
        }

        private static func level(_ value: Double) -> Float {
            value.isFinite ? Float(min(max(value, 0), 1)) : 1
        }
    }
}

extension VideoExporter.SoundStep {
    /// The film's lanes `tracks` following `steps`, at `level`.
    ///
    /// ⚠️ **`stated` SETS THE LEVEL AT ZERO — NOT WHERE A STEP IS ALREADY SET.** A
    /// ramp or a level and another level at the same instant are two answers
    /// for one moment. Before its first setting a track plays at full volume,
    /// so a mix under a song states the film's level on every lane at zero.
    static func parameters(
        _ steps: [Self], tracks: [CMPersistentTrackID], level: Float, stated: Bool
    ) -> [AVMutableAudioMixInputParameters] {
        tracks.map { track in
            let film = AVMutableAudioMixInputParameters()
            film.trackID = track
            let own = steps.filter { $0.track == track }
            let setAtZero = own.contains {
                switch $0.shape {
                case let .ramp(_, _, range): range.start == .zero
                case let .level(_, at): at == .zero
                }
            }
            if stated, !setAtZero { film.setVolume(level, at: .zero) }
            for step in own {
                switch step.shape {
                case let .ramp(from, to, range):
                    film.setVolumeRamp(fromStartVolume: from * level, toEndVolume: to * level, timeRange: range)
                case let .level(value, at):
                    film.setVolume(value * level, at: at)
                }
            }
            return film
        }
    }
}

extension VideoExporter {
    /// A song laid into a composition, and the mix it plays with.
    ///
    /// ⚠️ **NOT SENDABLE, LIKE THE ARRANGEMENT IT ENDS UP IN** —
    /// `AVMutableAudioMix` is `@_nonSendable`.
    struct LaidSoundtrack {
        let layout: SoundtrackLayout
        let mix: AVAudioMix
    }

    /// Lays `soundtrack` under an arranged film, and returns what it laid with
    /// the mix that replaces the film's own — or nil when there is no song.
    ///
    /// ⚠️ **CALLED ONCE THE PIECES ARE LAID AND SCALED.** The song runs the
    /// result's whole length, which is only known once every overlap has been
    /// taken off it — and a song laid before a rated piece was scaled would, if
    /// that scaling ever reached it, play at that piece's rate for its length.
    ///
    /// ⚠️ **FROM `startSeconds`, OVER THE WHOLE FILM, CLIPPED TO THE SONG.** A
    /// song shorter than what is left of the film stops where it ends — no loop
    /// in version 1 — and the film plays on under silence.
    ///
    /// ⚠️ **A SONG THAT CANNOT BE READ FAILS THE ARRANGEMENT.** It was checked
    /// when it was chosen (`VideoSoundtrack.vet`) and it is an app-owned copy, so
    /// losing it is exceptional — and a post that quietly published without the
    /// song the author chose is the defect this whole plan is written against.
    static func applySoundtrack(
        _ soundtrack: VideoSoundtrack?, to composition: AVMutableComposition,
        originals: [AVMutableCompositionTrack], steps: [SoundStep]
    ) async throws -> LaidSoundtrack? {
        guard let soundtrack else { return nil }
        let song = AVURLAsset(url: soundtrack.fileURL)
        guard let songTrack = try? await song.loadTracks(withMediaType: .audio).first,
              let songRange = try? await songTrack.load(.timeRange), songRange.isValid
        else {
            throw VideoExportError.unreadable
        }
        // ⚠️ A START PAST THE SONG'S LAST SECOND PLAYS THAT LAST SECOND. The
        // excerpt control never stores one, but a start is a number that can
        // outlive the song it was chosen on; an empty music track would leave
        // the export nothing to mix and the author no way to tell why.
        let latest = max(songRange.duration.seconds - VideoSoundtrack.shortestSeconds, 0)
        let requested = soundtrack.startSeconds.isFinite
            ? min(max(soundtrack.startSeconds, 0), latest) : 0
        let start = songRange.start + CMTime(seconds: requested, preferredTimescale: 600)
        let length = CMTimeMinimum(composition.duration, songRange.end - start)
        guard length > .zero else { return nil }
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoExportError.exportFailed
        }
        do {
            try track.insertTimeRange(CMTimeRange(start: start, duration: length), of: songTrack, at: .zero)
        } catch {
            throw VideoExportError.exportFailed
        }
        let layout = SoundtrackLayout(music: track.trackID, originals: originals.map(\.trackID), steps: steps)
        return LaidSoundtrack(
            layout: layout,
            mix: layout.mix(music: soundtrack.musicVolume, original: soundtrack.originalVolume)
        )
    }
}

/// Why a file cannot be laid under a film.
public enum SoundtrackProblem: Error, Equatable, Sendable {
    /// Not a file AVFoundation can open or play.
    case unreadable
    /// Protected content — a song bought with DRM, say.
    case protected
    /// A file with no sound in it: a silent video, a picture.
    case noSound
    /// Less than `VideoSoundtrack.shortestSeconds` of sound.
    case tooShort
}

extension VideoSoundtrack {
    /// The shortest sound worth laying under a film.
    public static let shortestSeconds: Double = 1

    /// Reads `url` and says whether it can be a song: how long its sound runs,
    /// or why it cannot.
    ///
    /// ⚠️ **THE SOUND'S OWN LENGTH, NOT THE FILE'S.** A movie picked for its
    /// sound can carry ten seconds of picture over half a second of audio, and
    /// the song is what gets laid.
    public static func vet(_ url: URL) async -> Result<Double, SoundtrackProblem> {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.isPlayable, .hasProtectedContent) else {
            return .failure(.unreadable)
        }
        let (playable, protected) = loaded
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var seconds = 0.0
        if let track = tracks.first, let range = try? await track.load(.timeRange), range.isValid {
            seconds = range.duration.seconds
        }
        if let problem = problem(
            hasSound: !tracks.isEmpty, isPlayable: playable, isProtected: protected, seconds: seconds
        ) {
            return .failure(problem)
        }
        return .success(seconds)
    }

    /// The rule `vet` applies, on its own — protection cannot be manufactured
    /// in a test file.
    static func problem(
        hasSound: Bool, isPlayable: Bool, isProtected: Bool, seconds: Double
    ) -> SoundtrackProblem? {
        if isProtected { return .protected }
        if !isPlayable { return .unreadable }
        if !hasSound { return .noSound }
        if !seconds.isFinite || seconds < shortestSeconds { return .tooShort }
        return nil
    }

    /// Whether two songs lay the same audio: the same file, from the same
    /// second.
    ///
    /// ⚠️ **THE LEVELS ARE LEFT OUT ON PURPOSE.** They change the mix, which a
    /// playing item takes live (`VideoPlaybackController.setMixLevels`); a new
    /// item for a volume would restart the film under the slider that moved it.
    public static func laysTheSameAudio(_ one: VideoSoundtrack?, _ other: VideoSoundtrack?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case let (one?, other?): one.fileURL == other.fileURL && one.startSeconds == other.startSeconds
        default: false
        }
    }
}
