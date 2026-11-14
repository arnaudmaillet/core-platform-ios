import CoreModels
import Foundation
import Testing

/// The one box for block-observer tokens (#2390): what it keeps is heard
/// until it goes, a replacement unregisters the previous tokens, and it
/// unregisters from the center the tokens came from.
@MainActor
struct NotificationTokensTests {
    private let name = Notification.Name("NotificationTokensTests.ping")

    /// A private center, so no other suite's posts reach these observers.
    private let center = NotificationCenter()

    @MainActor private final class Counter {
        var value = 0
    }

    @Test func whatItKeepsIsHeardUntilItGoes() {
        let heard = Counter()
        var tokens: NotificationTokens? = NotificationTokens(center: center)
        tokens?.observe(name) { heard.value += 1 }
        center.post(name: name, object: nil)
        #expect(heard.value == 1)
        tokens = nil
        center.post(name: name, object: nil)
        #expect(heard.value == 1)
    }

    @Test func aReplacementUnregistersThePreviousTokens() {
        let heard = Counter()
        let tokens = NotificationTokens(center: center)
        let register = { [center, name] in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { heard.value += 1 }
            }
        }
        tokens.replace(with: [register()])
        tokens.replace(with: [register()])
        center.post(name: name, object: nil)
        #expect(heard.value == 1)
    }

    @Test func removeAllEmptiesIt() {
        let heard = Counter()
        let tokens = NotificationTokens(center: center)
        #expect(tokens.isEmpty)
        tokens.observe(name) { heard.value += 1 }
        #expect(!tokens.isEmpty)
        tokens.removeAll()
        #expect(tokens.isEmpty)
        center.post(name: name, object: nil)
        #expect(heard.value == 0)
    }
}
