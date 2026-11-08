// ⚠️ THE WHOLE FILE: DEBUG only — the haptics playground's sounds (#2193).
// In Release, `Haptics.play` stays the one table, with no lookup and no
// branch; a Core Haptics pattern becomes real only once the owner picks one
// for the catalog (a follow-up issue).
#if DEBUG
import AudioToolbox
import CoreHaptics
import UIKit

/// What the playground can play, and what a role can be given to try in the
/// app: one of UIKit's recipes, a Core Haptics pattern, or the system's long
/// vibration.
public enum HapticSound: Hashable, Sendable {
    case recipe(HapticRecipe)
    case pattern(HapticPattern)
    case systemVibration

    /// One line, with its values: what the exported catalog says.
    public var summary: String {
        switch self {
        case .recipe(let recipe): recipe.summary
        case .pattern(let pattern): pattern.summary
        case .systemVibration: "system vibration (kSystemSoundID_Vibrate)"
        }
    }

    /// Plays only where the hardware has a Taptic Engine and Core Haptics.
    public var needsCoreHaptics: Bool {
        if case .pattern = self { return true }
        return false
    }
}

extension HapticRecipe {
    /// UIKit's impact styles, in the order the playground lists them.
    public static let impactStyles: [HapticRecipe] = [
        .impact(.light, intensity: 1), .impact(.medium, intensity: 1), .impact(.heavy, intensity: 1),
        .impact(.soft, intensity: 1), .impact(.rigid, intensity: 1),
    ]
    /// UIKit's notification types.
    public static let notifications: [HapticRecipe] = [
        .notification(.success), .notification(.warning), .notification(.error),
    ]

    /// The same impact at `intensity`; any other recipe unchanged.
    public func at(intensity: CGFloat) -> HapticRecipe {
        if case .impact(let style, _) = self { return .impact(style, intensity: intensity) }
        return self
    }

    public var summary: String {
        switch self {
        case .selection:
            return "selection"
        case .impact(let style, let intensity):
            let name: String = switch style {
            case .light: "light"
            case .medium: "medium"
            case .heavy: "heavy"
            case .soft: "soft"
            case .rigid: "rigid"
            @unknown default: "style \(style.rawValue)"
            }
            return intensity < 1 ? "impact .\(name) at \(Self.format(intensity))" : "impact .\(name)"
        case .notification(let type):
            return switch type {
            case .success: "notification .success"
            case .warning: "notification .warning"
            case .error: "notification .error"
            @unknown default: "notification \(type.rawValue)"
            }
        }
    }

    static func format(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
}

// MARK: - Core Haptics patterns

/// A Core Haptics pattern, as plain values: what the playground builds from
/// its sliders, stores in an override, and exports.
public struct HapticPattern: Hashable, Sendable, Codable {
    public struct Event: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable { case transient, continuous }
        public var kind: Kind
        /// Seconds from the pattern's start.
        public var time: Double
        /// Seconds; continuous events only.
        public var duration: Double
        public var intensity: Double
        public var sharpness: Double
        /// Continuous events only, 0–1 (Core Haptics' `attackTime`).
        public var attack: Double
        /// Continuous events only, 0–1 (`decayTime`; the event is then not
        /// sustained, it fades out).
        public var decay: Double
        /// An intensity curve over a continuous event: (seconds, 0–1).
        public var curve: [CurvePoint]

        public static func tap(at time: Double = 0, intensity: Double, sharpness: Double) -> Event {
            Event(kind: .transient, time: time, duration: 0, intensity: intensity, sharpness: sharpness,
                  attack: 0, decay: 0, curve: [])
        }

        public static func buzz(
            at time: Double = 0, duration: Double, intensity: Double, sharpness: Double,
            attack: Double = 0, decay: Double = 0, curve: [CurvePoint] = []
        ) -> Event {
            Event(kind: .continuous, time: time, duration: duration, intensity: intensity, sharpness: sharpness,
                  attack: attack, decay: decay, curve: curve)
        }
    }

    public struct CurvePoint: Hashable, Sendable, Codable {
        public var time: Double
        public var value: Double
        public init(_ time: Double, _ value: Double) {
            self.time = time
            self.value = value
        }
    }

    public var name: String
    public var events: [Event]

    public init(name: String, events: [Event]) {
        self.name = name
        self.events = events
    }

    public var summary: String {
        let f = { (value: Double) in String(format: "%.2f", value) }
        let parts = events.map { event -> String in
            switch event.kind {
            case .transient:
                return "tap at \(f(event.time)) s, intensity \(f(event.intensity)), sharpness \(f(event.sharpness))"
            case .continuous:
                var text = "buzz at \(f(event.time)) s for \(f(event.duration)) s, intensity \(f(event.intensity)), "
                    + "sharpness \(f(event.sharpness)), attack \(f(event.attack)), decay \(f(event.decay))"
                if !event.curve.isEmpty {
                    text += ", curve " + event.curve.map { "\(f($0.time)) s → \(f($0.value))" }.joined(separator: ", ")
                }
                return text
            }
        }
        return "Core Haptics \"\(name)\": " + parts.joined(separator: "; ")
    }

    /// The ready patterns, to compare (#2193 § 2).
    public static let presets: [HapticPattern] = [
        HapticPattern(name: "Double tap", events: [
            .tap(at: 0, intensity: 1, sharpness: 0.6),
            .tap(at: 0.12, intensity: 1, sharpness: 0.6),
        ]),
        HapticPattern(name: "Heartbeat", events: [
            .tap(at: 0, intensity: 1, sharpness: 0.3),
            .tap(at: 0.15, intensity: 0.6, sharpness: 0.2),
            .tap(at: 0.8, intensity: 1, sharpness: 0.3),
            .tap(at: 0.95, intensity: 0.6, sharpness: 0.2),
        ]),
        HapticPattern(name: "Rising ramp", events: [
            .buzz(at: 0, duration: 0.6, intensity: 1, sharpness: 0.4,
                  curve: [CurvePoint(0, 0.1), CurvePoint(0.6, 1)]),
            .tap(at: 0.6, intensity: 1, sharpness: 0.8),
        ]),
        // A threshold's give, like the pull to go back's: a firm hit, then a
        // soft wobble settling.
        HapticPattern(name: "Jelly", events: [
            .tap(at: 0, intensity: 0.9, sharpness: 0.9),
            .tap(at: 0.08, intensity: 0.45, sharpness: 0.2),
            .tap(at: 0.15, intensity: 0.25, sharpness: 0.1),
            .buzz(at: 0.02, duration: 0.2, intensity: 0.35, sharpness: 0.05, decay: 0.2),
        ]),
        HapticPattern(name: "Rumble", events: [
            .buzz(at: 0, duration: 0.5, intensity: 0.8, sharpness: 0.1, curve: [
                CurvePoint(0, 0.8), CurvePoint(0.1, 0.4), CurvePoint(0.2, 0.8),
                CurvePoint(0.3, 0.4), CurvePoint(0.4, 0.8), CurvePoint(0.5, 0.3),
            ]),
        ]),
    ]

    func makeCHPattern() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        for event in self.events.sorted(by: { $0.time < $1.time }) {
            var parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
            ]
            switch event.kind {
            case .transient:
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: event.time))
            case .continuous:
                parameters.append(CHHapticEventParameter(parameterID: .attackTime, value: Float(event.attack)))
                if event.decay > 0 {
                    parameters.append(CHHapticEventParameter(parameterID: .decayTime, value: Float(event.decay)))
                    parameters.append(CHHapticEventParameter(parameterID: .sustained, value: 0))
                }
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous, parameters: parameters,
                    relativeTime: event.time, duration: event.duration
                ))
                if !event.curve.isEmpty {
                    curves.append(CHHapticParameterCurve(
                        parameterID: .hapticIntensityControl,
                        controlPoints: event.curve.map {
                            CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: Float($0.value))
                        },
                        relativeTime: event.time
                    ))
                }
            }
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
}

/// Plays `HapticPattern`s through one `CHHapticEngine`, built on first use
/// and started again after the system stops or resets it.
@MainActor
public final class HapticPatternPlayer {
    public static let shared = HapticPatternPlayer()

    /// False on the simulator: it has no Taptic Engine.
    public nonisolated static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    private var engine: CHHapticEngine?
    private var needsStart = true

    private init() {}

    /// Builds and starts the engine ahead of a gesture's moment.
    public func prepare() {
        _ = startedEngine()
    }

    public func play(_ pattern: HapticPattern) {
        guard let engine = startedEngine() else { return }
        do {
            let player = try engine.makePlayer(with: pattern.makeCHPattern())
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("haptic pattern \"\(pattern.name)\" failed: \(error)")
        }
    }

    private func startedEngine() -> CHHapticEngine? {
        guard Self.supportsHaptics else { return nil }
        if engine == nil {
            guard let made = try? CHHapticEngine() else { return nil }
            made.playsHapticsOnly = true
            made.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.needsStart = true }
            }
            made.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.needsStart = true
                    _ = self?.startedEngine()
                }
            }
            engine = made
        }
        if needsStart, let engine {
            do {
                try engine.start()
                needsStart = false
            } catch {
                print("haptic engine failed to start: \(error)")
                return nil
            }
        }
        return engine
    }
}

enum HapticSystemVibration {
    static func play() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

// MARK: - Storage

extension HapticSound: Codable {
    private enum CodingKeys: String, CodingKey { case kind, style, intensity, type, pattern }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "selection":
            self = .recipe(.selection)
        case "impact":
            let raw = try container.decode(Int.self, forKey: .style)
            let intensity = try container.decode(Double.self, forKey: .intensity)
            // Named through the recipes, never the generator's type (#1884).
            let impact = HapticRecipe.impactStyles.first {
                if case .impact(let style, _) = $0 { return style.rawValue == raw }
                return false
            }
            guard let impact else {
                throw DecodingError.dataCorruptedError(forKey: .style, in: container, debugDescription: "style \(raw)")
            }
            self = .recipe(impact.at(intensity: CGFloat(intensity)))
        case "notification":
            let raw = try container.decode(Int.self, forKey: .type)
            let notification = HapticRecipe.notifications.first {
                if case .notification(let type) = $0 { return type.rawValue == raw }
                return false
            }
            guard let notification else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "type \(raw)")
            }
            self = .recipe(notification)
        case "pattern":
            self = .pattern(try container.decode(HapticPattern.self, forKey: .pattern))
        case "vibration":
            self = .systemVibration
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recipe(.selection):
            try container.encode("selection", forKey: .kind)
        case .recipe(.impact(let style, let intensity)):
            try container.encode("impact", forKey: .kind)
            try container.encode(style.rawValue, forKey: .style)
            try container.encode(Double(intensity), forKey: .intensity)
        case .recipe(.notification(let type)):
            try container.encode("notification", forKey: .kind)
            try container.encode(type.rawValue, forKey: .type)
        case .pattern(let pattern):
            try container.encode("pattern", forKey: .kind)
            try container.encode(pattern, forKey: .pattern)
        case .systemVibration:
            try container.encode("vibration", forKey: .kind)
        }
    }
}

/// THE CANDIDATES (#2193 § 4): a sound given to a role to try in the app.
/// `Haptics.play(role)` plays it instead of the role's recipe, everywhere,
/// until it is reset. Stored in `UserDefaults`, so it survives a relaunch;
/// the debug dashboard shows a line while any is on.
@MainActor
public final class HapticOverrides {
    public static let shared = HapticOverrides(defaults: .standard)
    /// Posted on every change.
    public static let didChange = Notification.Name("HapticOverrides.didChange")
    static let key = "debug.haptics.overrides"

    private let defaults: UserDefaults
    private var sounds: [Haptic: HapticSound]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        sounds = Self.load(from: defaults)
    }

    public subscript(role: Haptic) -> HapticSound? {
        get { sounds[role] }
        set {
            sounds[role] = newValue
            save()
        }
    }

    public var isAnyOn: Bool { !sounds.isEmpty }
    /// The roles with a candidate, in the catalog's order.
    public var roles: [Haptic] { Haptic.allCases.filter { sounds[$0] != nil } }

    public func resetAll() {
        sounds = [:]
        save()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: sounds.map { ("\($0.key)", $0.value) })
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func load(from defaults: UserDefaults) -> [Haptic: HapticSound] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: HapticSound].self, from: data) else { return [:] }
        var sounds: [Haptic: HapticSound] = [:]
        for role in Haptic.allCases {
            if let sound = stored["\(role)"] { sounds[role] = sound }
        }
        return sounds
    }
}

// MARK: - The export

public enum HapticCatalogExport {
    /// The current mapping as text (#2193 § 5): each role, what it plays with
    /// its values, and whether that is today's recipe or a candidate.
    @MainActor
    public static func text(overrides: HapticOverrides) -> String {
        var lines = ["Haptic catalog (\(Haptic.allCases.count) roles)"]
        for role in Haptic.allCases {
            if let candidate = overrides[role] {
                lines.append("- \(role): CANDIDATE \(candidate.summary) (today: \(role.recipe.summary))")
            } else {
                lines.append("- \(role): \(role.recipe.summary) (today)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif
