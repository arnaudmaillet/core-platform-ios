import Foundation
import Testing
@testable import CoreStorage

/// The band's Background setting is gone with #2172's capsules (#2339): a
/// value an older build stored is ignored, never a failure that would reset
/// every other choice.
struct MediaCommentPreferencesTests {
    private static let legacy = Data("""
    {"showsReactionBand":true,"bandOpacity":0.6,"bandSpeed":"slow","bandBackgroundOpacity":0.4,\
    "showsSubtitles":false,"subtitleBackgroundOpacity":0.2,"mutedKeywords":["spoiler"],\
    "mutedHandles":["troll"],"avoidsPeople":true}
    """.utf8)

    @Test func oldPreferencesWithABandBackgroundDecodeWithoutIt() throws {
        let decoded = try JSONDecoder().decode(MediaCommentPreferences.self, from: Self.legacy)
        #expect(decoded.showsReactionBand)
        #expect(decoded.bandOpacity == 0.6)
        #expect(decoded.bandSpeed == .slow)
        #expect(!decoded.showsSubtitles)
        #expect(decoded.subtitleBackgroundOpacity == 0.2)
        #expect(decoded.mutedKeywords == ["spoiler"])
        #expect(decoded.mutedHandles == ["troll"])
        #expect(decoded.avoidsPeople)

        // Written back, the key is gone.
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["bandBackgroundOpacity"] == nil)
        #expect(try JSONDecoder().decode(MediaCommentPreferences.self, from: encoded) == decoded)
    }

    /// The store reads such a value as the viewer's choices, not the defaults.
    @Test func theStoreKeepsTheChoicesAroundAnOldBandBackground() throws {
        let suite = "media-comment-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Self.legacy, forKey: "mediaCommentPreferences")
        let preferences = MediaCommentPreferencesStore(defaults: defaults).preferences
        #expect(preferences != MediaCommentPreferences())
        #expect(preferences.bandSpeed == .slow)
        #expect(preferences.mutedHandles == ["troll"])
    }
}
