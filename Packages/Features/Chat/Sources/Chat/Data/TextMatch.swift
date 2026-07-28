import Foundation

/// The one definition of "does this row match what was typed".
///
/// Case- and diacritic-insensitive **substring**, not prefix: the viewer types
/// the part of a name they remember, which is often the surname, and "sofia"
/// has to find "Sofía Reyes" — which neither an exact nor a prefix match would.
///
/// Shared rather than reimplemented per surface because the inbox's search and
/// the compose picker sit one tap apart. A query that finds someone in one and
/// misses them in the other reads as a broken search, not as two policies.
enum TextMatch {
    /// True when any of `fields` contains `query`. An empty query matches
    /// everything, so the same builder can serve the browsing and the searching
    /// projection without a second code path.
    static func matchesAny(_ fields: [String], query: String) -> Bool {
        let needle = normalize(query)
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return fields.contains { !$0.isEmpty && $0.range(of: needle, options: options) != nil }
    }

    /// Drops a leading "@" from what the viewer typed.
    ///
    /// Handles are stored and rendered BARE everywhere in the app — see
    /// `PersonDisplayModel.handle`, where the sigil is called out as redundant
    /// decoration — but people type it anyway, and the compose picker's own
    /// empty state invites them to ("…by name or @handle"). Without this,
    /// "@sofia" was a substring search for a character that appears in no
    /// field, so it matched nothing and the invitation was a lie.
    ///
    /// Only the first, and only at the front: "@" mid-string is ordinary text
    /// (an email-shaped display name), and stripping it there would make the
    /// query match rows that do not contain what was typed.
    ///
    /// Applied to the QUERY, never to the fields — and shared with
    /// `PeopleDirectoryRepository`, so the locally matched rows and the
    /// directory hits answer the same string. Normalising only one of them
    /// would list a correspondent under Messages and then omit that same
    /// person from People.
    ///
    /// Trimming happens HERE rather than in the callers, and before the sigil
    /// is looked for: the two steps compose in one order only, and " @sofia"
    /// (which is what a keyboard's smart-space or a paste produces) silently
    /// keeps its "@" if they run the other way round.
    static func normalize(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }
}
