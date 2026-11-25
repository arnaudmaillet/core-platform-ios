import LaunchArguments
import UIKit

/// How the animated avatars of one screen move (#2454, the owner,
/// 2026-11-15): one rule per screen, every avatar drawn inside it follows it.
/// The rules are written in ONE table, `AvatarMotionPolicy.standard`.
public indirect enum AvatarMotionRule: Equatable, Sendable, CustomStringConvertible {
    /// Nothing plays: every avatar shows its still (the sheet's last frame).
    case off
    /// From time to time, `picks` avatars picked at random among the visible
    /// ones play, staggered (`AnimatedAvatarRounds`).
    case rounds(picks: ClosedRange<Int>)
    /// One avatar at a time, in `order`: the next starts when the previous
    /// play ends, and the wave starts again after a pause.
    case sequence(order: SequenceOrder)
    /// Plays when it first shows on its screen, a beat after, then follows
    /// `then`.
    case firstAppearance(then: AvatarMotionRule)
    /// Plays when the person shown changes on screen; the first one rests. A
    /// fresh view standing for a change (`AnimatedAvatarPlayer.standsForChange`)
    /// plays once on screen.
    case change
    /// Plays once when a fresh view shows on screen, its sheet landed.
    case arrival

    /// The order of a sequence.
    public enum SequenceOrder: String, Sendable, CaseIterable {
        /// By position on screen, top row first.
        case topToBottom
        /// A horizontal row, leading first.
        case leadingToTrailing
        /// The rows the host raised (`AvatarMotionPriority.raised`: unread)
        /// first, then the others, each top to bottom.
        case unreadFirst
    }

    /// The rule the conductor runs for its screen: the rounds or the
    /// sequence, after a first appearance; nil when nothing is conducted
    /// (`.off`, `.change`, `.arrival`).
    var conducted: AvatarMotionRule? {
        switch self {
        case .rounds, .sequence: self
        case .firstAppearance(let then): then.conducted
        case .off, .change, .arrival: nil
        }
    }

    /// The rule as `-avatar-motion` writes it: `off`, `rounds:1-3`,
    /// `sequence:unreadFirst`, `first:rounds:1-1`, `change`, `arrival`.
    public var description: String {
        switch self {
        case .off: "off"
        case .rounds(let picks): "rounds:\(picks.lowerBound)-\(picks.upperBound)"
        case .sequence(let order): "sequence:\(order.rawValue)"
        case .firstAppearance(.off): "first"
        case .firstAppearance(let then): "first:\(then)"
        case .change: "change"
        case .arrival: "arrival"
        }
    }

    /// Reads `description`'s form back. `rounds` alone is `standardPicks`,
    /// `sequence` alone is top to bottom, `first` alone plays only once.
    init?(spec: Substring, standardPicks: ClosedRange<Int>) {
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard let head = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1] : nil
        switch head {
        case "off": self = .off
        case "change": self = .change
        case "arrival": self = .arrival
        case "rounds":
            guard let rest else {
                self = .rounds(picks: standardPicks)
                return
            }
            let bounds = rest.split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.first else { return nil }
            let high = max(low, bounds.last ?? low)
            self = .rounds(picks: max(1, low)...max(1, high))
        case "sequence":
            guard let rest else {
                self = .sequence(order: .topToBottom)
                return
            }
            guard let order = SequenceOrder(rawValue: String(rest)) else { return nil }
            self = .sequence(order: order)
        case "first":
            guard let rest else {
                self = .firstAppearance(then: .off)
                return
            }
            guard let then = AvatarMotionRule(spec: rest, standardPicks: standardPicks) else { return nil }
            self = .firstAppearance(then: then)
        default: return nil
        }
    }
}

/// A screen's name in the table (`AvatarMotionPolicy`), and in
/// `-avatar-motion`. A screen declares it once, on its view or its
/// controller, and every avatar under it follows the table's rule:
/// `traitOverrides.avatarMotionScreen = .messages`.
public struct AvatarMotionScreen: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Messages, the conversations list and the requests list
    /// (`ConversationRowView`, `MessageRequestCell`).
    public static let messages = AvatarMotionScreen(rawValue: "messages")
    /// A conversation's thread: the avatars beside its messages.
    public static let thread = AvatarMotionScreen(rawValue: "thread")
    /// A conversation's header pill.
    public static let threadHeader = AvatarMotionScreen(rawValue: "thread-header")
    /// Posts in lists, their 40 pt author: the profile, the place page, post
    /// sets.
    public static let posts = AvatarMotionScreen(rawValue: "posts")
    /// A hero page's header (`HeroHeaderView`): a profile's, a place's.
    public static let profileHeader = AvatarMotionScreen(rawValue: "profile-header")
    /// The media pages' author pill (`SnapAuthorIdentityView`).
    public static let authorPill = AvatarMotionScreen(rawValue: "author-pill")
    /// The comments panel.
    public static let comments = AvatarMotionScreen(rawValue: "comments")
    /// Search: the app's and the inbox's.
    public static let search = AvatarMotionScreen(rawValue: "search")
    /// Followers and following lists.
    public static let personLists = AvatarMotionScreen(rawValue: "person-lists")
    /// Suggested people.
    public static let suggestions = AvatarMotionScreen(rawValue: "suggestions")
    /// The map.
    public static let map = AvatarMotionScreen(rawValue: "map")
}

/// Where an avatar ranks in a sequence that orders by it
/// (`.sequence(order: .unreadFirst)`): its host raises an unread row.
public enum AvatarMotionPriority: Int, Sendable, Comparable {
    case normal
    case raised

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// EVERY SCREEN'S AVATAR MOTION, IN ONE TABLE (#2454): where the owner tunes
/// who plays, where, in what order. A screen missing from it keeps the
/// random rounds (`AnimatedAvatarRounds.Tuning.picks`), so nothing changes by
/// accident. The global limits stay above every rule: Reduce Motion, Low
/// Power Mode, idle calm, `AnimatedAvatarPlayer.minimumDiameter` and
/// `maxConcurrent`.
///
/// In DEBUG, `-avatar-motion` overrides screens on the device:
/// `-avatar-motion "messages=sequence:unreadFirst comments=off"`
/// (`AvatarMotionRule.description` for each rule's form).
public struct AvatarMotionPolicy: Equatable, Sendable {
    public var rules: [AvatarMotionScreen: AvatarMotionRule]

    public init(rules: [AvatarMotionScreen: AvatarMotionRule]) {
        self.rules = rules
    }

    /// The starting table (the owner tunes it afterwards).
    public static let standard = AvatarMotionPolicy(rules: [
        // Calm, one face at a time; a group plays its first face.
        .messages: .sequence(order: .unreadFirst),
        .thread: .off,
        .threadHeader: .arrival,
        .posts: .rounds(picks: 1...1),
        // Large and alone: a first display, then the rounds pick it again (a
        // face that played once and never again read as broken). A tap
        // replays it (`AnimatedAvatarPlayer.replay`).
        .profileHeader: .firstAppearance(then: .rounds(picks: 1...1)),
        .authorPill: .change,
        // Reading screens.
        .comments: .off,
        .search: .off,
        .personLists: .off,
        .suggestions: .off,
        .map: .off
    ])

    /// `-avatar-motion`'s rules over `base`; `base` without the flag. An
    /// entry that does not read is skipped.
    static func launch(_ arguments: [String], over base: AvatarMotionPolicy = .standard,
                       standardPicks: ClosedRange<Int>) -> AvatarMotionPolicy {
        var policy = base
        guard let spec = LaunchArgument.avatarMotion.value(in: arguments) else { return policy }
        for pair in spec.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let rule = AvatarMotionRule(spec: parts[1], standardPicks: standardPicks) else {
                continue
            }
            policy.rules[AvatarMotionScreen(rawValue: String(parts[0]))] = rule
        }
        return policy
    }
}

/// The screen an avatar is drawn in, with that screen's memory of the
/// avatars that already played their first display — one per declaration,
/// so a screen pushed again is a new screen, and a cell reused within one
/// screen plays a face once.
@MainActor
public final class AvatarMotionPlace: Equatable {
    public let screen: AvatarMotionScreen
    /// The avatars that played their first display here.
    var firstShown: Set<URL> = []

    public init(screen: AvatarMotionScreen) {
        self.screen = screen
    }

    /// One place by identity: the trait system compares values to tell a
    /// change.
    public nonisolated static func == (lhs: AvatarMotionPlace, rhs: AvatarMotionPlace) -> Bool { lhs === rhs }
}

/// A screen's avatar motion as a trait (#2454): set once on a screen's view
/// or controller, inherited by every avatar under it. Nil (the default): no
/// screen declared any, and the rounds play.
///
/// ⚠️ A VALUE, NOT A SERVICE: ADR 0016 keeps traits for app-wide services
/// only; this is UIKit's own use of a trait (like the interface style), a
/// fact about where a view is drawn.
public struct AvatarMotionTrait: UITraitDefinition {
    public static var defaultValue: AvatarMotionPlace? { nil }
    public static var name: String { "AvatarMotion" }
}

extension UITraitCollection {
    /// Where the avatars in this environment are drawn (`AvatarMotionTrait`).
    public var avatarMotionPlace: AvatarMotionPlace? { self[AvatarMotionTrait.self] }
}

extension UIMutableTraits {
    /// Declares the screen a view or a controller draws, for everything under
    /// it: `traitOverrides.avatarMotionScreen = .messages`. Each declaration is
    /// a new screen, with its own memory of first displays.
    @MainActor
    public var avatarMotionScreen: AvatarMotionScreen? {
        get { self[AvatarMotionTrait.self]?.screen }
        set { self[AvatarMotionTrait.self] = newValue.map(AvatarMotionPlace.init) }
    }
}
