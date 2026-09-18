import AVFoundation
import Testing
@testable import DesignSystem

/// The app's own sounds: that the file is really in the bundle, and that the
/// pool is deep enough for sounds that overlap on purpose.
@MainActor
struct UISoundTests {
    /// ⚠️ **A MISSING RESOURCE IS SILENT, AND SILENCE LOOKS EXACTLY LIKE
    /// WORKING.** `.copy("Resources/Sounds")` in Package.swift is the only
    /// thing putting this file in the bundle, and nothing else in the app would
    /// ever say it had gone.
    @Test func thePopIsInTheBundle() throws {
        let url = try #require(
            Bundle.module.url(forResource: "pop", withExtension: "caf", subdirectory: "Sounds"),
            "DesignSystem's bundle has no Sounds/pop.caf — check Package.swift's resources"
        )
        let player = try AVAudioPlayer(contentsOf: url)
        #expect(player.duration > 0.01, "got \(player.duration)s")
        #expect(player.duration < 0.2, "a punctuation sound this long smears a staggered row: \(player.duration)s")
    }

    /// ⚠️ **ONE PLAYER PER SOUND WOULD CUT EACH POP OFF WITH THE NEXT.**
    /// `AVAudioPlayer.play()` on a running player restarts it, and these are
    /// asked to overlap: 70ms of sound against a 40ms stagger.
    @Test func thePoolIsDeepEnoughForSoundsThatOverlap() {
        let pool = SoundPool()

        let first = pool.take(.pop)
        let second = pool.take(.pop)

        #expect(first != nil, "no player at all")
        #expect(pool.debugDepth(of: .pop) > 1, "a ring of \(pool.debugDepth(of: .pop))")
        #expect(first !== second, "the same player twice in a row cuts the first pop off")
    }

    /// And it comes back round rather than growing without end.
    @Test func theRingCyclesRatherThanAllocating() {
        let pool = SoundPool()
        let depth = { pool.debugDepth(of: .pop) }
        _ = pool.take(.pop)
        let built = depth()
        try? #require(built > 0)

        let taken = (0..<(built * 3)).compactMap { _ in pool.take(.pop) }

        #expect(depth() == built, "the ring grew from \(built) to \(depth())")
        #expect(taken.count == built * 3, "the pool stopped answering")
        #expect(taken[0] === taken[built], "it did not come back round")
    }

    @Test func everySoundNamesAFileThatExists() {
        for sound in UISound.allCases {
            #expect(
                Bundle.module.url(forResource: sound.rawValue, withExtension: "caf", subdirectory: "Sounds") != nil,
                "UISound.\(sound.rawValue) has no file"
            )
        }
    }
}
