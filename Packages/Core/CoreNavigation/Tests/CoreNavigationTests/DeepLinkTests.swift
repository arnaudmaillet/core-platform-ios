import Foundation
import Testing
@testable import CoreNavigation

/// Links into the app: the web addresses it shares, and its own scheme (#524).
struct DeepLinkTests {
    private func route(_ link: String) -> AppRoute? {
        URL(string: link).flatMap(AppRoute.init(deepLink:))
    }

    @Test func aProfileLink() {
        #expect(route("https://core-platform.click/@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(
            route("https://www.core-platform.click/@Kenji.Dev") == .profileHandle("kenji.dev"),
            "handles are stored lowercased"
        )
        #expect(route("https://core-platform.click/@kenji.dev/") == .profileHandle("kenji.dev"))
        #expect(route("https://core-platform.click/@kenji.dev?ref=share") == .profileHandle("kenji.dev"))
    }

    @Test func aTagLink() {
        #expect(route("https://core-platform.click/tag/travel") == .hashtag("travel"))
        #expect(route("https://core-platform.click/tag/Travel") == .hashtag("travel"))
        #expect(route("https://core-platform.click/tag/%E6%9D%B1%E4%BA%AC") == .hashtag("東京"))
    }

    /// A QR code or shared link (#412): the token as issued, case kept.
    @Test func aShareTokenLink() {
        #expect(
            route("https://core-platform.click/s/Ab3_x-Yz09Qw8RtUvWxYzA")
                == .profileShareToken("Ab3_x-Yz09Qw8RtUvWxYzA")
        )
        #expect(
            route("https://www.core-platform.click/s/Ab3_x-Yz09Qw8RtUvWxYzA?src=qr")
                == .profileShareToken("Ab3_x-Yz09Qw8RtUvWxYzA")
        )
        #expect(route("wynn://s/Ab3_x-Yz09Qw8RtUvWxYzA") == .profileShareToken("Ab3_x-Yz09Qw8RtUvWxYzA"))
        #expect(route("https://core-platform.click/s/short") == nil, "too short for a token")
        #expect(route("https://core-platform.click/s/has+plus=padding==") == nil, "not URL-safe")
        #expect(route("https://core-platform.click/s/") == nil)
    }

    /// A place's share link (#985): a country by its code, a city by its
    /// point and name — what the server lists posts by.
    @Test func aPlaceLink() {
        #expect(route("https://core-platform.click/place/country/FR") == .place(.country(code: "FR")))
        #expect(route("https://core-platform.click/place/country/fr") == .place(.country(code: "FR")))
        #expect(
            route("https://core-platform.click/place/city/48.8566,2.3522?name=Paris&country=fr")
                == .place(.city(latitude: 48.8566, longitude: 2.3522, name: "Paris", countryCode: "FR"))
        )
        #expect(
            route("https://core-platform.click/place/city/-33.8688,151.2093?name=Sydney")
                == .place(.city(latitude: -33.8688, longitude: 151.2093, name: "Sydney", countryCode: nil))
        )
        #expect(route("wynn:/place/country/JP") == .place(.country(code: "JP")))
        #expect(route("https://core-platform.click/place/country/FRA") == nil, "not alpha-2")
        #expect(route("https://core-platform.click/place/city/48.8566,2.3522") == nil, "a city needs its name")
        #expect(route("https://core-platform.click/place/city/95,2?name=X") == nil, "latitude out of range")
        #expect(route("https://core-platform.click/place/planet/earth") == nil)
    }

    /// What a place shares is what opens it again.
    @Test func aPlaceLinkRoundTrips() throws {
        let places: [PlaceLink] = [
            .country(code: "FR"),
            .city(latitude: 48.8566, longitude: 2.3522, name: "Saint-Étienne & co", countryCode: "FR"),
            .city(latitude: -33.8688, longitude: 151.2093, name: "Sydney", countryCode: nil),
        ]
        for place in places {
            let url = try #require(place.url)
            #expect(url.host() == AppRoute.webHost)
            #expect(AppRoute(deepLink: url) == .place(place), "\(url)")
        }
    }

    @Test func theAppsOwnScheme() {
        #expect(route("wynn://@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(route("wynn:/@kenji.dev") == .profileHandle("kenji.dev"))
        #expect(route("wynn://tag/travel") == .hashtag("travel"))
        #expect(route("wynn:///tag/travel?x=1") == .hashtag("travel"))
    }

    @Test func whatTheAppDoesNotKnow() {
        #expect(route("https://example.com/@kenji.dev") == nil, "another host")
        // The mock's own place identity is not a link (#985).
        #expect(route("https://core-platform.click/place/city:paris") == nil)
        #expect(route("https://core-platform.click/@k") == nil, "too short for a handle")
        #expect(route("https://core-platform.click/@kenji dev") == nil)
        #expect(route("https://core-platform.click/tag/1") == nil, "a tag needs a letter")
        #expect(route("https://core-platform.click/tag/travel/extra") == nil)
        #expect(route("https://core-platform.click/") == nil)
        #expect(route("other://@kenji.dev") == nil)
    }
}

/// A family supervision invite (#417): the code read as the server reads it.
struct SupervisionInviteLinkTests {
    private func route(_ link: String) -> AppRoute? {
        URL(string: link).flatMap(AppRoute.init(deepLink:))
    }

    @Test func anInviteLinkOpensTheCode() {
        #expect(route("https://core-platform.click/family/K7M2Q9XRTD") == .supervisionInvite("K7M2Q9XRTD"))
        #expect(route("https://core-platform.click/family/k7m2q-9xrtd") == .supervisionInvite("K7M2Q9XRTD"))
        #expect(route("wynn:/family/K7M2Q9XRTD") == .supervisionInvite("K7M2Q9XRTD"))
        #expect(route("https://core-platform.click/family/K7M2Q9XRT") == nil, "one short")
        #expect(route("https://core-platform.click/family/K7M2Q9XRTDX") == nil, "one long")
        #expect(route("https://core-platform.click/family/") == nil)
    }

    /// Typing ignores case, spaces and dashes, like the server.
    @Test func aCodeIsReadIgnoringCaseSpacesAndDashes() {
        #expect(SupervisionInviteCode.normalized(" k7m2q 9xr-td ") == "K7M2Q9XRTD")
        #expect(SupervisionInviteCode.normalized("K7M2Q9XRT!") == nil)
        #expect(SupervisionInviteCode.normalized("K7M2Q9XRTÉ") == nil)
        #expect(SupervisionInviteCode.display("K7M2Q9XRTD") == "K7M2Q-9XRTD")
    }

    /// The QR code and the share sheet carry a link the app opens back.
    @Test func theLinkRoundTrips() throws {
        let link = try #require(SupervisionInviteCode.link(for: "K7M2Q9XRTD"))
        #expect(link.absoluteString == "https://core-platform.click/family/K7M2Q9XRTD")
        #expect(AppRoute(deepLink: link) == .supervisionInvite("K7M2Q9XRTD"))
    }
}
