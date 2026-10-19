import Foundation
import Testing
@testable import Feed

/// For You's content contexts are gone (#1423): a device that had chosen a
/// mode keeps no stored choice after the update.
@MainActor
struct ForYouRetiredContextsTests {
    @Test func theStoredChoiceIsForgotten() {
        let name = "foryou-retired-contexts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("work", forKey: "foryou.context.v2")
        defaults.set("focus", forKey: "foryou.context")
        defaults.set("kept", forKey: "foryou.unrelated")

        FeedFeatureBuilder.forgetRetiredForYouModes(in: defaults)

        #expect(defaults.object(forKey: "foryou.context.v2") == nil, "the v2 choice survived")
        #expect(defaults.object(forKey: "foryou.context") == nil, "the v1 choice survived")
        #expect(defaults.string(forKey: "foryou.unrelated") == "kept", "it removed more than the contexts")
    }
}
