import CoreModels
import CoreNavigation
import DesignSystem
import ThreadKit
import UIKit

/// What the comments' voice asks of its panel (#2523): the composer, the
/// post, the voice its field records, the armed reply and the threads a
/// reply expands.
///
/// A view controller: the member gate, the hint's toast and the
/// microphone alert are presented from it, and the recorder is attached
/// to its view.
@MainActor
protocol PostDetailVoiceCommentsHost: UIViewController {
    var composeBar: CommentsInputBar { get }
    var viewModel: PostDetailViewModel { get }
    var commentsVoice: ComposerConfiguration.Voice { get }
    var replyTarget: (parentID: String, name: String)? { get }
    var expandedReplyParents: Set<String> { get set }
    func clearReplyState()
}

/// Voice comments (#2309), out of `PostDetailViewController` (#2523): the
/// recorder on the comments' field, the reply a take answers, the send
/// and retry behind the member gate, and the microphone's Settings offer.
@MainActor
final class PostDetailVoiceComments {
    private unowned let host: any PostDetailVoiceCommentsHost

    init(host: any PostDetailVoiceCommentsHost) {
        self.host = host
    }

    /// Hold the empty field to record a voice comment (#2309) — the
    /// conversation's mic, lock, pause, listen back and send (#2102), with a
    /// comment's minute. A tap still types.
    private(set) var voiceComposer: VoiceComposer?
    /// The reply the take was started under: a reply's keyboard can go
    /// while it records (`onIdleDismiss` clears the target), and the take
    /// still answers the comment it was held for.
    private var voiceReplyTarget: (parentID: String, name: String)?

    func installCommentVoice() {
        // A draft's voice is its host's (`configureDraft`).
        guard !host.viewModel.isDraft else { return }
        host.composeBar.configuration.voice = host.commentsVoice
        guard host.commentsVoice.records, voiceComposer == nil, let postID = host.viewModel.postID else { return }
        let composer = VoiceComposer(for: .comment, draftKey: "comment-voice-\(postID.rawValue)")
        composer.onSend = { [weak self] take in
            self?.sendVoiceComment(CommentVoiceTake(fileURL: take.fileURL, duration: take.duration, waveform: take.waveform))
        }
        composer.onHint = { [weak self] hint in
            guard let self else { return }
            Feedback.info(hint, symbol: "mic", from: host)
        }
        // Once refused, a hold offers Settings, the conversation's (#2102).
        composer.offersMicrophoneSettings(from: host, message: "Allow microphone access to record voice comments.")
        composer.onPhaseChange = { [weak self] phase in self?.voicePhaseChanged(phase) }
        composer.attach(to: host.composeBar, host: host.view)
        voiceComposer = composer
    }

    private func voicePhaseChanged(_ phase: VoiceComposer.Phase) {
        if phase == .idle {
            voiceReplyTarget = nil
        } else if voiceReplyTarget == nil {
            voiceReplyTarget = host.replyTarget
        }
    }

    /// A take from the comments' field, sent as a voice comment: behind the
    /// member gate, as a typed comment is; under the reply it was held for;
    /// with the words typed so far, if any, as its body.
    func sendVoiceComment(_ take: CommentVoiceTake) {
        let target = voiceReplyTarget ?? host.replyTarget
        MemberGates.perform(.comment, from: host) { [weak self] in
            guard let self else { return }
            // A reply must be visible where it lands, as a typed one's.
            if let target { host.expandedReplyParents.insert(target.parentID) }
            let text = host.composeBar.draftText
            host.viewModel.submitVoiceComment(take, text: text, parentID: target?.parentID)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.composeBar.draftText = "" }
            host.clearReplyState()
        }
    }

    /// A voice comment that didn't go, sent again from its row's tap.
    func retryVoiceComment(_ commentID: String) {
        MemberGates.perform(.comment, from: host) { [weak self] in
            self?.host.viewModel.retryVoiceComment(commentID)
        }
    }
}

extension PostDetailViewController: PostDetailVoiceCommentsHost {}
