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
/// **`.entertainment` matches everything**, which is what keeps the default
/// experience honest: a viewer who never opens the menu sees the unfiltered
/// corpus rather than a keyword-shaped slice of it.
public enum ContentContext: String, Equatable, Sendable, CaseIterable {
    /// Everything, unfiltered. The default.
    case entertainment
    case work
    case focus
    case gaming

    /// What the selector shows and says.
    public var title: String {
        switch self {
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
        case .entertainment: "sparkles"
        case .work: "briefcase.fill"
        case .focus: "target"
        case .gaming: "gamecontroller.fill"
        }
    }

    /// Words that place a post in this context. Lowercased; matched against a
    /// lowercased caption.
    ///
    /// Empty for `.entertainment`, which is not a keyword set at all — it is
    /// the absence of a filter, and `matches` says so before it ever looks.
    var keywords: [String] {
        switch self {
        case .entertainment: []
        case .work: ["work", "office", "meeting", "deadline", "refactor", "ship", "launch", "standup", "review", "build"]
        case .focus: ["focus", "deep work", "study", "reading", "quiet", "notes", "writing", "practice"]
        case .gaming: ["game", "gaming", "play", "stream", "speedrun", "boss", "level", "co-op", "controller"]
        }
    }

    /// Whether a post belongs in this context.
    func matches(_ post: GalleryPost) -> Bool {
        guard self != .entertainment else { return true }
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
        guard self != .entertainment else { return posts }
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

    public init(defaults: UserDefaults = .standard, key: String = "foryou.context") {
        self.defaults = defaults
        self.key = key
    }

    /// The stored context, or the default when nothing has been chosen — and
    /// also when something unrecognisable has been: a downgrade that wrote a
    /// context this build has never heard of degrades to Entertainment rather
    /// than to an empty screen.
    public var context: ContentContext {
        get { defaults.string(forKey: key).flatMap(ContentContext.init(rawValue:)) ?? .entertainment }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
