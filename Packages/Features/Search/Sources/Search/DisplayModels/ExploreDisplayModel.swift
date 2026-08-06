import CoreModels
import CoreStorage
import DesignSystem
import Foundation

/// One text row on the search screen, pre-formatted so the cell does no logic.
///
/// The same shape serves both lists it appears in — the resting history and
/// the typeahead — because they *are* the same row: a glyph, a line of text,
/// and something that happens when you tap it. Only the glyph and whether it
/// can be forgotten differ, and both are fields rather than a second type.
public struct SearchRowDisplayModel: Equatable, Sendable, Identifiable {
    /// Where the row came from, which is what decides whether it is the
    /// viewer's to delete.
    public enum Source: Equatable, Sendable {
        /// The device's own history.
        case history
        /// A live completion from `search.v1.Suggest`. Not the viewer's to
        /// forget — it is not remembered in the first place, and a ✕ on it
        /// would promise something that does not happen.
        ///
        /// Named `completion`, not `suggestion`: "Suggestions" is the header
        /// over the PEOPLE list on the resting screen, and one word for two
        /// things on the same screen is a coin toss every time anyone reads it.
        case completion
    }

    public let id: String
    /// The query, or the person's name.
    public let text: String
    /// The second line — a profile's handle. Queries have none.
    public let subtitle: String?
    /// What the leading disc shows — and the single place the avatar-or-icon
    /// question is answered.
    ///
    /// ⚠️ **Derived from the row's ACTION, not set beside it.** A row that
    /// opens a profile shows that person's face; a row that runs a search
    /// shows a glyph. Those were once two independent fields and they drifted:
    /// the same person rendered as a 48pt avatar in Suggestions and a 22pt
    /// `person` glyph in Recent, because one surface set the symbol and the
    /// other set the disc. One question, asked once, in `init`.
    public let subject: PersonRowContent.Subject
    /// The person's picture, when one is known.
    ///
    /// `var` because it is filled in from two directions: what was persisted
    /// with the row, and what `ProfileAvatarProviding` resolves afterwards.
    /// Nil is not "no avatar" — it is "none known yet", and the disc falls
    /// back to initials until one arrives.
    public var avatarURL: URL?
    /// Social context, filled in by `ProfileMetadataProviding`. Never
    /// persisted — see `RecentSearchStore`.
    public var context: ProfileRowContext = .none
    /// One or two letters behind the picture.
    public let monogram: String
    public let source: Source
    /// What tapping the row does.
    ///
    /// Carried on the model rather than decided at the tap site, because the
    /// answer depends on where the row came from and only the row knows: a
    /// remembered query runs a search, a remembered person opens their
    /// profile, and a completion does one or the other depending on what
    /// `search.v1` said it was a completion OF.
    public let action: Action

    /// The two things a text row can be.
    public enum Action: Equatable, Sendable {
        /// Run this row's `text` as a search.
        case search
        /// Open a person, in one tap.
        ///
        /// ⚠️ **Not "search for their name".** That was the old behaviour and
        /// it cost a tap and a wrong screen: tapping a person ran a query,
        /// landed on a results list, and left the viewer to tap the same
        /// person again. `displayName` is nil when the row genuinely does not
        /// know one — a completion carries a handle and an id and nothing
        /// else — so the routing site can tell "no name" from "name that
        /// happens to equal the handle" and not fake a chrome stub.
        case openProfile(id: ProfileID, handle: String, displayName: String?, avatarURL: URL?)
    }

    public var isRemovable: Bool { source == .history }
    /// Spoken by VoiceOver for the row's delete button, so it says which entry
    /// it removes rather than "Remove, button" repeated down the list.
    public var deleteAccessibilityLabel: String { "Remove \(text) from recent searches" }

    public init(entry: RecentSearch) {
        id = entry.id
        text = entry.text
        subtitle = entry.subtitle
        source = .history
        // A `.profile` entry that somehow lost its id is still a legible row —
        // it just falls back to searching its own text rather than trapping,
        // and reads as a query, which is exactly what it can still do.
        if entry.kind == .profile, let profileID = entry.profileID, !profileID.isEmpty {
            let stored = entry.avatarURL.flatMap(URL.init(string:))
            // The action carries the picture too, so re-tapping a remembered
            // person re-records them with everything already known about them
            // rather than overwriting it with less.
            action = .openProfile(
                id: ProfileID(profileID), handle: entry.subtitle ?? "",
                displayName: entry.text, avatarURL: stored
            )
            subject = .person
            avatarURL = stored
            monogram = Self.monogram(for: entry.text)
        } else {
            action = .search
            subject = .symbol("clock")
            avatarURL = nil
            monogram = ""
        }
    }

    public init(suggestion: SearchSuggestion) {
        // Keyed on the text, like a history entry, so the two lists can be
        // concatenated and de-duplicated against each other by identity alone.
        id = suggestion.text.lowercased()
        text = suggestion.text
        subtitle = nil
        source = .completion
        // Only a PROFILE completion carrying an id can be opened. A hashtag
        // completion has no id by contract, and a profile one without an id
        // identifies nobody — both stay searches, and both read as searches.
        if suggestion.kind == .profile, !suggestion.id.isEmpty {
            // The completion text IS the handle: that is what the index
            // stores and what `Suggest` answers with. No display name exists
            // to pass along, and inventing one from the handle would put the
            // wrong name in the profile's chrome for a beat.
            action = .openProfile(
                id: ProfileID(suggestion.id), handle: suggestion.text,
                displayName: nil, avatarURL: nil
            )
            subject = .person
            // `Suggest` answers with text and an id and no picture, so this
            // starts empty and is filled in by `ProfileAvatarProviding`.
            avatarURL = nil
            monogram = Self.monogram(for: suggestion.text)
        } else {
            action = .search
            subject = .symbol(suggestion.kind == .hashtag ? "number" : "magnifyingglass")
            avatarURL = nil
            monogram = ""
        }
    }

    /// The same initials rule the rest of the app uses, so one person's disc
    /// reads the same in Recent as in Suggestions.
    private static func monogram(for name: String) -> String {
        SearchResultDisplayModel.monogram(displayName: name, handle: name)
    }

    /// This row as the shared person cell renders it.
    public var rowContent: PersonRowContent {
        PersonRowContent(
            displayName: text,
            handle: subtitle ?? "",
            monogram: monogram,
            subject: subject,
            context: context
        )
    }
}

/// Where the trending section is up to.
///
/// A state rather than an optional array, because "not fetched yet", "nothing
/// came back" and "the fetch failed" are three different things and the screen
/// says something different for each. An `[GalleryPost]?` would collapse them
/// into one shrug.
public enum TrendingState: Equatable, Sendable {
    /// No provider is wired — the section does not exist on this build.
    case unavailable
    case loading
    case loaded(creators: [ExploreCreator])
    /// The corpus could not be read. The history still renders; the section
    /// just does not appear, because a failed trending rail is not worth an
    /// error message on a screen whose main job still works.
    case failed

    var isLoading: Bool { self == .loading }

    var creators: [ExploreCreator] {
        if case .loaded(let creators) = self { return creators }
        return []
    }
}

/// What the resting Search screen shows: the history, and what is trending.
public struct ExploreDisplayModel: Equatable, Sendable {
    public let recents: [SearchRowDisplayModel]
    /// How many entries the collapsed window is hiding. Zero when the whole
    /// history is on screen.
    public let hiddenRecentCount: Int
    public let trending: TrendingState

    /// Whether the section ends in a "See more" row.
    public var showsMoreRecentsRow: Bool { hiddenRecentCount > 0 }
    /// Whether the screen has nothing to show at all — no history AND no
    /// trending, which is the only case that earns the full-screen empty
    /// state. A viewer with no history but a live trending grid is looking at
    /// a working screen.
    public var isEmpty: Bool {
        recents.isEmpty && trending.creators.isEmpty && !trending.isLoading
    }

    public init(
        recents: [SearchRowDisplayModel],
        hiddenRecentCount: Int,
        trending: TrendingState = .unavailable
    ) {
        self.recents = recents
        self.hiddenRecentCount = hiddenRecentCount
        self.trending = trending
    }

    /// Projects a store window onto the display model.
    public init(window: RecentSearchStore.Window, trending: TrendingState = .unavailable) {
        self.init(
            recents: window.rows.map(SearchRowDisplayModel.init),
            hiddenRecentCount: window.hiddenCount,
            trending: trending
        )
    }
}
