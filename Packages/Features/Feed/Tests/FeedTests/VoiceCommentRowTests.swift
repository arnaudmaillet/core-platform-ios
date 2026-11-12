import CoreModels
import MediaCore
import Testing
import UIKit
import VoiceKitUI
@testable import Feed

private final class NoVoicePostFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

/// Every comment in one page, whatever the order.
private struct FixedComments: CommentsProviding {
    let all: [CommentEntry]
    func loadComments(for postID: PostID) async throws -> [CommentEntry] { all }
    func addComment(_ body: String, to postID: PostID, parentID: String?, commentID: String) async throws -> CommentEntry {
        CommentEntry(id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me", body: body, createdAt: Date())
    }
}

/// **Voice comments in the rows (#2309, piece 2).** A comment's attachment is
/// drawn by kind in the row's slot — a voice as the shared voice view with
/// the seconds timer, its words under it; a kind this build doesn't know as
/// its words or a neutral line — and its words in one line wherever a
/// comment shows as a line. The row's height counts the voice, Copy needs
/// words, and one voice plays at a time.
@MainActor
@Suite(.serialized)
struct VoiceCommentRowTests {
    private static let voice = PostVoice(
        assetID: "voice-short", url: URL(fileURLWithPath: "/tmp/voice-short.m4a"), duration: 12.6,
        waveform: (0..<100).map { UInt8($0 % 32) }
    )
    private static let future = CommentAttachment.unsupported(CommentAttachment.Kind(rawValue: "x-future"))

    private static func entry(
        _ id: String, body: String, attachment: CommentAttachment?, isHeld: Bool = false, ageMinutes: Double = 1
    ) -> CommentEntry {
        CommentEntry(
            id: id, authorID: ProfileID("prof-\(id)"), authorName: "Ava Moreau", authorHandle: "ava", body: body,
            attachment: attachment, createdAt: Date(timeIntervalSinceNow: -ageMinutes * 60), isHeld: isHeld
        )
    }

    private static func model(
        _ id: String = "c1", body: String, attachment: CommentAttachment?, isHeld: Bool = false, canReview: Bool = false
    ) -> CommentDisplayModel {
        CommentDisplayModel(entry: entry(id, body: body, attachment: attachment, isHeld: isHeld), canReview: canReview)
    }

    /// Runs `body` with the rows' voice hub on a silent player.
    private static func withSilentHub<T>(_ body: (VoicePlaybackHub) throws -> T) rethrows -> T {
        let previous = CommentRowView.voiceHub
        let hub = VoicePlaybackHub.silentForTests()
        CommentRowView.voiceHub = hub
        defer { CommentRowView.voiceHub = previous }
        return try body(hub)
    }

    private static func laidOut(_ row: CommentRowView, width: CGFloat = 390) -> CommentRowView {
        let size = row.systemLayoutSizeFitting(
            CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        row.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
        row.layoutIfNeeded()
        return row
    }

    // MARK: - The slot, by kind

    /// A voice with words: the shared voice view, full size, at the text
    /// column's width, with a voice post's seconds ("12″"); the words under it.
    @Test func aVoiceCommentDrawsTheVoiceWithItsSecondsAndTheWordsUnderIt() throws {
        try Self.withSilentHub { _ in
            let row = CommentRowView()
            row.configure(with: Self.model(body: "Had to say this one out loud 😂", attachment: .voice(Self.voice)))
            let voice = try #require(row.debugAttachmentVoiceView, "no voice drawn")
            #expect(voice.size == .full)
            #expect(voice.role == .comment(author: "Ava Moreau"))
            #expect(voice.timerStyle == .seconds)
            #expect(voice.accessibilityLabel == "Voice comment by Ava Moreau, 13 seconds")
            #expect(voice.debugTimerText == "12\u{2033}", "a comment's voice in seconds (#2294)")
            #expect(row.debugShowsBody, "the words went")
            #expect(row.debugUnsupportedAttachmentLine == nil)
            #expect(row.attachmentVoiceID == CommentRowView.voicePlaybackID(commentID: "c1"))

            _ = Self.laidOut(row)
            let voiceFrame = voice.convert(voice.bounds, to: row)
            let bodyFrame = row.bodyTextLabel.convert(row.bodyTextLabel.bounds, to: row)
            #expect(voiceFrame.height >= VoiceView.panelHeight(for: .full) - 0.5, "the voice took no room: \(voiceFrame)")
            #expect(voiceFrame.maxY <= bodyFrame.minY + 0.5, "the words are not under the voice: \(voiceFrame) / \(bodyFrame)")
            #expect(abs(voiceFrame.minX - bodyFrame.minX) < 0.5, "the voice is not on the text column")
            #expect(abs(voiceFrame.width - bodyFrame.width) < 1, "the voice's room is not the text column")
            // Its panel says its length (#2329): leading-aligned, narrower
            // than the column at 12 s, as a voice post's caption.
            #expect(voice.widthFollowsLength)
            let panel = voice.debugPanelFrame
            let expected = VoiceView.panelWidth(forLength: Self.voice.duration, available: voiceFrame.width)
            #expect(abs(panel.width - expected) < 1, "panel \(panel.width), by length \(expected)")
            #expect(panel.width < voiceFrame.width - 1, "a 12 s voice took the whole column")
            #expect(abs(panel.minX) < 0.5, "the panel is not leading-aligned")
        }
    }

    /// A voice alone: the voice, and no empty line under it.
    @Test func aVoiceAloneHasNoBodyLabel() {
        Self.withSilentHub { _ in
            let row = CommentRowView()
            row.configure(with: Self.model(body: "", attachment: .voice(Self.voice)))
            #expect(row.debugAttachmentVoiceView != nil)
            #expect(!row.debugShowsBody, "an empty line under a voice alone")
        }
    }

    /// ⚠️ AN UNKNOWN KIND IS IGNORED SAFELY (the epic's criterion): with words,
    /// the words alone; without, the neutral line — never a crash, never an
    /// empty row. A plain comment after it is today's row.
    @Test func anUnsupportedKindShowsItsWordsOrTheNeutralLine() {
        Self.withSilentHub { _ in
            let row = CommentRowView()
            row.configure(with: Self.model(body: "Sent from a newer version of the app", attachment: Self.future))
            #expect(row.debugAttachmentVoiceView == nil)
            #expect(row.debugUnsupportedAttachmentLine == nil, "words speak for it")
            #expect(row.debugShowsBody)

            row.configure(with: Self.model(body: "", attachment: Self.future))
            #expect(row.debugUnsupportedAttachmentLine == CommentRowView.unsupportedAttachmentText)
            #expect(!row.debugShowsBody)
            #expect(Self.laidOut(row).bounds.height > 0)

            // A voice, then an unknown kind, then words alone: nothing of the
            // last one stays.
            row.configure(with: Self.model(body: "", attachment: .voice(Self.voice)))
            row.configure(with: Self.model(body: "", attachment: Self.future))
            #expect(row.debugAttachmentVoiceView == nil && row.attachmentVoiceID == nil)
            row.configure(with: Self.model(body: "Just words", attachment: nil))
            #expect(row.debugAttachmentVoiceView == nil && row.debugUnsupportedAttachmentLine == nil)
            #expect(row.debugShowsBody)
        }
    }

    /// A recycled row lets its voice go: no binding left in the hub.
    @Test func aRecycledRowLetsItsVoiceGo() {
        Self.withSilentHub { hub in
            let cell = CommentCell()
            cell.row.configure(with: Self.model(body: "", attachment: .voice(Self.voice)))
            #expect(hub.debugBoundCount == 1)
            cell.prepareForReuse()
            #expect(cell.row.debugAttachmentVoiceView == nil)
            #expect(hub.debugBoundCount == 0)
        }
    }

    // MARK: - One line of words

    /// The band, the danmaku and the subtitle zone: a voice's words when it
    /// has some, "🎙 12″" otherwise; an unknown kind's words, or "Attachment".
    @Test func aCommentInOneLineIsItsWordsOrItsVoice() {
        #expect(Self.entry("a", body: "", attachment: .voice(Self.voice)).oneLineText == "🎙 12\u{2033}")
        #expect(Self.entry("b", body: " Out loud ", attachment: .voice(Self.voice)).oneLineText == "Out loud")
        #expect(Self.entry("c", body: "", attachment: Self.future).oneLineText == "Attachment")
        #expect(Self.entry("d", body: "Newer app", attachment: Self.future).oneLineText == "Newer app")
        #expect(Self.model(body: "", attachment: .voice(Self.voice)).oneLineText == "🎙 12\u{2033}")
    }

    /// Voices alone ride the band as "🎙 12″" — each its own comment, even
    /// two of one length.
    @Test func voicesAloneRideTheBand() {
        let entries = (0..<6).map { Self.entry("v\($0)", body: "", attachment: .voice(Self.voice)) }
        let band = CommentTickerBuilder().build(entries, postID: PostID("p"))
        #expect(band.count == 6, "\(band.map(\.text))")
        #expect(band.allSatisfy { $0.text == "🎙 12\u{2033}" })
        // Words dedupe as before.
        let words = (0..<6).map { Self.entry("w\($0)", body: "GG", attachment: .voice(Self.voice)) }
        #expect(CommentTickerBuilder().build(words, postID: PostID("p")).isEmpty, "six GGs are one reaction")
    }

    /// The subtitle zone, with no band on screen: every comment in one line,
    /// never a blank cue.
    @Test func theSubtitleZoneSpeaksForVoicesAndUnknownKinds() {
        let entries = [
            Self.entry("v", body: "", attachment: .voice(Self.voice)),
            Self.entry("w", body: "Had to say this one out loud, really", attachment: .voice(Self.voice)),
            Self.entry("f", body: "", attachment: Self.future),
        ]
        let cues = SubtitleCommentBuilder().build(entries, postID: PostID("p"), tickerIsRendering: false)
        let texts = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0.text) })
        #expect(texts["w"] == "Had to say this one out loud, really")
        #expect(cues.allSatisfy { !$0.text.isEmpty })
        // The semantic pass found a thought; the shape-blind floor, alone.
        let alone = SubtitleCommentBuilder().build(Array(entries[0...0]) + [entries[2]], postID: PostID("p"),
                                                   tickerIsRendering: false)
        #expect(alone.map(\.text) == ["🎙 12\u{2033}", "Attachment"])
    }

    // MARK: - The menu (#2309, D)

    private static func titles(_ elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let menu = element as? UIMenu { return titles(menu.children) }
            return [element.title]
        }
    }

    private static func menuTitles(_ model: CommentDisplayModel) -> [String] {
        titles(CommentStream.commentMenu(for: model, copy: { _ in }, selectText: {}, share: {}, review: { _ in }).children)
    }

    /// Copy and Select Text need words: a voice alone has neither; a voice
    /// with words copies its words. Review and Share stand whatever the kind.
    @Test func copyIsOnlyForAVoiceCommentWithWords() {
        let alone = Self.model(body: "", attachment: .voice(Self.voice))
        #expect(alone.copyableText == nil)
        #expect(!Self.menuTitles(alone).contains("Copy"))
        #expect(!Self.menuTitles(alone).contains("Select Text"))
        #expect(Self.menuTitles(alone).contains("Share Comment"))

        let spoken = Self.model(body: "Had to say this one out loud 😂", attachment: .voice(Self.voice))
        #expect(spoken.copyableText == "Had to say this one out loud 😂")
        #expect(Self.menuTitles(spoken) == ["Copy", "Select Text", "Share Comment"])

        let unknown = Self.model(body: "", attachment: Self.future)
        #expect(!Self.menuTitles(unknown).contains("Copy"))

        // The post's owner reviews a held voice comment as any other.
        let held = Self.model(body: "", attachment: .voice(Self.voice), isHeld: true, canReview: true)
        #expect(Self.menuTitles(held) == ["Approve Comment", "Decline Comment", "Share Comment"])
    }

    // MARK: - Height

    private static func cellHeight(_ model: CommentDisplayModel, width: CGFloat = 402) -> CGFloat {
        let cell = CommentCell()
        cell.row.bindsVoicePlayback = false
        cell.row.configure(with: model)
        cell.bounds.size.width = width
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        return ceil(cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    /// The row is measured with its voice, so the cut counts it: in one room,
    /// fewer voice rows fit than text rows.
    @Test func theRowsHeightCountsTheVoice() {
        let voiceRow = Self.cellHeight(Self.model(body: "", attachment: .voice(Self.voice)))
        let textRow = Self.cellHeight(Self.model(body: "Nice one", attachment: nil))
        #expect(voiceRow > textRow + 10, "voice \(voiceRow), text \(textRow)")
        func shown(_ height: CGFloat) -> Int {
            PopularCommentsCut(
                threadHeights: Array(repeating: height, count: 30), room: 700, lead: 80, seeAllHeight: 40,
                sourceHasMore: false
            ).shownThreads
        }
        #expect(shown(voiceRow) < shown(textRow))
    }

    private static let looks = 3_000

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<Self.looks where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Popular's cut on a real panel: the same room holds fewer voice
    /// comments than short text comments.
    @Test func popularsCutFitsFewerVoiceRowsThanTextRows() async {
        let previous = CommentRowView.voiceHub
        CommentRowView.voiceHub = VoicePlaybackHub.silentForTests()
        defer { CommentRowView.voiceHub = previous }

        func shown(_ entries: [CommentEntry]) async -> Int {
            let controller = PostDetailViewController(
                viewModel: PostDetailViewModel(
                    postID: PostID("p"), repository: NoVoicePostFeed(), commentsProvider: FixedComments(all: entries)
                ),
                imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = controller
            window.isHidden = false
            defer { window.isHidden = true }
            controller.setEngagedInsets(top: 100, bottomInset: 34)
            controller.setEngagedPageSwipeHandler({ _, _, _ in }, pagesBack: { false })
            controller.seedCaption("A text post", timestamp: "2h", authorName: "Ava Moreau")
            let stream = controller.popular
            _ = await settle {
                stream.collectionView.layoutIfNeeded()
                return stream.commentsLoaded && stream.debugItems.last == .seeAll
            }
            return stream.debugItems.filter { if case .comment = $0 { true } else { false } }.count
        }
        let voices = await shown((0..<30).map {
            Self.entry("v\($0)", body: "", attachment: .voice(Self.voice), ageMinutes: Double($0 + 1))
        })
        let words = await shown((0..<30).map {
            Self.entry("t\($0)", body: "Nice one", attachment: nil, ageMinutes: Double($0 + 1))
        })
        #expect(voices > 0 && voices < words, "voices \(voices), words \(words)")
    }

    // MARK: - Playback

    /// One voice at a time, through the app's one hub: playing a second
    /// voice comment stops the first; a row leaving the screen stops its own.
    @Test func playingOneVoiceCommentStopsAnother() throws {
        try Self.withSilentHub { hub in
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.isHidden = false
            defer { window.isHidden = true }
            let first = CommentRowView(), second = CommentRowView()
            for (index, row) in [first, second].enumerated() {
                row.frame = CGRect(x: 0, y: CGFloat(index) * 120, width: 402, height: 110)
                window.addSubview(row)
            }
            first.configure(with: Self.model("a", body: "", attachment: .voice(Self.voice)))
            second.configure(with: Self.model("b", body: "Second", attachment: .voice(Self.voice)))
            let a = CommentRowView.voicePlaybackID(commentID: "a")
            let b = CommentRowView.voicePlaybackID(commentID: "b")

            try #require(first.debugAttachmentVoiceView).debugTapPlay()
            #expect(hub.isPlaying(a))
            try #require(second.debugAttachmentVoiceView).debugTapPlay()
            #expect(hub.isPlaying(b))
            #expect(!hub.isPlaying(a), "two voice comments played at once")

            second.removeFromSuperview()
            #expect(!hub.isPlaying(b), "the voice went on after its row left")
        }
    }
}
