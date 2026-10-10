/// Reads a whole token-paged list: the first page asked with an empty token,
/// each next page with the token the one before handed back, until a page
/// hands back an empty token — the contract's "the list ended" — or
/// `maxPages` pages have been read.
///
/// ⚠️ **BOUNDED ON PURPOSE.** A server that kept handing back a token must
/// not spin the loop forever, so the cap is not optional. What the cap cuts
/// off is simply not returned: callers ask for lists that are short by
/// nature (blocks, mutes, appeals) and size the cap far above them.
///
/// Errors are the caller's own: whatever `fetch` throws ends the read and is
/// rethrown as is, and the pages read before it are dropped with it.
public enum TokenPager {
    public static func collect<Item>(
        maxPages: Int,
        isolation: isolated (any Actor)? = #isolation,
        fetch: (_ pageToken: String) async throws -> (items: [Item], nextPageToken: String)
    ) async rethrows -> [Item] {
        var items: [Item] = []
        var pageToken = ""
        for _ in 0..<max(maxPages, 0) {
            let page = try await fetch(pageToken)
            items += page.items
            pageToken = page.nextPageToken
            if pageToken.isEmpty { break }
        }
        return items
    }
}
