import CoreModels
import DesignSystem
import EntityStore
import Foundation
import MediaCore
import TestSupport
import Testing
import UIKit
@testable import Chat

/// The Messages inbox rows (#2049, the owner 2026-11-02): the unread count
/// under the time, and the face wearing the relation mark — the "+" included,
/// and live.
@MainActor
@Suite(.serialized)
struct InboxRelationMarkTests {
    private actor Graph: SocialGraphReading, SocialGraphWriting {
        var relations: [ProfileID: FollowRelation]
        var outcome: FollowOutcome?
        private(set) var reads = 0
        private(set) var follows: [ProfileID] = []

        init(_ relations: [ProfileID: FollowRelation], outcome: FollowOutcome? = .following) {
            self.relations = relations
            self.outcome = outcome
        }

        func set(_ relation: FollowRelation, for peer: ProfileID) { relations[peer] = relation }

        func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
            reads += 1
            guard let relation = relations[profileID] else { throw URLError(.badServerResponse) }
            return relation
        }

        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

        func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
            follows.append(profileID)
            guard let outcome else { throw URLError(.notConnectedToInternet) }
            return outcome
        }
    }

    private static let peer = ProfileID("peer-1")

    private func model(
        peers: [String] = ["peer-1"], unread: Int = 0, muted: Bool = false, pinned: Bool = false
    ) -> ConversationDisplayModel {
        ConversationDisplayModel(
            conversation: Conversation(
                id: ConversationID("c1"),
                title: "Ava Moreau",
                lastMessage: "hi",
                lastActivityAt: Date(timeIntervalSince1970: 0),
                otherMemberIDs: peers.map { ProfileID($0) },
                lastMessageIsMine: false,
                lastMessageID: "c1-latest",
                isUnread: unread > 0,
                unreadCount: unread
            ),
            now: Date(timeIntervalSince1970: 60),
            isPinned: pinned,
            isMuted: muted,
            isUnread: unread > 0,
            unreadCount: unread
        )
    }

    private func laidOutRow(
        _ model: ConversationDisplayModel, mark: PersonPill.Badge = .none
    ) -> (ConversationRowView, String) {
        let row = ConversationRowView()
        let label = row.configure(with: model, mark: mark)
        row.frame = CGRect(x: 0, y: 0, width: 402, height: 76)
        row.setNeedsLayout()
        row.layoutIfNeeded()
        return (row, label)
    }

    // MARK: - The count under the time

    /// The pill's text: the count, "99+" past 99.
    @Test func thePillReadsTheCount() {
        #expect(UnreadCountPill.text(for: 1) == "1")
        #expect(UnreadCountPill.text(for: 12) == "12")
        #expect(UnreadCountPill.text(for: 120) == "99+")
    }

    /// The pill is the solid unread mark, as every pill and badge (#2062,
    /// the owner: never a gradient), with no ring (#2088).
    @Test func thePillIsTheSolidMark() {
        let pill = UnreadCountPill()
        #expect(pill.layer.borderWidth == 0)
        #expect(pill.backgroundColor == Palette.counter)
        #expect(!(pill.layer.sublayers ?? []).contains { $0 is CAGradientLayer })
    }

    /// The count sits under the time, at the row's trailing edge, and the
    /// face carries none.
    @Test(arguments: [1, 12, 120])
    func theCountSitsUnderTheTime(_ count: Int) throws {
        let (row, _) = laidOutRow(model(unread: count))
        let pill = try #require(row.debugUnreadPill)
        let time = row.debugTimeLabel
        #expect(!pill.isHidden)
        #expect(pill.shownText == UnreadCountPill.text(for: count))
        let pillFrame = pill.convert(pill.bounds, to: row)
        let timeFrame = time.convert(time.bounds, to: row)
        #expect(pillFrame.minY >= timeFrame.maxY, "the pill is not under the time")
        #expect(abs(pillFrame.maxX - timeFrame.maxX) < 0.5, "the pill is not at the time's trailing edge")
    }

    /// No pill at zero, nor on a read row.
    @Test func noPillAtZero() throws {
        let (row, _) = laidOutRow(model(unread: 0))
        #expect(try #require(row.debugUnreadPill).isHidden)
    }

    /// The glyphs come first, then the pill at the edge.
    @Test func mutedAndPinnedSitInboardOfThePill() throws {
        let (row, _) = laidOutRow(model(unread: 3, muted: true, pinned: true))
        let pill = try #require(row.debugUnreadPill)
        let pillFrame = pill.convert(pill.bounds, to: row)
        for glyph in row.debugGlyphs {
            #expect(glyph.convert(glyph.bounds, to: row).maxX <= pillFrame.minX, "a glyph past the pill")
        }
    }

    /// Nothing shifts: the time sits at the same height with or without the
    /// pill.
    @Test func theTimeDoesNotMoveForThePill() {
        let (read, _) = laidOutRow(model(unread: 0))
        let (unread, _) = laidOutRow(model(unread: 5))
        let readTime = read.debugTimeLabel.convert(read.debugTimeLabel.bounds, to: read)
        let unreadTime = unread.debugTimeLabel.convert(unread.debugTimeLabel.bounds, to: unread)
        #expect(abs(readTime.minY - unreadTime.minY) < 0.5)
    }

    /// VoiceOver hears the count.
    @Test func theLabelSaysTheCount() {
        #expect(laidOutRow(model(unread: 3)).1.contains("3 unread"))
        #expect(!laidOutRow(model(unread: 0)).1.contains("unread"))
    }

    // MARK: - The mark

    /// The mapping: the author pill's.
    @Test func theMarkFollowsTheRelation() {
        #expect(PersonPill.Badge(relation: .notFollowing) == .follow)
        #expect(PersonPill.Badge(relation: .followedBy) == .follow)
        #expect(PersonPill.Badge(relation: .requested) == .pending)
        #expect(PersonPill.Badge(relation: .following) == .following)
        #expect(PersonPill.Badge(relation: .mutual) == .friends)
        #expect(PersonPill.Badge(relation: .viewer) == .none)
        #expect(PersonPill.Badge(relation: .blocked) == .none)
        #expect(PersonPill.Badge(relation: nil) == .loading, "a relation not known yet is the skeleton's badge (#2098)")
    }

    /// NO RING ROUND THE FACE (#2082, the owner 2026-11-03), whatever the
    /// relation: the badge alone, its cutout kept.
    @Test(arguments: [PersonPill.Badge.none, .loading, .follow, .pending, .following, .friends])
    func theFaceWearsNoRing(_ mark: PersonPill.Badge) {
        let face = RelationMarkedAvatarView()
        face.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        face.setMark(mark, animated: false)
        face.layoutIfNeeded()
        #expect(!face.drawsRing, "an edge round the face for \(mark)")
        #expect(face.faceIsCutOut == (mark != .none))
    }

    /// A group keeps its initials, with no mark.
    @Test func aGroupWearsNoMark() {
        let (row, _) = laidOutRow(model(peers: ["a", "b"]), mark: .follow)
        #expect(row.relationMark == .none)
    }

    /// Before its relation is known, a one-to-one row wears the skeleton's
    /// badge, its cutout already out of the face (#2098) — never nothing.
    @Test func theSkeletonsBadgeBeforeTheRelationIsKnown() {
        let relations = InboxRelations(entities: EntityStore(), reader: Graph([:]), writer: Graph([:]))
        #expect(relations.mark(for: Self.peer) == .loading)
        let (row, _) = laidOutRow(model(), mark: relations.mark(for: Self.peer))
        #expect(row.relationMark == .loading)
        #expect(row.debugBadge?.showsBone == true)
        #expect(row.debugFaceIsCutOut)
    }

    /// A reused row starts unknown for its next person (#2098): never the
    /// previous person's mark, never an empty face.
    @Test func aReusedRowStartsWithTheSkeletonsBadge() {
        let (row, _) = laidOutRow(model(), mark: .friends)
        row.prepareForReuse()
        row.layoutIfNeeded()
        #expect(row.relationMark == .loading)
        #expect(row.debugFaceIsCutOut)
    }

    /// ⚠️ THE "+" IS THE BADGE'S ALONE: a touch on it reaches the badge, past
    /// the disc's bounds and the stack round it — never the row's own tap.
    @Test func aTouchOnThePlusIsTheBadges() throws {
        let (row, _) = laidOutRow(model(), mark: .follow)
        let badge = try #require(row.debugBadge)
        let centre = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.midY), to: row)
        #expect(row.hitTest(centre, with: nil) === badge)
        // Its grown touch area, below the disc.
        let below = badge.convert(CGPoint(x: badge.bounds.midX, y: badge.bounds.maxY + 6), to: row)
        #expect(row.hitTest(below, with: nil) === badge)
        // A state mark takes no touch: the row keeps it.
        row.setRelationMark(.following, animated: false)
        #expect(row.hitTest(centre, with: nil) !== badge)
    }

    /// Only the "+" calls the follow.
    @Test func onlyThePlusCallsTheFollow() throws {
        let (row, _) = laidOutRow(model(), mark: .follow)
        var follows = 0
        row.onFollowTapped = { follows += 1 }
        let badge = try #require(row.debugBadge)
        for mark in [PersonPill.Badge.following, .friends, .pending] {
            row.setRelationMark(mark, animated: false)
            badge.sendActions(for: .primaryActionTriggered)
        }
        #expect(follows == 0)
        row.setRelationMark(.follow, animated: false)
        badge.sendActions(for: .primaryActionTriggered)
        #expect(follows == 1)
        #expect(row.followAccessibilityActions?.first?.name == "Follow")
    }

    // MARK: - The relations

    /// The "+": the check at once, then the graph's answer.
    @Test func thePlusFlipsAtOnce() async throws {
        let graph = Graph([Self.peer: .notFollowing])
        let relations = InboxRelations(entities: EntityStore(), reader: graph, writer: graph)
        relations.resolve([Self.peer])
        try #require(await settle { await relations.relation(for: Self.peer) == .notFollowing })
        await graph.set(.following, for: Self.peer)
        var failed = false
        relations.follow(Self.peer) { failed = true }
        #expect(relations.mark(for: Self.peer) == .following, "no optimistic flip")
        try #require(await settle { await graph.follows == [Self.peer] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(relations.mark(for: Self.peer) == .following)
        #expect(!failed)
    }

    /// A private person: the clock.
    @Test func aRequestGivesTheClock() async throws {
        let graph = Graph([Self.peer: .notFollowing], outcome: .requested)
        let relations = InboxRelations(entities: EntityStore(), reader: graph, writer: graph)
        relations.resolve([Self.peer])
        try #require(await settle { await relations.relation(for: Self.peer) == .notFollowing })
        await graph.set(.requested, for: Self.peer)
        relations.follow(Self.peer) {}
        try #require(await settle { await relations.mark(for: Self.peer) == .pending }, "no clock")
    }

    /// A refusal puts the "+" back and is said.
    @Test func aRefusalPutsThePlusBack() async throws {
        let graph = Graph([Self.peer: .notFollowing], outcome: nil)
        let relations = InboxRelations(entities: EntityStore(), reader: graph, writer: graph)
        relations.resolve([Self.peer])
        try #require(await settle { await relations.relation(for: Self.peer) == .notFollowing })
        var failed = false
        relations.follow(Self.peer) { failed = true }
        #expect(relations.mark(for: Self.peer) == .following)
        try #require(await settle { failed }, "the refusal was not said")
        #expect(relations.mark(for: Self.peer) == .follow, "the + did not come back")
    }

    /// A viewer change wipes the store's answers, and the rows are told —
    /// every one.
    @Test func aViewerChangeDropsTheAnswers() async throws {
        let graph = Graph([Self.peer: .following])
        let entities = EntityStore()
        let relations = InboxRelations(entities: entities, reader: graph, writer: graph)
        var toldEveryone = false
        relations.observe(by: graph) { peers in if peers == nil { toldEveryone = true } }
        relations.resolve([Self.peer])
        try #require(await settle { await relations.relation(for: Self.peer) == .following })
        entities.viewerDidChange()
        #expect(relations.relation(for: Self.peer) == nil)
        try #require(await settle { toldEveryone }, "the rows were not told")
    }

    /// ONE STATE PER PERSON (#2049): the answers are the app's `EntityStore`
    /// — what the inbox read, a thread opened from it starts from; a follow
    /// made elsewhere (the follow channel moves the store) reaches the row.
    @Test func theAnswersAreTheAppsOneCopy() async throws {
        let graph = Graph([Self.peer: .notFollowing])
        let entities = EntityStore()
        let relations = InboxRelations(entities: entities, reader: graph, writer: graph)
        var told: Set<ProfileID> = []
        relations.observe(by: graph) { told.formUnion($0 ?? []) }
        relations.resolve([Self.peer])
        try #require(await settle { await entities.relation(to: Self.peer) == .notFollowing }, "not written to the store")
        entities.applyFollowChange(FollowChange(profileID: Self.peer, isFollowing: true))
        try #require(await settle { told.contains(Self.peer) })
        #expect(relations.mark(for: Self.peer) == .following, "a follow made elsewhere did not reach the row")
    }

    /// Back on screen, the inbox asks again: a follow made elsewhere shows.
    @Test func aRefreshAsksAgain() async throws {
        let graph = Graph([Self.peer: .notFollowing])
        let relations = InboxRelations(entities: EntityStore(), reader: graph, writer: graph)
        relations.resolve([Self.peer])
        try #require(await settle { await relations.relation(for: Self.peer) == .notFollowing })
        relations.resolve([Self.peer])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await graph.reads == 1, "a known answer was asked again")
        await graph.set(.following, for: Self.peer)
        relations.resolve([Self.peer], refresh: true)
        try #require(await settle { await relations.relation(for: Self.peer) == .following })
    }
}
