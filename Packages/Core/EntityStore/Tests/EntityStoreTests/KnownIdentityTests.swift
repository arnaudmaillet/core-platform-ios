import CoreModels
import Foundation
import Testing
@testable import EntityStore

/// What is known of a person before their profile loads (#1858): the
/// origin's stub, then the store, and nothing invented.
@MainActor
struct KnownIdentityTests {
    private static let avatar = URL(string: "https://example.test/ava.jpg")!
    private static let id = ProfileID("ava")

    private static func full() -> AuthorSummary {
        AuthorSummary(id: id, handle: "ava", displayName: "Ava Moreau", avatarURL: avatar, avatarFrameID: "frame.gold")
    }

    @Test func theStubAloneIsTheIdentity() {
        let store = EntityStore()
        let stub = ProfileIdentityStub(handle: "ava", displayName: "Ava", isFollowing: true, avatarURL: Self.avatar)
        #expect(store.knownIdentity(of: Self.id, stub: stub) == stub)
    }

    @Test func theStoreAloneIsTheIdentity() {
        let store = EntityStore()
        store.upsert(Self.full())
        let known = store.knownIdentity(of: Self.id, stub: nil)
        #expect(known?.handle == "ava")
        #expect(known?.displayName == "Ava Moreau")
        #expect(known?.avatarURL == Self.avatar)
        #expect(known?.avatarFrameID == "frame.gold")
        #expect(known?.isFollowing == nil, "a follow state invented")
        #expect(known?.hasBanner == nil)
    }

    /// The stub wins field by field; the store fills what it lacks.
    @Test func theStubWinsFieldByFieldAndTheStoreFillsTheRest() {
        let store = EntityStore()
        store.upsert(Self.full())
        let thread = ProfileIdentityStub(handle: nil, displayName: "Ava M.")
        let known = store.knownIdentity(of: Self.id, stub: thread)
        #expect(known?.displayName == "Ava M.", "the origin's name lost")
        #expect(known?.handle == "ava", "the store's handle not used")
        #expect(known?.avatarURL == Self.avatar)
        #expect(known?.avatarFrameID == "frame.gold")
    }

    @Test func nobodyKnowsThePerson() {
        #expect(EntityStore().knownIdentity(of: Self.id, stub: nil) == nil)
    }

    /// The follow state from the viewer's relation, when the stub has none —
    /// and only a relation that says it: a pending request or a block is not
    /// "not following".
    @Test func theFollowStateComesFromTheRelation() {
        let store = EntityStore()
        store.upsert(Self.full())
        store.setRelation(.mutual, for: Self.id)
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.isFollowing == true)
        store.setRelation(.followedBy, for: Self.id)
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.isFollowing == false)
        store.setRelation(.requested, for: Self.id)
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.isFollowing == nil)
        let origin = ProfileIdentityStub(handle: "ava", displayName: "Ava", isFollowing: true)
        #expect(store.knownIdentity(of: Self.id, stub: origin)?.isFollowing == true, "the origin's answer lost")
    }

    /// ⚠️ A ROW'S THIN SUMMARY NEVER ERASES A FULL ONE: a comment's author
    /// with no avatar, seen after the profile, keeps the avatar and frame.
    @Test func aThinSummaryAfterAFullOneErasesNothing() {
        let store = EntityStore()
        store.upsert(Self.full())
        store.saw([AuthorSummary(id: Self.id, handle: "", displayName: "Ava", avatarURL: nil)])
        let summary = store.profile(Self.id)?.summary
        #expect(summary?.avatarURL == Self.avatar)
        #expect(summary?.avatarFrameID == "frame.gold")
        #expect(summary?.handle == "ava")
        #expect(summary?.displayName == "Ava Moreau")
    }

    /// A row fills what the store did not know.
    @Test func aRowFillsWhatTheStoreLacked() {
        let store = EntityStore()
        store.saw([AuthorSummary(id: Self.id, handle: "ava", displayName: "Ava", avatarURL: nil)])
        store.saw([AuthorSummary(id: Self.id, handle: "ava", displayName: "Ava", avatarURL: Self.avatar)])
        #expect(store.profile(Self.id)?.summary?.avatarURL == Self.avatar)
        // The full profile, read fresh, replaces it.
        store.upsert(AuthorSummary(id: Self.id, handle: "ava.m", displayName: "Ava Moreau", avatarURL: nil))
        #expect(store.profile(Self.id)?.summary?.handle == "ava.m")
        #expect(store.profile(Self.id)?.summary?.avatarURL == nil, "a fresh profile with no picture keeps one")
    }

    /// The banner a profile taught (#1859) reaches the next opening, and a
    /// feed page's author — which never says — does not erase it.
    @Test func theBannerAProfileTaughtIsKept() {
        let store = EntityStore()
        store.loaded(AuthorSummary(id: Self.id, handle: "ava", displayName: "Ava", avatarURL: nil, hasBanner: true))
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.hasBanner == true)
        let post = Post(id: PostID("p1"), authorID: Self.id, caption: "", attachments: [], publishedAt: Date())
        store.upsert([FeedEntry(post: post, author: Self.full())])
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.hasBanner == true, "a feed page erased the banner hint")
        #expect(store.knownIdentity(of: Self.id, stub: nil)?.avatarFrameID == "frame.gold", "the fresh author not applied")
        // The origin's own answer wins.
        let origin = ProfileIdentityStub(handle: "ava", displayName: "Ava", hasBanner: false)
        #expect(store.knownIdentity(of: Self.id, stub: origin)?.hasBanner == false)
    }
}
