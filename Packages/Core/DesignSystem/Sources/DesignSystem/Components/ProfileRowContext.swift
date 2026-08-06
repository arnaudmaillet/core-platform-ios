import Foundation

/// The one line of social context a person row carries beside their name.
///
/// **One enum rather than a formatted string on the content model**, so the
/// decision "what do we say about this person" stays with the feature that
/// knows, and the wording, the abbreviation and the typography stay here. A
/// caller that hands over `.followerCount(1_240)` cannot accidentally ship
/// "1240 followers" on one screen and "1.2K" on another.
///
/// ⚠️ **Only say what can be backed.** Every case here has to come from
/// somewhere real: `.following` and `.followerCount` both come out of one
/// `social_graph.v1.GetRelationStatus` (its view carries the status *and*
/// `target_followers_count`). `.newPostsCount` has no source yet — nothing in
/// the contracts says what is new to a given viewer — and is here because the
/// shape of the row should not have to change when one arrives. It is
/// unpopulated on purpose, not by oversight.
public enum ProfileRowContext: Equatable, Sendable {
    /// Nothing worth saying, or nothing known yet. Renders no label at all
    /// rather than an empty one, so the row is exactly as tall as a row with
    /// no context ever was.
    case none
    /// The viewer already follows this person.
    case following
    case followerCount(Int)
    /// Reserved — see the type's note.
    case newPostsCount(Int)

    /// What the row shows, or nil for no label.
    public var label: String? {
        switch self {
        case .none: nil
        case .following: "Following"
        case .followerCount(let count): "\(Self.abbreviate(count)) followers"
        case .newPostsCount(let count): "\(count) new"
        }
    }

    /// Compact counts, because this label sits at the end of a row whose text
    /// is already competing for the width: "1.2K" costs four characters where
    /// "1,240" costs five and reads no better at a glance.
    ///
    /// Truncating rather than rounding — 1,999 is "1.9K", not "2K" — so the
    /// number never claims more than the count it came from.
    static func abbreviate(_ count: Int) -> String {
        switch count {
        case ..<1_000:
            "\(count)"
        case ..<1_000_000:
            "\(trimmed(Double(count) / 1_000))K"
        default:
            "\(trimmed(Double(count) / 1_000_000))M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let floored = (value * 10).rounded(.down) / 10
        return floored == floored.rounded()
            ? String(Int(floored))
            : String(format: "%.1f", floored)
    }
}
