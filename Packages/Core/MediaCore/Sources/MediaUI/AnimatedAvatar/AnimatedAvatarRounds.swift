import DesignSystem
import LaunchArguments
import MediaCore
import UIKit

/// Who plays, among the animated avatars on screen: the CONDUCTOR. Each
/// screen's rule comes from one table (`AvatarMotionPolicy`, #2454, the
/// owner, 2026-11-15); the conductor runs the two rules that need one:
///
/// - `.rounds(picks:)` (#1424): from time to time, a round picks a few
///   avatars at random among the screen's candidates, plays the first at once
///   and each next one `tuning.stagger` later, then the next round comes
///   `tuning.pause` after its last play started. No avatar plays two rounds
///   in a row, and the most recently played are picked last.
/// - `.sequence(order:)`: ONE AVATAR AT A TIME, in an order read when a wave
///   starts, among the avatars visible then. The next starts when the
///   previous play ends; an avatar that left the screen since, or whose play
///   a global limit refuses, is skipped. The wave starts again
///   `tuning.pause` after its last play ends.
///
/// A candidate is on screen, its screen at rest (not scrolling, nothing
/// presented over it, the app in front): `AnimatedAvatarPlayer.isRoundCandidate`.
/// No round or wave starts while a screen scrolls. The players' own limits
/// stay above every rule: `maxConcurrent`, `minimumDiameter`, Reduce Motion,
/// Low Power Mode, idle calm (#650 — under it nothing plays and the screens
/// stop until decoration wakes).
///
/// ⚠️ A TIMER, NOT AN ANIMATION (#580): one pending work item per screen
/// while one of its animated avatars is in a window, nothing at all
/// otherwise. Players join while they are animated, in a window and
/// conducted, and leave when any of these ends.
///
/// One for the app (`app`): each screen's avatars are conducted apart, by
/// the screen's name.
@MainActor
public final class AnimatedAvatarRounds {
    /// The timings to tune, in one place (each screen's rule is
    /// `AvatarMotionPolicy`'s). In DEBUG, `-avatar-rounds` sets them on the
    /// device: `-avatar-rounds "picks=1-3 stagger=0.3-1.5
    /// pause=3-6 first=0.4-0.8"`, any subset.
    public struct Tuning: Equatable, Sendable {
        /// How many a round plays on a screen the table leaves out.
        public var picks: ClosedRange<Int> = 1...3
        /// Between two plays of one round, in seconds.
        public var stagger: ClosedRange<TimeInterval> = 0.3...1.5
        /// From a round's last play to the next round, and from a wave's
        /// last play's end to the next wave, in seconds.
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
            guard let spec = LaunchArgument.avatarRounds.value(in: arguments) else {
                return tuning
            }
            for pair in spec.split(separator: " ") {
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
        let arguments = ProcessInfo.processInfo.arguments
        let tuning = Tuning.launch(arguments)
        return AnimatedAvatarRounds(
            tuning: tuning, policy: .launch(arguments, standardPicks: tuning.picks)
        )
        #else
        return AnimatedAvatarRounds(tuning: .standard, policy: .standard)
        #endif
    }()

    public var tuning: Tuning
    /// Every screen's rule (`AvatarMotionPolicy.standard`, or a test's own).
    public var policy: AvatarMotionPolicy

    private struct Member {
        weak var player: AnimatedAvatarPlayer?
        let screen: AvatarMotionScreen?
    }

    /// One screen's choreography: its one timer, its rounds' memory, its
    /// wave.
    private final class Stage {
        var next: DispatchWorkItem?
        var pendingPlays: [DispatchWorkItem] = []
        /// The round each avatar last played in.
        var lastPlayed: [URL: Int] = [:]
        var round = 0
        /// The wave's avatars still to play, in order.
        var wave: [WeakPlayer] = []

        func halt() {
            next?.cancel()
            next = nil
            pendingPlays.forEach { $0.cancel() }
            pendingPlays = []
            wave = []
        }
    }

    private struct WeakPlayer {
        weak var player: AnimatedAvatarPlayer?
    }

    private var members: [ObjectIdentifier: Member] = [:]
    private var stages: [AvatarMotionScreen?: Stage] = [:]
    private var motionObserver: NSObjectProtocol?

    init(tuning: Tuning, policy: AvatarMotionPolicy = .standard) {
        self.tuning = tuning
        self.policy = policy
        motionObserver = NotificationCenter.default.addObserver(
            forName: .decorativeMotionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.decorationChanged() }
        }
    }

    /// The rule `screen`'s avatars follow: the table's, or the random rounds
    /// for a screen not in it (nil: none declared).
    public func rule(for screen: AvatarMotionScreen?) -> AvatarMotionRule {
        screen.flatMap { policy.rules[$0] } ?? .rounds(picks: tuning.picks)
    }

    /// Whether a work item is pending — false with no conducted avatar in a
    /// window (#580).
    var isRunning: Bool { stages.values.contains { $0.next != nil } }

    /// Told each time a play it asked for starts — what a test reads for a
    /// sequence's order.
    var onPlay: ((AnimatedAvatarPlayer) -> Void)?

    /// The avatars `screen`'s conductor holds now. Tests.
    func memberCount(on screen: AvatarMotionScreen?) -> Int { liveMembers(on: screen).count }

    /// A conducted play: told to `onPlay` when it starts. Its duration, nil
    /// when a limit refused it.
    @discardableResult
    private func play(_ player: AnimatedAvatarPlayer) -> TimeInterval? {
        guard let duration = player.playFromConductor() else { return nil }
        onPlay?(player)
        return duration
    }

    func join(_ player: AnimatedAvatarPlayer, on screen: AvatarMotionScreen?) {
        let id = ObjectIdentifier(player)
        if let member = members[id], member.screen != screen { leave(player) }
        members[id] = Member(player: player, screen: screen)
        let stage = stages[screen] ?? Stage()
        stages[screen] = stage
        if stage.next == nil { schedule(screen, after: tuning.draw(tuning.pause)) }
    }

    func leave(_ player: AnimatedAvatarPlayer) {
        guard let member = members.removeValue(forKey: ObjectIdentifier(player)) else { return }
        guard liveMembers(on: member.screen).isEmpty else { return }
        stages.removeValue(forKey: member.screen)?.halt()
    }

    private func liveMembers(on screen: AvatarMotionScreen?) -> [AnimatedAvatarPlayer] {
        members = members.filter { $0.value.player != nil }
        return members.values.filter { $0.screen == screen }.compactMap(\.player)
    }

    private func schedule(_ screen: AvatarMotionScreen?, after delay: TimeInterval) {
        guard let stage = stages[screen] else { return }
        stage.next?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.advance(on: screen) }
        }
        stage.next = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Decoration woke (idle calm ended): every screen starts again.
    private func decorationChanged() {
        guard !MotionPreference.stillsDecoration else { return }
        for (screen, stage) in stages where stage.next == nil && !liveMembers(on: screen).isEmpty {
            schedule(screen, after: tuning.draw(tuning.pause))
        }
    }

    /// `screen`'s next turn: a round, or the wave's next play.
    func advance(on screen: AvatarMotionScreen? = nil) {
        guard let stage = stages[screen] else { return }
        // Asked early (a test), the turn it replaces is dropped.
        stage.next?.cancel()
        stage.next = nil
        stage.pendingPlays = []
        guard !liveMembers(on: screen).isEmpty else { return }
        // At rest the screens stop; `decorationChanged` starts them again.
        guard !MotionPreference.stillsDecoration else {
            stage.wave = []
            return
        }
        switch rule(for: screen).conducted {
        case .rounds(let picks)?: playRound(on: screen, stage: stage, picks: picks)
        case .sequence(let order)?: playWave(on: screen, stage: stage, order: order)
        default: return
        }
    }

    // MARK: Rounds

    private func playRound(on screen: AvatarMotionScreen?, stage: Stage, picks: ClosedRange<Int>) {
        stage.round += 1
        let previous = stage.round - 1
        let candidates = liveMembers(on: screen).filter { player in
            guard player.isRoundCandidate, let url = player.url else { return false }
            return stage.lastPlayed[url] != previous
        }
        // Never played first, then the longest ago; random among equals.
        let lastPlayed = stage.lastPlayed
        let ordered = candidates.shuffled().sorted { (lastPlayed[$0.url!] ?? -1) < (lastPlayed[$1.url!] ?? -1) }
        let count = min(Int.random(in: picks), ordered.count)
        var at: TimeInterval = 0
        for (index, player) in ordered.prefix(count).enumerated() {
            if index > 0 { at += tuning.draw(tuning.stagger) }
            guard let url = player.url else { continue }
            stage.lastPlayed[url] = stage.round
            if at == 0 {
                play(player)
                continue
            }
            let work = DispatchWorkItem { [weak self, weak player] in
                MainActor.assumeIsolated {
                    // Still its own, still at rest: a scroll since stops it.
                    guard let self, let player, player.url == url, player.isRoundCandidate else { return }
                    self.play(player)
                }
            }
            stage.pendingPlays.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
        }
        schedule(screen, after: at + tuning.draw(tuning.pause))
    }

    // MARK: Sequences

    /// The wave's next play, or a new wave when the last one is over.
    private func playWave(on screen: AvatarMotionScreen?, stage: Stage, order: AvatarMotionRule.SequenceOrder) {
        // ⚠️ ONE AT A TIME, EVEN LATE: a play's end is told by Core
        // Animation, which can come a beat after the play's duration; a play
        // the screen started itself (a first display, a tap) holds it too.
        guard !liveMembers(on: screen).contains(where: \.isPlaying) else {
            return schedule(screen, after: Self.playingBeat)
        }
        if stage.wave.isEmpty {
            // The rank is read now, among the avatars visible and at rest: a
            // screen that scrolls has none, and its wave waits for rest.
            let candidates = liveMembers(on: screen).filter(\.isRoundCandidate)
            stage.wave = Self.ordered(candidates, by: order).map(WeakPlayer.init)
        }
        while !stage.wave.isEmpty {
            // Left the screen, scrolled, or refused by a global limit since
            // the wave began: skipped, the next one plays.
            guard let player = stage.wave.removeFirst().player, player.isRoundCandidate,
                  let duration = play(player) else { continue }
            schedule(screen, after: stage.wave.isEmpty ? duration + tuning.draw(tuning.pause) : duration)
            return
        }
        schedule(screen, after: tuning.draw(tuning.pause))
    }

    /// How long a sequence waits again for a play still running.
    static let playingBeat: TimeInterval = 0.1

    /// `players` in a sequence's order, by their place in the window.
    static func ordered(
        _ players: [AnimatedAvatarPlayer], by order: AvatarMotionRule.SequenceOrder
    ) -> [AnimatedAvatarPlayer] {
        let rightToLeft = players.first?.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let placed = players.map { player -> (player: AnimatedAvatarPlayer, row: CGFloat, along: CGFloat) in
            let frame = player.convert(player.bounds, to: nil)
            return (player, frame.minY, rightToLeft ? -frame.maxX : frame.minX)
        }
        let sorted = placed.sorted { lhs, rhs in
            switch order {
            case .topToBottom:
                return (lhs.row, lhs.along) < (rhs.row, rhs.along)
            case .leadingToTrailing:
                return (lhs.along, lhs.row) < (rhs.along, rhs.row)
            case .unreadFirst:
                let left = lhs.player.motionPriority, right = rhs.player.motionPriority
                if left != right { return left > right }
                return (lhs.row, lhs.along) < (rhs.row, rhs.along)
            }
        }
        return sorted.map(\.player)
    }
}
