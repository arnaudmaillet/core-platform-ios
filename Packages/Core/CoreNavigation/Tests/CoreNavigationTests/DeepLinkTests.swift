import Foundation
import Testing
@testable import CoreNavigation

/// Links into the app: the web addresses it shares, and its own scheme (#524).
struct DeepLinkTests {
    private func route(_ link: String) -> AppRoute? {
        URL(string: link).flatMap(AppRoute.init(deepLink:))
    }

    @Test func aProfileLink() {
        #expect(route("https://wynn.cn/@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(route("https://www.wynn.cn/@Kenji.Dev") == .profileHandle("kenji.dev"), "handles are stored lowercased")
        #expect(route("https://wynn.cn/@kenji.dev/") == .profileHandle("kenji.dev"))
        #expect(route("https://wynn.cn/@kenji.dev?ref=share") == .profileHandle("kenji.dev"))
    }

    @Test func aTagLink() {
        #expect(route("https://wynn.cn/tag/travel") == .hashtag("travel"))
        #expect(route("https://wynn.cn/tag/Travel") == .hashtag("travel"))
        #expect(route("https://wynn.cn/tag/%E6%9D%B1%E4%BA%AC") == .hashtag("東京"))
    }

    @Test func theAppsOwnScheme() {
        #expect(route("wynn://@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(route("wynn:/@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(route("wynn://tag/travel") == .hashtag("travel"))
        #expect(route("wynn:///tag/travel?x=1") == .hashtag("travel"))
    }

    @Test func whatTheAppDoesNotKnow() {
        #expect(route("https://example.com/@kenji.dev") == nil, "another host")
        #expect(route("https://wynn.cn/place/city:paris") == nil, "no place route yet")
        #expect(route("https://wynn.cn/@k") == nil, "too short for a handle")
        #expect(route("https://wynn.cn/@kenji dev") == nil)
        #expect(route("https://wynn.cn/tag/1") == nil, "a tag needs a letter")
        #expect(route("https://wynn.cn/tag/travel/extra") == nil)
        #expect(route("https://wynn.cn/") == nil)
        #expect(route("other://@kenji.dev") == nil)
    }
}
