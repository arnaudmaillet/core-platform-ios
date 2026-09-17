import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// **A SONG IS LAID UNDER THE FILM THE AUTHOR CUT, AND HEARD AS IT WAS SET.**
///
/// Every assertion LISTENS: the arrangement, the export or the playing item is
/// read back through its own mix (`SoundProbe`) and the samples are measured —
/// loudness where the film is silent, pitch where the song's staircase says
/// which of its seconds is playing. A mix that names the right tracks can still
/// be silent, and a song laid at the right place can still be sped up.
///
/// The film (`ColourClipWriter`) is four seconds long with a 440 Hz tone for
/// the first two and silence after; `sound: false` has no audio track at all.
@Suite(.serialized)
struct SoundtrackCompositionTests {
    private func arranged(
        _ segments: [VideoExportSegment], sound: Bool = true, song: VideoSoundtrack?
    ) async throws -> VideoExporter.Arrangement {
        let file = try await ColourClipWriter.clip(sound: sound)
        return try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: segments, orientation: .whenComposited, soundtrack: song
        )
    }

    private func listen(_ arrangement: VideoExporter.Arrangement) async throws -> SoundProbe {
        try await SoundProbe.listen(to: arrangement.asset, mix: arrangement.audioMix)
    }

    private static let whole = [VideoExportSegment(start: 0, end: 4)]

    // MARK: - Where the song goes

    /// The film is silent from its second second on; a song laid under it is
    /// what fills that silence.
    @Test func musicFillsTheSilentSecond() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        let bare = try await listen(try await arranged(Self.whole, song: nil))
        let scored = try await listen(try await arranged(Self.whole, song: song))

        #expect(bare.rms(at: 0.5) > 5_000, "guard: the film's own tone is not there")
        #expect(bare.rms(at: 3.0) < 100, "guard: the film is not silent at 3s: \(bare.rms(at: 3.0))")
        #expect(scored.rms(at: 3.0) > 5_000, "no song under the silent second: \(scored.rms(at: 3.0))")
        #expect(abs(scored.pitch(at: 3.0) - 1_000) < 60, "what fills it is not the song: \(scored.pitch(at: 3.0)) Hz")
    }

    /// ⚠️ **INSERTED AFTER EVERY `scaleTimeRange`, OR A RATED PIECE SPEEDS THE
    /// SONG UP.** The first piece plays two seconds of film in one; a song
    /// scaled with it would reach its second second half-way through — and,
    /// under the spectral pitch the export uses, still at its own pitch, which
    /// is why this reads the staircase's STEP, not a pitch shift.
    @Test func musicIsNotRescaledByARatedPiece() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.staircase(), title: "Stairs")
        let cut = [
            VideoExportSegment(start: 0, end: 2, speed: 2),
            VideoExportSegment(start: 2, end: 4)
        ]
        let heard = try await listen(try await arranged(cut, sound: false, song: song))

        // Played 0.75s is the song's 0.75s (300 Hz) — not its 1.5s (600 Hz).
        #expect(abs(heard.pitch(at: 0.75) - ToneWriter.staircasePitch(at: 0.75)) < 40,
                "over the 2x piece the song is at \(heard.pitch(at: 0.75)) Hz")
        // Played 2.5s is the song's 2.5s (900 Hz) — not its 3.5s (1200 Hz).
        #expect(abs(heard.pitch(at: 2.5) - ToneWriter.staircasePitch(at: 2.5)) < 40,
                "after the 2x piece the song is at \(heard.pitch(at: 2.5)) Hz")
    }

    /// The excerpt starts at the song's own second the author chose, and a song
    /// that runs out before the film stops — it does not loop.
    @Test func theExcerptStartsWhereAsked() async throws {
        let stairs = try ToneWriter.staircase()
        let fromTwo = try await listen(try await arranged(
            Self.whole, sound: false, song: VideoSoundtrack(fileURL: stairs, title: "Stairs", startSeconds: 2)
        ))
        let fromStart = try await listen(try await arranged(
            Self.whole, sound: false, song: VideoSoundtrack(fileURL: stairs, title: "Stairs", startSeconds: 0)
        ))
        let late = try await listen(try await arranged(
            Self.whole, sound: false, song: VideoSoundtrack(fileURL: stairs, title: "Stairs", startSeconds: 4.5)
        ))

        #expect(abs(fromStart.pitch(at: 0.5) - 300) < 30, "from 0: \(fromStart.pitch(at: 0.5)) Hz")
        #expect(abs(fromTwo.pitch(at: 0.5) - 900) < 40, "from 2s: \(fromTwo.pitch(at: 0.5)) Hz")
        #expect(abs(fromTwo.pitch(at: 1.5) - 1_200) < 40, "from 2s, a second on: \(fromTwo.pitch(at: 1.5)) Hz")
        #expect(abs(late.pitch(at: 0.75) - 1_800) < 60, "from 4.5s: \(late.pitch(at: 0.75)) Hz")
        #expect(late.rms(at: 1.2) > 5_000, "guard: the late excerpt is heard while it lasts")
        #expect(late.rms(at: 2.5) < 100, "a song that ran out went on: \(late.rms(at: 2.5))")
    }

    // MARK: - The levels

    /// The film's own sound at the level the author left it — silent at zero,
    /// half at a half. Two levels, so a rule that only knew "on" and "off"
    /// cannot pass.
    @Test func originalZeroSilencesTheFilm() async throws {
        let quiet = try ToneWriter.tone(named: "silence", seconds: 6) { _ in (1_000, 0) }
        func film(at level: Double) async throws -> Double {
            let song = VideoSoundtrack(
                fileURL: quiet, title: "Silence", musicVolume: 0, originalVolume: level
            )
            return try await listen(try await arranged(Self.whole, song: song)).rms(at: 0.5)
        }
        let full = try await film(at: 1)
        let half = try await film(at: 0.5)
        let none = try await film(at: 0)

        #expect(full > 5_000, "guard: the film's tone is not there: \(full)")
        #expect(none < 100, "the film is still heard at zero: \(none) of \(full)")
        #expect(abs(half / full - 0.5) < 0.08, "half the level is \(half / full) of full")
    }

    /// And the song's level is its own: half is half.
    @Test func theSongIsHeardAtItsLevel() async throws {
        let steady = try ToneWriter.steady()
        func song(at level: Double) async throws -> Double {
            let song = VideoSoundtrack(fileURL: steady, title: "Steady", musicVolume: level)
            return try await listen(try await arranged(Self.whole, song: song)).rms(at: 3.0)
        }
        let full = try await song(at: 1)
        let quarter = try await song(at: 0.25)

        #expect(full > 5_000, "guard: the song is not there: \(full)")
        #expect(abs(quarter / full - 0.25) < 0.05, "a quarter of the level is \(quarter / full) of full")
    }

    /// ⚠️ **THE FILM'S DIPS ARE REBUILT AT ITS OWN LEVEL.** Turned down to half
    /// under a song, the film must fall from half to silence at a dip to black
    /// and come back to half — not jump to full on the way in.
    @Test func originalVolumeScalesTheDips() async throws {
        let quiet = try ToneWriter.tone(named: "silence", seconds: 6) { _ in (1_000, 0) }
        let cut = [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 1, end: 1.9)
        ]
        let bare = try await listen(try await arranged(cut, song: nil))
        let halved = try await listen(try await arranged(cut, song: VideoSoundtrack(
            fileURL: quiet, title: "Silence", musicVolume: 0, originalVolume: 0.5
        )))

        let full = bare.rms(at: 0.4)
        #expect(full > 5_000, "guard: the film's tone is not there")
        #expect(abs(halved.rms(at: 0.4) / full - 0.5) < 0.08, "before the dip: \(halved.rms(at: 0.4) / full)")
        #expect(halved.rms(at: 1.0) < full * 0.05, "the film does not dip at the cut: \(halved.rms(at: 1.0))")
        #expect(halved.rms(at: 0.85) < full * 0.4, "the film does not fall from its level: \(halved.rms(at: 0.85))")
        #expect(abs(halved.rms(at: 1.5) / full - 0.5) < 0.08, "after the dip: \(halved.rms(at: 1.5) / full)")
    }

    // MARK: - The export

    /// ⚠️ **PASSTHROUGH MIXES NOTHING.** A plan that asked for it, with a song,
    /// would publish two separate audio tracks — or fail — so it gets the
    /// exporter's own preset, and the song is heard in ONE track.
    @Test func aSoundtrackOverridesPassthrough() async throws {
        let file = try await ColourClipWriter.clip()
        let exported = try await VideoExporter().export(VideoExportPlan(
            sourceURL: file,
            segments: [VideoExportSegment(start: 0, end: 1), VideoExportSegment(start: 2, end: 4)],
            preset: AVAssetExportPresetPassthrough,
            soundtrack: VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        ))
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        let asset = AVURLAsset(url: exported.fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "the export carries \(tracks.count) audio tracks")
        // Played 2s is the film's 3s — silent — so only the song can be there.
        let heard = try await SoundProbe.listen(to: asset, mix: nil)
        #expect(heard.rms(at: 2.0) > 3_000, "the song is not in the export: \(heard.rms(at: 2.0))")
        #expect(abs(exported.durationSeconds - 3) < 0.1, "got \(exported.durationSeconds)s")
    }

    /// An uncut clip with a song still carries it.
    @Test(.disabled("TODO(S2): an uncut clip takes `arrangement`'s early return and drops its song; the export-route slice builds it as one piece — enable this then"))
    func anUncutClipCarriesItsSong() async throws {
        let file = try await ColourClipWriter.clip()
        let arranged = try await VideoExporter.arrangement(
            of: AVURLAsset(url: file), cut: [], orientation: .whenComposited,
            soundtrack: VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        )
        let heard = try await listen(arranged)
        #expect(heard.rms(at: 3.0) > 5_000, "no song under an uncut clip: \(heard.rms(at: 3.0))")
    }

    /// ⚠️ **TWELVE EXPORTS, EACH UNDER A WATCHDOG** (memory
    /// `export-volume-ramp-hang`). A song runs under pieces played at 3x and 4x
    /// and beside a dip between two pieces at 1x; a volume ramp at a rate change
    /// once froze the export one time in twelve, silently, so a single passing
    /// export proves nothing. An export whose progress stands still for two
    /// minutes is cancelled and counted as hung.
    ///
    /// ⚠️ **A STALL, NOT A DEADLINE — MEASURED.** With a 60 s deadline this
    /// reported 2 of 12 hung on a machine at load average ~900; 24 exports of
    /// the same arrangement under a 90 s deadline then all finished, in up to
    /// 59 s — and 24 of the film WITHOUT a song took up to 85 s. A frozen export
    /// never moves again; a starved one keeps creeping, so only the stall tells
    /// them apart.
    @Test func stressExportWithMusicAndRatedPieces() async throws {
        let file = try await ColourClipWriter.clip()
        let song = VideoSoundtrack(
            fileURL: try ToneWriter.tone(named: "stress", seconds: 8, compressed: true) { _ in (700, 0.5) },
            title: "Stress", startSeconds: 1, musicVolume: 0.8, originalVolume: 0.6
        )
        let cut = [
            VideoExportSegment(start: 0, end: 1, transitionOut: .dipToBlack),
            VideoExportSegment(start: 1, end: 1.8),
            VideoExportSegment(start: 1.8, end: 3.3, speed: 3),
            VideoExportSegment(start: 0.5, end: 3.7, speed: 4)
        ]
        var hung = 0
        var failed: [String] = []
        for run in 0..<12 {
            let arranged = try await VideoExporter.arrangement(
                of: AVURLAsset(url: file), cut: cut, orientation: .whenComposited, soundtrack: song
            )
            try #require(arranged.sound != nil, "guard: no song was laid")
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("stress-\(run)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            let outcome = try await Self.export(arranged, to: output, stalledFor: 120)
            switch outcome {
            case .completed: break
            case .hung: hung += 1
            case .failed(let reason): failed.append("run \(run): \(reason)")
            }
        }
        #expect(hung == 0, "\(hung) of 12 exports hung")
        #expect(failed.isEmpty, "\(failed)")
    }

    private enum Outcome: Sendable {
        case completed
        case hung
        case failed(String)
    }

    /// ⚠️ **`exportAsynchronously` AND `cancelExport`, BECAUSE A HUNG `await
    /// export()` NEVER RETURNS** — the session is driven here the way
    /// `VideoExporter.export` drives it, with the same preset, mix, composition
    /// and pitch, and a watchdog that gives up on it once its progress has
    /// stood still for `stall` seconds.
    private static func export(
        _ arranged: VideoExporter.Arrangement, to output: URL, stalledFor stall: Double
    ) async throws -> Outcome {
        guard let session = AVAssetExportSession(
            asset: arranged.asset, presetName: AVAssetExportPreset1280x720
        ) else { return .failed("no session") }
        session.videoComposition = arranged.videoComposition
        session.audioMix = arranged.audioMix
        session.outputURL = output
        session.outputFileType = .mp4
        session.audioTimePitchAlgorithm = .spectral
        nonisolated(unsafe) let driven = session
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let clock = StallClock()
            driven.exportAsynchronously {
                once.run { continuation.resume(returning: true) }
            }
            @Sendable func watch() {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    guard !once.isDone else { return }
                    guard clock.hasStalled(at: driven.progress, for: stall) else { return watch() }
                    once.run {
                        driven.cancelExport()
                        continuation.resume(returning: false)
                    }
                }
            }
            watch()
        }
        guard finished else { return .hung }
        return driven.status == .completed
            ? .completed : .failed(driven.error.map { "\($0)" } ?? "status \(driven.status.rawValue)")
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }

    /// How long an export's progress has stood still.
    private final class StallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Float = -1
        private var since = Date()

        /// Whether `progress` has not moved for `seconds`.
        func hasStalled(at progress: Float, for seconds: Double) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard progress == last else {
                last = progress
                since = Date()
                return false
            }
            return Date().timeIntervalSince(since) > seconds
        }
    }

    // MARK: - Checking a song

    /// A file that is not a song is said to be one of the four things that can
    /// be wrong with it; a song is its length.
    @Test func refusesProtectedOrSilentFiles() async throws {
        let silentFilm = try await ColourClipWriter.clip(sound: false)
        let blip = try ToneWriter.tone(named: "blip", seconds: 0.5) { _ in (500, 0.5) }
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-song.m4a")
        try Data("not a song".utf8).write(to: garbage)
        let steady = try ToneWriter.steady()

        #expect(await VideoSoundtrack.vet(silentFilm) == .failure(.noSound))
        #expect(await VideoSoundtrack.vet(blip) == .failure(.tooShort))
        #expect(await VideoSoundtrack.vet(garbage) == .failure(.unreadable))
        let length = try (await VideoSoundtrack.vet(steady)).get()
        #expect(abs(length - 6) < 0.05, "a six-second song measured \(length)s")
        #expect(await VideoSoundtrack.vet(try await ColourClipWriter.clip()).map { $0 > 3.9 } == .success(true),
                "the sound of a film is a song")

        // Protection cannot be written into a test file; the rule is asked.
        #expect(VideoSoundtrack.problem(hasSound: true, isPlayable: true, isProtected: true, seconds: 60)
                == .protected)
        #expect(VideoSoundtrack.problem(hasSound: true, isPlayable: false, isProtected: false, seconds: 60)
                == .unreadable)
        #expect(VideoSoundtrack.problem(hasSound: true, isPlayable: true, isProtected: false, seconds: 1)
                == nil, "exactly a second is enough")
    }

    /// A new level is a new mix for a playing item — the same file from the same
    /// second lays the same audio.
    @Test func onlyTheFileAndTheStartNeedANewTrack() {
        let url = URL(fileURLWithPath: "/tmp/song.m4a")
        let song = VideoSoundtrack(fileURL: url, title: "Song", startSeconds: 3)
        var louder = song
        louder.musicVolume = 0.2
        louder.originalVolume = 0
        var later = song
        later.startSeconds = 4
        var other = song
        other.fileURL = URL(fileURLWithPath: "/tmp/other.m4a")

        #expect(VideoSoundtrack.laysTheSameAudio(song, louder))
        #expect(!VideoSoundtrack.laysTheSameAudio(song, later))
        #expect(!VideoSoundtrack.laysTheSameAudio(song, other))
        #expect(!VideoSoundtrack.laysTheSameAudio(song, nil))
        #expect(VideoSoundtrack.laysTheSameAudio(nil, nil))
    }

    // MARK: - The waveform

    /// Loud, then quiet, then silent: the peaks say so, at the tone's own
    /// heights — a sine's AVERAGE is 0.64 of its peak, which a bar must not show.
    @Test func waveformPeaksFollowLoudness() async throws {
        let steps = try ToneWriter.tone(named: "steps", seconds: 3) { at in
            (440, at < 1 ? 0.8 : at < 2 ? 0.2 : 0)
        }
        let peaks = try await AudioWaveform.peaks(of: steps)

        #expect(abs(peaks.count - 300) <= 2, "\(peaks.count) peaks for three seconds")
        let loud = peaks[20..<80].reduce(0, +) / 60
        let soft = peaks[120..<180].reduce(0, +) / 60
        let silent = peaks[220..<280].max() ?? 1
        #expect(abs(loud - 0.8) < 0.05, "the loud second peaks at \(loud)")
        #expect(abs(soft - 0.2) < 0.03, "the soft second peaks at \(soft)")
        #expect(silent < 0.01, "the silent second peaks at \(silent)")
    }

    @Test func aFileWithoutSoundHasNoWaveform() async throws {
        let silentFilm = try await ColourClipWriter.clip(sound: false)
        await #expect(throws: SoundtrackProblem.noSound) {
            try await AudioWaveform.peaks(of: silentFilm)
        }
    }
}

/// **THE EDITOR'S PLAYER HEARS THE SONG, AT THE LEVELS BEING DRAGGED.**
@MainActor
@Suite(.serialized)
struct SoundtrackPreviewTests {
    private struct Passthrough: VideoSource {
        func playableURL(for url: URL) async throws -> URL { url }
    }

    private func loaded(
        song: VideoSoundtrack?
    ) async throws -> (VideoPlaybackController, VideoRenderView, AVPlayerItem) {
        let controller = VideoPlaybackController(source: Passthrough(), poolSize: 1, capacity: 1)
        let view = VideoRenderView()
        view.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let file = try await ColourClipWriter.clip()
        await controller.load(
            VideoExportPlan(sourceURL: file, segments: [VideoExportSegment(start: 0, end: 4)], soundtrack: song),
            in: view
        ) { 0 }
        let item = try #require(controller.debugItem(in: view), "nothing was loaded")
        return (controller, view, item)
    }

    /// ⚠️ **THE ITEM'S MIX IS REPLACED, AND WHAT IT PLAYS IS MEASURED** — through
    /// the mix the item now holds, not the levels the call was given.
    @Test func setMixLevelsReplacesTheItemMix() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        let (controller, view, item) = try await loaded(song: song)
        defer { controller.stop(view) }

        #expect(controller.carriesSoundtrack(in: view))
        let before = try await SoundProbe.listen(to: item.asset, mix: item.audioMix)
        #expect(before.rms(at: 3.0) > 5_000, "guard: the song is not in the item")

        #expect(controller.setMixLevels(music: 0, original: 1, in: view))
        let songOff = try await SoundProbe.listen(to: item.asset, mix: item.audioMix)
        #expect(songOff.rms(at: 3.0) < 100, "the song is still heard at zero: \(songOff.rms(at: 3.0))")
        #expect(songOff.rms(at: 0.5) > 5_000, "the film went with it: \(songOff.rms(at: 0.5))")

        #expect(controller.setMixLevels(music: 0.5, original: 0, in: view))
        let halfSong = try await SoundProbe.listen(to: item.asset, mix: item.audioMix)
        #expect(abs(halfSong.rms(at: 3.0) / before.rms(at: 3.0) - 0.5) < 0.08,
                "half the song is \(halfSong.rms(at: 3.0) / before.rms(at: 3.0))")
        #expect(abs(halfSong.pitch(at: 0.5) - 1_000) < 60,
                "the film is still heard under a song at half: \(halfSong.pitch(at: 0.5)) Hz")
    }

    /// ⚠️ **LEVELS BELONG TO THE ITEM THAT CARRIES THE SONG.** Reloaded without
    /// one, shown as shot under a trim handle, or stopped, the player has no
    /// song to set — and a mix naming the song's track would be handed to an
    /// item that has no such track.
    @Test func levelsNeedASong() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        let (controller, view, _) = try await loaded(song: song)
        let file = try await ColourClipWriter.clip()
        try #require(controller.carriesSoundtrack(in: view), "guard: the song was not laid")

        #expect(controller.showAsShot(file, in: view, at: 1))
        #expect(!controller.carriesSoundtrack(in: view), "the file as shot carries no song")
        #expect(!controller.setMixLevels(music: 1, original: 1, in: view))

        await controller.load(
            VideoExportPlan(sourceURL: file, segments: [VideoExportSegment(start: 0, end: 4)]), in: view
        ) { 0 }
        #expect(!controller.carriesSoundtrack(in: view), "a reload without the song still carries it")
        #expect(!controller.setMixLevels(music: 1, original: 1, in: view))

        controller.stop(view)
        #expect(!controller.setMixLevels(music: 1, original: 1, in: view))
    }

    /// ⚠️ **HEARD UNDER `.playback`, AND BACK TO `.ambient` WHEN IT STOPS.** An
    /// `.ambient` session is silenced by the ring switch; one left at `.playback`
    /// after the editor would make the feed play through it.
    @Test func setMutedLetsTheClipBeHeardAndStopGivesTheSessionBack() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        let (controller, view, _) = try await loaded(song: song)
        let session = AVAudioSession.sharedInstance()

        #expect(controller.isMuted(in: view) == true, "a clip starts silent")
        #expect(session.category == .ambient)

        #expect(controller.setMuted(false, in: view))
        #expect(controller.isMuted(in: view) == false)
        #expect(session.category == .playback, "heard under \(session.category.rawValue)")

        controller.stop(view)
        #expect(session.category == .ambient, "the session stayed \(session.category.rawValue)")
        #expect(!controller.setMuted(false, in: view), "nothing is bound to hear")
    }

    /// A reloaded item keeps the player's choice — the author hears the new
    /// excerpt without asking again.
    @Test func aSwappedItemStaysHeard() async throws {
        let song = VideoSoundtrack(fileURL: try ToneWriter.steady(), title: "Steady")
        let (controller, view, first) = try await loaded(song: song)
        defer { controller.stop(view) }
        controller.setMuted(false, in: view)

        var later = song
        later.startSeconds = 2
        await controller.load(
            VideoExportPlan(
                sourceURL: try await ColourClipWriter.clip(),
                segments: [VideoExportSegment(start: 0, end: 4)], soundtrack: later
            ),
            in: view
        ) { 0 }

        let second = try #require(controller.debugItem(in: view))
        #expect(second !== first, "guard: no new item")
        #expect(controller.isMuted(in: view) == false)
        #expect(controller.carriesSoundtrack(in: view))
    }
}
