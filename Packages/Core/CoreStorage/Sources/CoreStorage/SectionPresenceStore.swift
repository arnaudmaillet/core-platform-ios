import Foundation

/// Which sections a screen showed last time, and how many items each held
/// (#1756, the loading rule): a cold load draws a structural skeleton only
/// for a section known to be there, so the content lands where the bone was
/// and no bone vanishes because its section turned out empty.
///
/// Per PROFILE (`StorageScope`): whether a viewer has friends or follows
/// anyone is theirs. A section never seen has no entry (`count` nil): the
/// screen then decides from what it already knows, or shows no skeleton and
/// lets the section fade in.
public final class SectionPresenceStore: @unchecked Sendable {
    public static let shared = SectionPresenceStore()

    private let defaults: UserDefaults
    private let scope: StorageScope

    public init(defaults: UserDefaults = .standard, scope: StorageScope = .shared) {
        self.defaults = defaults
        self.scope = scope
    }

    private func key(_ screen: String, _ section: String) -> String {
        scope.profileKey("sectionPresence.\(screen).\(section)")
    }

    /// How many items `section` of `screen` held when it last loaded: 0 when
    /// it was empty (absent), nil when it has never loaded here.
    public func count(screen: String, section: String) -> Int? {
        let key = key(screen, section)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    /// Remembers what `section` of `screen` held once its data answered.
    public func remember(_ count: Int, screen: String, section: String) {
        defaults.set(max(0, count), forKey: key(screen, section))
    }
}
