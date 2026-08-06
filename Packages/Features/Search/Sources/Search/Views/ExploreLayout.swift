import CoreModels
import UIKit

/// The Search screen's sections, and the order they appear in.
///
/// One enum for all three phases rather than one per phase: they share a
/// collection view and a data source, so a phase change is a snapshot diff —
/// the recent rows animate out and the results animate in — rather than a view
/// swap. Only one phase's sections are ever present at a time.
enum SearchSection: Hashable {
    /// The resting screen's history.
    case recent
    /// People worth looking at, on the resting screen.
    case suggestions
    /// The history plus live completions, while the viewer is typing.
    ///
    /// Named for what its rows ARE rather than for the RPC behind half of
    /// them: `search.v1.Suggest` supplies the remote half, but calling this
    /// "suggestions" would collide with the section above, which is people and
    /// is what the viewer sees that word attached to on screen.
    case completions
    /// A submitted search's answer.
    case results

    /// The header this section wears, if any.
    ///
    /// Completions and results are deliberately unlabelled. A header names a
    /// run of content when there is more than one kind on screen; both of
    /// those are the only thing on screen, and a title over them would be
    /// naming the obvious.
    ///
    /// ⚠️ **"Suggestions" is the product's word, not the data's.** The corpus
    /// behind that section is the viewer's FOLLOWING timeline, so everyone in
    /// it is already followed — see `ExploreRanking.creators`. It was titled
    /// "Creators" for exactly that reason; Arnaud set it to "Suggestions" for
    /// the MVP (2026-08-06), which is a naming call, not a claim the ranking
    /// can back. Nothing downstream should start treating these as people the
    /// viewer does NOT follow.
    var title: String? {
        switch self {
        case .recent: "Recent"
        case .suggestions: "Suggestions"
        case .completions, .results: nil
        }
    }

    /// The trailing action in the header, if any.
    var actionTitle: String? {
        switch self {
        case .recent: "Clear all"
        case .suggestions, .completions, .results: nil
        }
    }
}

/// One row. Every row on this screen is a row — there are no tiles.
enum SearchItem: Hashable {
    /// A text row — a remembered search or a live completion — in either the
    /// Recent or the Completions section.
    case row(String)
    /// The "See more" row that ends a truncated Recent section. Carries the
    /// hidden count so a change in it re-renders the row — an item that
    /// hashed the same while its label changed would keep the old number.
    case seeMoreRecents(Int)
    case result(ProfileID)
    /// A person in the Suggestions section.
    case suggested(ProfileID)
    /// A shimmering placeholder while the corpus is in flight.
    case suggestedSkeleton(Int)
}

/// The compositional layout the Search screen is laid out by.
///
/// **One list configuration for the whole screen.** Every section is a plain
/// list of full-width rows — text rows, person rows, a "See more" row — so the
/// layout has exactly one shape to build and the only thing that varies is
/// whether a section is titled.
///
/// It had a sideways-scrolling card rail and a two-column media grid, and both
/// were removed (2026-08-06): three layouts on one screen made a search
/// surface read as a magazine, and the rail in particular put the one section
/// the viewer could not scan vertically in the middle of two they could.
enum ExploreLayout {
    /// `hasHeader` is asked PER SECTION and at layout time, because which
    /// sections are on screen depends on which phase is showing.
    ///
    /// `@MainActor` on the whole function, not just on the closure: the
    /// section provider both calls a main-actor closure and hands the layout
    /// environment to `NSCollectionLayoutSection.list`, and that environment
    /// is not `Sendable` — built anywhere else, the two together read to the
    /// compiler as the environment escaping onto the main actor.
    @MainActor
    static func make(
        hasHeader: @escaping @MainActor (Int) -> Bool
    ) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.headerMode = hasHeader(index) ? .supplementary : .none
            // Only the FIRST section loses its top padding. That padding is
            // what separates a header from the rows above it; at the top of
            // the list there is nothing above to separate from, and the gap
            // just pushes the content down under the navigation bar.
            if index == 0 { configuration.headerTopPadding = 0 }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }
}
