import AVFoundation
import UIKit

/// The sounds the app makes for ITSELF — a control landing, not a clip playing.
///
/// ⚠️ **THIS TYPE NEVER TOUCHES THE AUDIO SESSION, AND THAT IS A RULE.**
/// `VideoPlaybackController` owns the shared session: `.ambient` while nothing
/// audible is playing, `.playback` while a clip with sound is. A UI sound that
/// set a category of its own would fight it — and the category is what decides
/// whether the hardware silent switch is honoured, so the fight would be over
/// something the author has an opinion about. Inheriting it means a pop is
/// silent when the phone is silent and audible when a clip already is.
///
/// ⚠️ **AND IT IS NOT A HAPTIC.** Both exist, they are not alternatives, and
/// the rule for the haptic is `StraightenDialView`'s: a generator built inside
/// the handler arrives cold and clicks late.
@MainActor
public enum UISound: String, CaseIterable, Sendable {
    /// The tick an element makes as it arrives — see `BandPop` in Upload, whose
    /// 40ms stagger this file was chosen against.
    case pop

    /// Plays it, optionally `delay` seconds from now.
    ///
    /// ⚠️ **SCHEDULED ON THE AUDIO CLOCK, NOT ON A TIMER.** A row of nine
    /// elements asks for nine plays 40ms apart; nine `Task.sleep`s would land
    /// wherever the main thread happened to be, and the ripple the spacing
    /// exists for would come out as a stutter. `play(atTime:)` hands the
    /// spacing to the audio system, which is the only clock that can keep it.
    public func play(after delay: TimeInterval = 0) {
        guard let player = Self.players.take(self) else { return }
        player.currentTime = 0
        if delay > 0 {
            player.play(atTime: player.deviceCurrentTime + delay)
        } else {
            player.play()
        }
    }

    /// Warms the sound up, so the first one of a session is not the late one.
    ///
    /// ⚠️ **A FIRST `play()` DECODES AND OPENS THE ROUTE**, which on a cold app
    /// is tens of milliseconds — long enough for the first element of the first
    /// row to be seen landing before it is heard.
    public static func prepare() {
        for sound in allCases { _ = players.take(sound) }
    }

    fileprivate static let players = SoundPool()
}

/// A small ring of players per sound.
///
/// ⚠️ **ONE PLAYER PER SOUND IS NOT ENOUGH, BECAUSE THESE OVERLAP ON PURPOSE.**
/// `AVAudioPlayer.play()` on a player that is already running restarts it — so
/// a single instance would cut each pop off with the next and a nine-element
/// row would be heard as one. The pop is 70ms against a 40ms stagger, so two
/// can sound at once; four is that with room to spare, and four players of a
/// 10KB file is nothing.
@MainActor
final class SoundPool {
    private enum Metrics {
        static let depth = 4
        /// ⚠️ **QUIET.** This is punctuation under a finger, not an event. Read
        /// at full volume against the room the phone is usually in, nine of
        /// them in a third of a second is a rattle.
        static let volume: Float = 0.35
    }

    private var rings: [UISound: [AVAudioPlayer]] = [:]
    private var next: [UISound: Int] = [:]

    /// The next player for `sound`, or nil when the bundle has no such file.
    ///
    /// ⚠️ **NIL IS SILENCE, NOT A CRASH** — the reason `MediaLookReference`
    /// gives for its own missing picture: a resource that failed to copy is a
    /// build mistake, and it must not take the screen down with it.
    func take(_ sound: UISound) -> AVAudioPlayer? {
        if rings[sound] == nil { rings[sound] = Self.build(sound) }
        guard let ring = rings[sound], !ring.isEmpty else { return nil }
        let index = (next[sound] ?? 0) % ring.count
        next[sound] = index + 1
        return ring[index]
    }

    private static func build(_ sound: UISound) -> [AVAudioPlayer] {
        // ⚠️ **`Bundle.module` IS DESIGNSYSTEM'S** — and the folder is `.copy`'d,
        // so it keeps its name in the bundle and is addressed by subdirectory.
        guard let url = Bundle.module.url(
            forResource: sound.rawValue, withExtension: "caf", subdirectory: "Sounds"
        ) else { return [] }
        return (0..<Metrics.depth).compactMap { _ in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.volume = Metrics.volume
            player.prepareToPlay()
            return player
        }
    }

    #if DEBUG
    /// Internal for tests: how deep the ring for `sound` is, once built.
    func debugDepth(of sound: UISound) -> Int { (rings[sound] ?? []).count }
    #endif
}
