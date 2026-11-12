import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// The seeded voice comments (#2309): a few posts whose comments speak, so
/// every surface that draws a comment can be checked on the simulator — two
/// media posts (the band, the danmaku) and a text post (the text page, the
/// lists' tiles), one after the other, early in the timeline and clear of every other seed set (dense, long, reaction-only,
/// empty, and post-0001, which the repository tests pin).
///
/// Each keeps its sparse pair and adds, newest first:
/// - `<post>-voice-1`: a voice with words — the text sits under it;
/// - `<post>-voice-0`: a voice alone, with no body at all;
/// - `<post>-c0-r0`: a voice alone as a REPLY, under the pair's first comment.
///
/// The text post also carries `<post>-future-0`: an attachment of a kind no
/// build reads (`unsupportedAttachmentKind`), with words — the comment must
/// read as its text (the epic's "an unknown kind is ignored safely").
///
/// The voices are the voice messages' and voice posts' bundled takes
/// (`MockVoiceCatalog`), all under a comment's 60 s.
extension MockCommentService {
    /// Media, media, text (`index % 3` = 0, 1, 2), none a repost.
    public static let voiceCommentPostIDs: [String] = ["post-0015", "post-0016", "post-0017"]

    /// The post whose comments carry an attachment of an unknown kind.
    public static let unsupportedAttachmentPostID = "post-0017"

    /// A kind no build will ever read: not `image` or `video`, which #2310
    /// may make real.
    public static let unsupportedAttachmentKind = CommentAttachment.Kind(rawValue: "x-future")

    /// The takes the voice comments speak, in turn: short ones first, a
    /// longer one each round.
    static let commentVoiceIDs = [
        "voice-short", "voice-pair1", "voice-post-hike", "voice-pair2", "voice-post-bakery", "voice-mine",
    ]

    /// The voice of the `turn`th voice comment.
    static func commentVoice(turn: Int) -> PostVoice? {
        MockVoiceCatalog.shared.postVoice(id: commentVoiceIDs[turn % commentVoiceIDs.count])
    }

    /// `postID`'s top-level voice comments, ages relative (the caller makes
    /// them absolute, as for every seed). None for any other post.
    func voiceSeed(for postID: String, authors: [MockSocialDataset.Author]) -> [Comment_V1_CommentView] {
        guard let slot = Self.voiceCommentPostIDs.firstIndex(of: postID), authors.count >= 6 else { return [] }
        var seeds: [Comment_V1_CommentView] = []
        if let voice = Self.commentVoice(turn: slot * 3 + 1) {
            var spoken = makeComment(
                id: "\(postID)-voice-1", postID: postID, author: authors[4].profileID,
                body: "Had to say this one out loud 😂", ageMs: 2 * 60_000
            )
            CommentAttachmentWire.write(.voice(voice), to: &spoken)
            seeds.append(spoken)
        }
        if postID == Self.unsupportedAttachmentPostID {
            var future = makeComment(
                id: "\(postID)-future-0", postID: postID, author: authors[5].profileID,
                body: "Sent from a newer version of the app", ageMs: 8 * 60_000
            )
            CommentAttachmentWire.write(.unsupported(Self.unsupportedAttachmentKind), to: &future)
            seeds.append(future)
        }
        if let voice = Self.commentVoice(turn: slot * 3) {
            var alone = makeComment(
                id: "\(postID)-voice-0", postID: postID, author: authors[3].profileID, body: "", ageMs: 12 * 60_000
            )
            CommentAttachmentWire.write(.voice(voice), to: &alone)
            seeds.append(alone)
        }
        return seeds
    }

    /// `postID`'s voice reply, by parent: a voice alone under the sparse
    /// pair's first comment (`<post>-c0`), ten minutes ago.
    func voiceReplySeed(for postID: String, authors: [MockSocialDataset.Author]) -> [String: [Comment_V1_CommentView]] {
        guard let slot = Self.voiceCommentPostIDs.firstIndex(of: postID), authors.count >= 6,
              let voice = Self.commentVoice(turn: slot * 3 + 2) else { return [:] }
        let parent = "\(postID)-c0"
        var reply = makeComment(
            id: "\(parent)-r0", postID: postID, author: authors[5].profileID, body: "", ageMs: 0
        )
        reply.parentID = parent
        reply.createdAtMs = Int64(Date().timeIntervalSince1970 * 1000) - 10 * 60_000
        CommentAttachmentWire.write(.voice(voice), to: &reply)
        return [parent: [reply]]
    }
}
