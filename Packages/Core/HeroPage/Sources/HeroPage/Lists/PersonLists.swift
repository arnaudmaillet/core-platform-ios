import Foundation
import os

/// The lists behind a hero header's counters (#2237): one screen of tabs,
/// each a paged list of people — a group's Members / Admins / Requests /
/// Followers, a channel's Subscribers / Admins / Requests — as a profile's
/// counters open its Followers / Following / Friends.
///
/// A feature hands the screen (`PersonListsViewController`) its tabs and a
/// `PersonListsSource`: the pages, and what a row's tap, its "⋯" and its
/// Approve / Decline do. Every rule stays the feature's; this draws.
///
/// ⚠️ Shared, so it lives in Core: a feature never imports another, and the
/// group's and the channel's lists (Chat) are drawn by the same screen a
/// profile's would be.
public struct PersonListTab: Equatable, Sendable {
    /// What the source knows the tab by.
    public let id: String
    /// The strip's words for it — its count and its name ("64 Subscribers").
    public var title: String
    /// What an empty tab says, in place of rows: never a header over nothing.
    public var empty: Empty
    /// A row that leads the tab ("Add Members", "Add Admin"), for a viewer
    /// who may add. Nil: none.
    public var leadingAction: LeadingAction?

    public struct Empty: Equatable, Sendable {
        public let symbol: String
        public let title: String
        public let message: String?

        public init(symbol: String, title: String, message: String? = nil) {
            self.symbol = symbol
            self.title = title
            self.message = message
        }
    }

    public struct LeadingAction: Equatable, Sendable {
        public let title: String
        public let symbol: String

        public init(title: String, symbol: String) {
            self.title = title
            self.symbol = symbol
        }
    }

    public init(id: String, title: String, empty: Empty, leadingAction: LeadingAction? = nil) {
        self.id = id
        self.title = title
        self.empty = empty
        self.leadingAction = leadingAction
    }
}

/// One person in a list: the shared person row (`PersonListCell`, #2145).
public struct PersonListRow: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    /// Under the name: a role, an @handle, when they asked.
    public var detail: String
    public var avatarURL: URL?
    public var monogram: String
    /// The row's "⋯" (and its long press): what the viewer may do to them.
    /// Empty: no "⋯".
    public var actions: [PersonListRowAction]
    /// A join request: Approve and Decline trail the row (#2231).
    public var answersRequest: Bool
    /// A tap opens them; false for the viewer's own row.
    public var opens: Bool

    public init(
        id: String, name: String, detail: String, avatarURL: URL? = nil, monogram: String,
        actions: [PersonListRowAction] = [], answersRequest: Bool = false, opens: Bool = true
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.avatarURL = avatarURL
        self.monogram = monogram
        self.actions = actions
        self.answersRequest = answersRequest
        self.opens = opens
    }
}

/// One entry of a row's "⋯".
public struct PersonListRowAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let isDestructive: Bool

    public init(id: String, title: String, isDestructive: Bool = false) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
    }
}

/// One page of a tab, as the source read it.
public struct PersonListPage: Equatable, Sendable {
    public let rows: [PersonListRow]
    /// Nil: the last page.
    public let nextPageToken: String?
    /// Everyone the tab holds — what its counter says.
    public let total: Int

    public init(rows: [PersonListRow], nextPageToken: String?, total: Int) {
        self.rows = rows
        self.nextPageToken = nextPageToken
        self.total = total
    }
}

/// What the lists ask of the feature that opened them.
@MainActor
public protocol PersonListsSource: AnyObject {
    /// Tab `tab`'s page after `token` (nil: the first).
    func page(of tab: String, after token: String?) async throws -> PersonListPage
    /// A row was tapped: their profile, usually.
    func open(_ row: PersonListRow, in tab: String, from screen: PersonListsViewController)
    /// An entry of a row's "⋯" was picked. The source confirms what needs
    /// it, writes, and reloads the tabs the write changed (`reload`).
    func perform(_ action: PersonListRowAction, on row: PersonListRow, in tab: String, from screen: PersonListsViewController)
    /// A request's Approve or Decline.
    func answer(_ row: PersonListRow, approve: Bool, in tab: String, from screen: PersonListsViewController)
    /// The tab's leading row ("Add Members").
    func performLeadingAction(in tab: String, from screen: PersonListsViewController)
}

/// One tab's rows, read page by page (#2237): the first page when the tab
/// is first shown, the next as the list nears its end — nothing reads a
/// whole audience at once.
///
/// ⚠️ THE COUNTER AND THE LIST AGREE. A list that ends shorter than the
/// total its pages said is a bug in what served it, reported
/// (`onShortList`, a fault in the log), never drawn as a gap.
@MainActor
public final class PersonListFeed {
    public enum Phase: Equatable, Sendable {
        case loading
        case content(rows: [PersonListRow], isLoadingMore: Bool)
        case empty
        case failed(String)
    }

    public let tab: String
    public private(set) var phase: Phase = .loading { didSet { if phase != oldValue { onChange?(phase) } } }
    /// The rows so far.
    public private(set) var rows: [PersonListRow] = []
    /// The total the last page said.
    public private(set) var total = 0
    /// Whether the last page has been read.
    public private(set) var isComplete = false
    /// How many pages have been asked for. Tests.
    public private(set) var pagesRequested = 0

    public var onChange: ((Phase) -> Void)?
    /// The list ended with fewer rows than its total: `(rows, total)`.
    public var onShortList: ((Int, Int) -> Void)?

    private weak var source: (any PersonListsSource)?
    private var nextToken: String?
    private var isLoading = false
    private var hasStarted = false
    /// Bumped by `reload`: an answer to an older read is dropped.
    private var generation = 0

    public init(tab: String, source: any PersonListsSource) {
        self.tab = tab
        self.source = source
    }

    /// The first page, once.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        read(after: nil)
    }

    /// From the first page again — after a write, a pull.
    public func reload() {
        hasStarted = true
        generation += 1
        isLoading = false
        nextToken = nil
        isComplete = false
        if rows.isEmpty { phase = .loading }
        read(after: nil, replacing: true)
    }

    /// The next page, when the list nears its end and there is one.
    public func loadMoreIfNeeded() {
        guard hasStarted, !isLoading, !isComplete, let token = nextToken else { return }
        if case .content(let shown, _) = phase { phase = .content(rows: shown, isLoadingMore: true) }
        read(after: token)
    }

    private func read(after token: String?, replacing: Bool = false) {
        guard let source else { return }
        isLoading = true
        pagesRequested += 1
        let asked = generation
        let tab = tab
        Task { [weak self] in
            do {
                let page = try await source.page(of: tab, after: token)
                self?.adopt(page, generation: asked, replacing: replacing || token == nil)
            } catch {
                self?.fail(error, generation: asked)
            }
        }
    }

    private func adopt(_ page: PersonListPage, generation asked: Int, replacing: Bool) {
        guard asked == generation else { return }
        isLoading = false
        var next = replacing ? [] : rows
        let known = Set(next.map(\.id))
        next += page.rows.filter { !known.contains($0.id) }
        rows = next
        total = page.total
        nextToken = page.nextPageToken
        isComplete = page.nextPageToken == nil
        if isComplete, rows.count < total {
            let tab = tab, shown = rows.count, expected = total
            Self.log.fault("list \(tab, privacy: .public) ended at \(shown) of \(expected)")
            onShortList?(shown, expected)
        }
        phase = rows.isEmpty ? .empty : .content(rows: rows, isLoadingMore: false)
    }

    private func fail(_ error: Error, generation asked: Int) {
        guard asked == generation else { return }
        isLoading = false
        // A page past the first that fails keeps what is shown: the next
        // approach of the end asks again.
        if !rows.isEmpty {
            phase = .content(rows: rows, isLoadingMore: false)
            return
        }
        phase = .failed(error.localizedDescription)
    }

    private static let log = Logger(subsystem: "HeroPage", category: "PersonLists")
}
