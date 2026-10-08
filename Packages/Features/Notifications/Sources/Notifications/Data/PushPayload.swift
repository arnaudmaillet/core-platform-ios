import CoreModels
import Foundation

/// What a push from the notification service carries beside its alert (#651):
///
///     { "aps": { "alert": { "loc-key": "NTF_PUSH_REACTION", "loc-args": ["Alice"] }, … },
///       "notification_id": "<uuid>", "kind": "reaction",
///       "subject_kind": "post", "subject_id": "<uuid>" }
///
/// The alert is iOS's to show, from `Localizable.strings`; this is the half
/// the app reads when the viewer taps it.
public struct PushPayload: Sendable, Equatable {
    /// Where a tap takes the viewer: the subject the notification is about.
    public enum Destination: Sendable, Equatable {
        case post(PostID)
        /// A comment's id only: its post is looked up before opening it.
        case comment(String)
        case profile(ProfileID)
    }

    public let notificationID: String?
    /// `reaction`, `comment`, `reply`, `mention`, `follow`, `follow_request`,
    /// `follow_accepted` — informative; the subject decides where a tap goes.
    public let kind: String?
    public let destination: Destination

    /// Nil for anything that is not one of this service's pushes, or that
    /// names no subject the app can open.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let subjectKind = userInfo["subject_kind"] as? String,
              let subjectID = userInfo["subject_id"] as? String, !subjectID.isEmpty
        else { return nil }
        switch subjectKind {
        case "post": destination = .post(PostID(subjectID))
        case "comment": destination = .comment(subjectID)
        case "profile": destination = .profile(ProfileID(subjectID))
        default: return nil
        }
        notificationID = userInfo["notification_id"] as? String
        kind = userInfo["kind"] as? String
    }
}
