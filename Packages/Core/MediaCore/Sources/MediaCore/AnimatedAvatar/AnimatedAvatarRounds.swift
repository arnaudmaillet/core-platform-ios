import DesignSystem
import UIKit

/// Who plays, among the animated avatars on screen (#1424, the owner,
/// 2026-10-19): avatars no longer play because they appeared. From time to
/// time, a ROUND picks a few at random among the visible ones and plays them
/// staggered, then waits a random pause before the next.
///
/// - A round picks `tuning.picks` avatars among the candidates
///   (`AnimatedAvatarPlayer.isRoundCandidate`: on screen, its screen at rest,
///   not scrolling, nothing presented over it, the app in front), plays the
///   first at once and each next one `tuning.stagger` later, then the next
///   round comes `tuning.pause` after its last play started.
/// - No avatar plays two rounds in a row, and the most recently played are
///   picked last.
/// - The players' own limits still hold: `maxConcurrent`, `minimumDiameter`,
///   Reduce Motion, Low Power Mode, idle calm (#650 — a round under it plays
///   nothing and the rounds stop until decoration wakes).
///
/// ⚠️ A TIMER, NOT AN ANIMATION (#580): one pending work item while an
/// animated avatar is in a window, nothing at all otherwise. Players join
/// while they are animated and in a window, and leave when either ends.
///
/// One for the app (`app`): only the screen in front has avatars in a window,
/// so its rounds are that screen's.
@MainActor
public final class AnimatedAvatarRounds {
    /// The numbers to tune, in one place. In DEBUG, `-avatar-rounds` sets
    /// them on the device: `-avatar-rounds "picks=1-3 stagger=0.3-1.5
    /// pause=3-6 first=0.4-0.8"`, any subset.
    public struct Tuning: Equatable, Sendable {
        /// How many a round plays.
        public var picks: ClosedRange<Int> = 1...3
        /// Between two plays of one round, in seconds.
        public var stagger: ClosedRange<TimeInterval> = 0.3...1.5
        /// From a round's last play to the next round, in seconds.
        public var pause: ClosedRange<TimeInterval> = 3...6
        /// From a first display to its play (`.firstAppearance`), in seconds.
        public var firstDisplayDelay: ClosedRange<TimeInterval> = 0.4...0.8

        public init(
            picks: ClosedRange<Int> = 1...3, stagger: ClosedRange<TimeInterval> = 0.3...1.5,
            pause: ClosedRange<TimeInterval> = 3...6, firstDisplayDelay: ClosedRange<TimeInterval> = 0.4...0.8
        ) {
            self.picks = picks
            self.stagger = stagger
            self.pause = pause
            self.firstDisplayDelay = firstDisplayDelay
        }

        public static let standard = Tuning()

        /// A random value in `range`.
        func draw(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
            range.lowerBound == range.upperBound ? range.lowerBound : .random(in: range)
        }

        /// `-avatar-rounds`'s tuning over the standard one; the standard one
        /// without the flag.
        static func launch(_ arguments: [String]) -> Tuning {
            var tuning = Tuning.standard
            guard let index = arguments.firstIndex(of: "-avatar-rounds"), arguments.indices.contains(index + 1) else {
                return tuning
            }
            for pair in arguments[index + 1].split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let bounds = parts[1].split(separator: "-").compactMap { Double($0) }
                guard let low = bounds.first else { continue }
                let high = max(low, bounds.last ?? low)
                switch parts[0] {
                case "picks": tuning.picks = max(1, Int(low))...max(1, Int(high))
                case "stagger": tuning.stagger = low...high
                case "pause": tuning.pause = low...high
                case "first": tuning.firstDisplayDelay = low...high
                default: continue
                }
            }
            return tuning
        }
    }

    public static let app: AnimatedAvatarRounds = {
        #if DEBUG
        return AnimatedAvatarRounds(tuning: .launch(ProcessInfo.processInfo.arguments))
        #else
        return AnimatedAvatarRounds(tuning: .standard)
        #endif
    }()

    public var tuning: Tuning

    private struct Member {
        weak var player: AnimatedAvatarPlayer?
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var nextRound: DispatchWorkItem?
    private var pendingPlays: [DispatchWorkItem] = []
    /// The round each avatar last played in.
    private var lastPlayed: [URL: Int] = [:]
    private var round = 0
    private var motionObserver: NSObjectProtocol?

    init(tuning: Tuning) {
        self.tuning = tuning
        motionObserver = NotificationCenter.default.addObserver(
            forName: .decorativeMotionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.decorationChanged() }
        }
    }

    /// Whether a round is waiting — false with no animated avatar on screen.
    var isRunning: Bool { nextRound != nil }

    func join(_ player: AnimatedAvatarPlayer) {
        members[ObjectIdentifier(player)] = Member(player: player)
        if nextRound == nil { schedule(after: tuning.draw(tuning.pause)) }
    }

    func leave(_ player: AnimatedAvatarPlayer) {
        guard members.removeValue(forKey: ObjectIdentifier(player)) != nil else { return }
        if liveMembers.isEmpty { halt() }
    }

    private var liveMembers: [AnimatedAvatarPlayer] {
        members = members.filter { $0.value.player != nil }
        return members.values.compactMap(\.player)
    }

    private func halt() {
        nextRound?.cancel()
        nextRound = nil
        pendingPlays.forEach { $0.cancel() }
        pendingPlays = []
    }

    private func schedule(after delay: TimeInterval) {
        nextRound?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.playRound() }
        }
        nextRound = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Decoration woke (idle calm ended): the rounds start again.
    private func decorationChanged() {
        guard !MotionPreference.stillsDecoration, nextRound == nil, !liveMembers.isEmpty else { return }
        schedule(after: tuning.draw(tuning.pause))
    }

    /// One round: picks, staggers, and books the next.
    func playRound() {
        nextRound = nil
        pendingPlays = []
        let players = liveMembers
        guard !players.isEmpty else { return }
        // At rest the rounds stop; `decorationChanged` starts them again.
        guard !MotionPreference.stillsDecoration else { return }
        round += 1
        let previous = round - 1
        let candidates = players.filter { player in
            guard player.isRoundCandidate, let url = player.url else { return false }
            return lastPlayed[url] != previous
        }
        // Never played first, then the longest ago; random among equals.
        let ordered = candidates.shuffled().sorted { (lastPlayed[$0.url!] ?? -1) < (lastPlayed[$1.url!] ?? -1) }
        let count = min(Int.random(in: tuning.picks), ordered.count)
        var at: TimeInterval = 0
        for (index, player) in ordered.prefix(count).enumerated() {
            if index > 0 { at += tuning.draw(tuning.stagger) }
            guard let url = player.url else { continue }
            lastPlayed[url] = round
            if at == 0 {
                player.playFromRound()
                continue
            }
            let work = DispatchWorkItem { [weak player] in
                MainActor.assumeIsolated {
                    // Still its own, still at rest: a scroll since stops it.
                    guard let player, player.url == url, player.isRoundCandidate else { return }
                    player.playFromRound()
                }
            }
            pendingPlays.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
        }
        schedule(after: at + tuning.draw(tuning.pause))
    }
}
