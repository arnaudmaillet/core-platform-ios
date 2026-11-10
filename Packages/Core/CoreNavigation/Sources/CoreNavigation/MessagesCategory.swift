/// The Messages inbox's top-level surfaces, in paging order.
///
/// Lives here rather than in the Chat feature because `AppRoute` carries it:
/// a push payload or universal link has to be able to open the inbox *on* a
/// category, and the shell must not import a feature to parse its own routes.
/// The raw values are the deep-link tokens (`-open-messages requests`).
///
/// ⚠️ NO CHANNELS PAGE (#2230). Channels had a page of their own here
/// (#2215) and joined Chats instead: a channel is read like a chat, and the
/// selector was short of room with three tabs. A token left behind by it
/// (`-open-messages channels`, a stored or linked "channels") no longer
/// parses — `MessagesCategory(rawValue:)` answers nil — and every caller
/// falls back to `.all`, so such a route lands on Chats, where the channels
/// now are.
public enum MessagesCategory: String, CaseIterable, Sendable {
    /// Chats: every active conversation — DMs, groups and channels (#2230),
    /// sorted together. Unread ones are marked in place (bold row, dot, and
    /// a count on this tab) rather than split into a tab of their own.
    case all
    /// Pending message requests from accounts the viewer doesn't follow.
    case requests
    /// Personalized account recommendations.
    case suggestions
}
