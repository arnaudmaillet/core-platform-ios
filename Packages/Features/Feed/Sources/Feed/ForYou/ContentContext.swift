import Foundation
import PostGrid

/// What the viewer is here for right now — the lens the whole For You surface
/// is read through, above the tabs and above the ordering.
///
/// Named `ContentContext` rather than "profile" on purpose: this app already
/// has profiles, they are people, and a second meaning for the word in the same
/// navigation bar would be a coin toss every time anyone read it.
///
/// ⚠️ **THE FILTER IS A CLIENT-SIDE STAND-IN, and a thin one.** Nothing in the
/// contracts describes what a post is ABOUT — no topic, category, tag or
/// classification field exists on `post.v1`, and `GalleryPost` carries only
/// media, counters, timestamps and a caption. So a context is matched by
/// looking for its words in the caption, which is a keyword search wearing a
/// product's clothes: it will miss a gaming post that never says "game" and
/// will claim a work post that mentions one. It is quarantined here, in one
/// pure file, exactly like `MessageRequestPolicy` — see `dev/BACKEND_GAPS.md`
/// §16 for what the server would need to answer this properly.
///
/// **`.all` is its own case rather than a mood that happens to match
/// everything.** An earlier cut made Entertainment the default AND the
/// unfiltered state, which quietly asserted that "no filter" and "entertainment"
/// are the same thing — so a viewer who wanted films specifically had no way to
/// say so, and the menu had no honest way to show which of the two they were in.
/// Separating them costs one case and makes both answerable: `.all` filters
/// nothing and is where the surface opens; Entertainment is a subject like the
/// other three.
public enum ContentContext: String, Equatable, Sendable, CaseIterable {
    /// Everything, unfiltered. The default, and the only case that is a SCOPE
    /// rather than a subject — which is why it leads the menu.
    case all
    case entertainment
    case work
    case focus
    case gaming

    /// The one case that admits the whole corpus. Everything downstream asks
    /// this rather than comparing against a specific case, so adding another
    /// unfiltered scope later does not mean hunting for `!= .all` comparisons.
    public var isUnfiltered: Bool { self == .all }

    /// What the selector shows and says.
    public var title: String {
        switch self {
        case .all: "All"
        case .entertainment: "Entertainment"
        case .work: "Work"
        case .focus: "Focus"
        case .gaming: "Gaming"
        }
    }

    /// The SF Symbol the navigation bar item wears while this context is
    /// active. Filled variants throughout: the item is showing STATE, not
    /// offering an action, and an outline glyph beside outline actions reads as
    /// another button.
    public var symbol: String {
        switch self {
        case .all: "sparkles"
        case .entertainment: "theatermasks.fill"
        case .work: "briefcase.fill"
        case .focus: "target"
        case .gaming: "gamecontroller.fill"
        }
    }

    /// Words that place a post in this context. Lowercased; matched against a
    /// lowercased caption.
    ///
    /// Empty for `.all`, which is not a keyword set at all — it is the absence
    /// of a filter, and `matches` says so before it ever looks.
    var keywords: [String] {
        switch self {
        case .all: []
        case .entertainment: ["film", "movie", "show", "series", "music", "concert", "gig", "album", "comedy", "watch"]
        case .work: ["work", "office", "meeting", "deadline", "refactor", "ship", "launch", "standup", "review", "build"]
        case .focus: ["focus", "deep work", "study", "reading", "quiet", "notes", "writing", "practice"]
        case .gaming: ["game", "gaming", "play", "stream", "speedrun", "boss", "level", "co-op", "controller"]
        }
    }

    /// Whether a post belongs in this context.
    func matches(_ post: GalleryPost) -> Bool {
        guard !isUnfiltered else { return true }
        let caption = post.caption.lowercased()
        return keywords.contains { caption.contains($0) }
    }

    /// The corpus this context admits.
    ///
    /// Applied ACROSS both tabs, because a context is a statement about the
    /// whole surface rather than about one page of it — switching to Work and
    /// finding Discover filtered but Following not would read as a bug in the
    /// filter rather than as a scope anyone chose.
    public func filtering(_ posts: [GalleryPost]) -> [GalleryPost] {
        guard !isUnfiltered else { return posts }
        return posts.filter { matches($0) }
    }
}

/// The selected context, persisted so the surface opens where the viewer left
/// it.
///
/// Its own store rather than a key on `GalleryPreferences`: that type is the
/// profile gallery's filter pair and is shared with a surface that has no
/// notion of a context at all.
public final class ContentContextStore {
    private let defaults: UserDefaults
    private let key: String

    /// ⚠️ **`.v2` because the vocabulary changed meaning, not just shape.**
    /// Under the previous key, `entertainment` WAS the unfiltered default;
    /// it is now a filtered subject. An install that stored it then would
    /// otherwise wake up quietly filtered, having originally chosen "show me
    /// everything" — the same token, a different promise. Bumping the key
    /// retires every value written under the old meaning in one line, which is
    /// cheaper and more honest than a migration that has to guess which build
    /// wrote what.
    public init(defaults: UserDefaults = .standard, key: String = "foryou.context.v2") {
        self.defaults = defaults
        self.key = key
    }

    /// The stored context, or the default when nothing has been chosen — and
    /// also when something unrecognisable has been: a downgrade that wrote a
    /// context this build has never heard of degrades to All rather than to an
    /// empty screen.
    public var context: ContentContext {
        get { defaults.string(forKey: key).flatMap(ContentContext.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
