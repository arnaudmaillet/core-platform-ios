import CacheKit
import Foundation
import LocalStore
import OSLog

/// The settings screens' last answers on the device (#1776), in the
/// LocalStore: a settings screen opens on what the server last said, with no
/// skeleton, then revalidates in place. They were fetched at every visit.
///
/// One entity per screen (`settings.value`, id the record's `name`), each a
/// versioned JSON record of the screen's value, its enums in fixed words. The
/// viewer's own settings, so `retained`; the store's viewer scope keeps them
/// the viewer's (a profile switch is another viewer: the settings are the
/// profile's), and a sign-out wipes them with the other device caches.
///
/// Reads are synchronous (the screen's first frame); writes go to a serial
/// queue, each as the viewer the screen opened for.
package final class SettingsLocalCache: Sendable {
    package static let entityType = "settings.value"

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.settings-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "settings-cache")

    package init(store: LocalStore) {
        self.store = store
    }

    /// Who the screen is open for, captured as it opens.
    package var viewer: LocalStoreViewer? { store.currentViewer }

    package func value<Record: SettingsRecord>(_ record: Record.Type) -> Record.Value? {
        guard let entity = store.entity(LocalEntityKey(type: Self.entityType, id: Record.name)),
              entity.format == Record.format,
              let decoded = try? JSONDecoder().decode(Record.self, from: entity.payload) else { return nil }
        return decoded.value
    }

    package func store<Record: SettingsRecord>(_ value: Record.Value, as record: Record.Type, viewer: LocalStoreViewer?) {
        guard let payload = try? JSONEncoder().encode(Record(value)) else { return }
        let write = LocalEntityWrite(
            key: LocalEntityKey(type: Self.entityType, id: Record.name), payload: payload, format: Record.format,
            lifetime: LocalStorePolicy.transcriptLifetime, tier: .retained
        )
        let store = self.store
        let logger = self.logger
        queue.async {
            do {
                try store.write([write], as: viewer)
            } catch {
                logger.error("settings cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for every write queued so far. Tests only.
    package func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }
}

/// One settings screen's value as stored.
package protocol SettingsRecord: Codable, Sendable {
    associatedtype Value
    /// The entity's id: the screen's.
    static var name: String { get }
    static var format: Int { get }
    init(_ value: Value)
    /// Nil when a word in it is one this build does not know: a miss.
    var value: Value? { get }
}

extension SettingsRecord {
    package static var format: Int { 1 }
}

// MARK: - Records

package struct LocationSharingRecord: SettingsRecord {
    package static let name = "locationSharing"
    package var ghost: Bool
    package var cityLevel: Bool

    package init(_ value: LocationSharingSettings) {
        ghost = value.ghost
        cityLevel = value.cityLevel
    }

    package var value: LocationSharingSettings? {
        LocationSharingSettings(ghost: ghost, cityLevel: cityLevel)
    }
}

package struct ListPrivacyRecord: SettingsRecord {
    package static let name = "listPrivacy"
    package var followers: String
    package var following: String

    package init(_ value: ListPrivacy) {
        followers = Self.word(value.followers)
        following = Self.word(value.following)
    }

    package var value: ListPrivacy? {
        guard let followers = Self.audience(followers), let following = Self.audience(following) else { return nil }
        return ListPrivacy(followers: followers, following: following)
    }

    package static func word(_ audience: ListAudience) -> String {
        switch audience {
        case .everyone: "everyone"
        case .followers: "followers"
        case .mutuals: "mutuals"
        case .onlyMe: "onlyMe"
        }
    }

    package static func audience(_ word: String) -> ListAudience? {
        ListAudience.allCases.first { Self.word($0) == word }
    }
}

package struct ActivityDiscoveryRecord: SettingsRecord {
    package static let name = "activityDiscovery"
    package var activityStatus: Bool
    package var readReceipts: Bool
    package var findableInSearch: Bool
    package var findableByPhone: Bool
    package var findableByEmail: Bool
    package var reachableByLink: Bool
    package var inSuggestions: Bool

    package init(_ value: ActivityDiscoverySettings) {
        activityStatus = value.activityStatus
        readReceipts = value.readReceipts
        findableInSearch = value.findableInSearch
        findableByPhone = value.findableByPhone
        findableByEmail = value.findableByEmail
        reachableByLink = value.reachableByLink
        inSuggestions = value.inSuggestions
    }

    package var value: ActivityDiscoverySettings? {
        var settings = ActivityDiscoverySettings()
        settings.activityStatus = activityStatus
        settings.readReceipts = readReceipts
        settings.findableInSearch = findableInSearch
        settings.findableByPhone = findableByPhone
        settings.findableByEmail = findableByEmail
        settings.reachableByLink = reachableByLink
        settings.inSuggestions = inSuggestions
        return settings
    }
}

package struct CommentFiltersRecord: SettingsRecord {
    package static let name = "commentFilters"
    package var hiddenWords: [String]
    package var filtersOffensive: Bool

    package init(_ value: CommentFilterSettings) {
        hiddenWords = value.hiddenWords
        filtersOffensive = value.filtersOffensive
    }

    package var value: CommentFilterSettings? {
        var settings = CommentFilterSettings()
        settings.hiddenWords = hiddenWords
        settings.filtersOffensive = filtersOffensive
        return settings
    }
}

package struct NotificationPreferencesRecord: SettingsRecord {
    package static let name = "notificationPreferences"
    package var muted: [String]
    package var emailed: [String]
    package var pausedUntil: Date?
    package var quietStart: Int?
    package var quietEnd: Int?

    package init(_ value: NotificationPreferences) {
        muted = NotificationCategory.allCases.filter(value.mutedCategories.contains).map(Self.word)
        emailed = NotificationCategory.allCases.filter(value.emailCategories.contains).map(Self.word)
        pausedUntil = value.pausedUntil
        quietStart = value.quietHours?.startMinute
        quietEnd = value.quietHours?.endMinute
    }

    package var value: NotificationPreferences? {
        // A word this build does not know is a category it cannot show: left
        // out, as an unknown category from the server is.
        var preferences = NotificationPreferences(
            mutedCategories: Set(muted.compactMap(Self.category)),
            // A pause past its end is no pause.
            pausedUntil: pausedUntil.flatMap { $0 > Date() ? $0 : nil },
            quietHours: quietStart.flatMap { start in quietEnd.map { QuietHours(startMinute: start, endMinute: $0) } }
        )
        preferences.emailCategories = Set(emailed.compactMap(Self.category))
        return preferences
    }

    package static func word(_ category: NotificationCategory) -> String { String(describing: category) }

    package static func category(_ word: String) -> NotificationCategory? {
        NotificationCategory.allCases.first { Self.word($0) == word }
    }
}

package struct InteractionLimitsRecord: SettingsRecord {
    package static let name = "interactionLimits"
    package var audience: String?
    package var until: Date?
    package var allowsSoundReuse: Bool

    package init(_ value: LimitInteractionsViewController.State) {
        audience = value.limit.map { $0.audience == .nonFollowers ? "nonFollowers" : "recentFollowers" }
        until = value.limit?.until
        allowsSoundReuse = value.allowsSoundReuse
    }

    package var value: LimitInteractionsViewController.State? {
        var limit: InteractionLimit?
        if let audience, let until {
            let decoded: InteractionLimitAudience
            switch audience {
            case "nonFollowers": decoded = .nonFollowers
            case "recentFollowers": decoded = .recentFollowers
            default: return nil
            }
            // A limit past its end is no limit.
            if until > Date() { limit = InteractionLimit(audience: decoded, until: until) }
        }
        return LimitInteractionsViewController.State(limit: limit, allowsSoundReuse: allowsSoundReuse)
    }
}

package struct WhatYouSeeRecord: SettingsRecord {
    package struct Value: Equatable, Sendable {
        package var level: SensitiveContentLevel
        package var personalized: Bool
        /// The age that decides whether Standard is offered, as last read.
        package var teen: Bool
    }

    package static let name = "whatYouSee"
    package var level: String
    package var personalized: Bool
    package var teen: Bool

    package init(_ value: Value) {
        level = value.level == .standard ? "standard" : "less"
        personalized = value.personalized
        teen = value.teen
    }

    package var value: Value? {
        let decoded: SensitiveContentLevel
        switch level {
        case "standard": decoded = .standard
        case "less": decoded = .less
        default: return nil
        }
        return Value(level: decoded, personalized: personalized, teen: teen)
    }
}

package struct ConsentsRecord: SettingsRecord {
    package struct Consent: Codable, Sendable {
        package var isGiven: Bool
        package var changedAt: Date?
    }

    package static let name = "consents"
    package var dataProcessing: Consent
    package var marketing: Consent
    package var analytics: Consent

    package init(_ value: AccountConsents) {
        dataProcessing = Consent(isGiven: value.dataProcessing.isGiven, changedAt: value.dataProcessing.changedAt)
        marketing = Consent(isGiven: value.marketing.isGiven, changedAt: value.marketing.changedAt)
        analytics = Consent(isGiven: value.analytics.isGiven, changedAt: value.analytics.changedAt)
    }

    package var value: AccountConsents? {
        AccountConsents(
            dataProcessing: .init(isGiven: dataProcessing.isGiven, changedAt: dataProcessing.changedAt),
            marketing: .init(isGiven: marketing.isGiven, changedAt: marketing.changedAt),
            analytics: .init(isGiven: analytics.isGiven, changedAt: analytics.changedAt)
        )
    }
}

/// A settings screen that opens on its stored answer (#1776).
@MainActor
package protocol SettingsCaching: AnyObject {
    var settingsCache: SettingsLocalCache? { get set }
}

extension SettingsCaching {
    /// The screen, set to open on `cache`'s answer: what the builder hands
    /// out.
    package func cachingSettings(in cache: SettingsLocalCache?) -> Self {
        settingsCache = cache
        return self
    }
}

extension LocationSharingViewController: SettingsCaching {}
extension ListPrivacyViewController: SettingsCaching {}
extension ActivityDiscoveryViewController: SettingsCaching {}
extension HiddenWordsViewController: SettingsCaching {}
extension LimitInteractionsViewController: SettingsCaching {}
extension NotificationSettingsViewController: SettingsCaching {}
extension WhatYouSeeViewController: SettingsCaching {}
