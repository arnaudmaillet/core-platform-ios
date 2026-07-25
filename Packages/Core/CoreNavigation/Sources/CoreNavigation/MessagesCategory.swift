/// The Messages inbox's top-level surfaces, in paging order.
///
/// Lives here rather than in the Chat feature because `AppRoute` carries it:
/// a push payload or universal link has to be able to open the inbox *on* a
/// category, and the shell must not import a feature to parse its own routes.
/// The raw values are the deep-link tokens (`-open-messages requests`).
public enum MessagesCategory: String, CaseIterable, Sendable {
    /// Active direct-message conversations. Unread ones are marked in place
    /// (bold row, dot, and a count on this tab) rather than split into a tab
    /// of their own.
    case all
    /// Pending message requests from accounts the viewer doesn't follow.
    case requests
    /// Personalized account recommendations.
    case suggestions
}
