import CoreModels
import EmoteKit
import Foundation
import PostGrid

/// State for Settings → Your Activity → Recently Deleted (#408).
@MainActor
final class RecentlyDeletedViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([DeletedPost])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let trash: any PostTrashManaging
    private let viewer: any ProfileViewerResolving

    init(trash: any PostTrashManaging, viewer: any ProfileViewerResolving) {
        self.trash = trash
        self.viewer = viewer
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        guard let author = await viewer.viewerProfileID() else {
            phase = .failed
            return
        }
        do {
            phase = .loaded(try await trash.recentlyDeleted(for: author))
        } catch {
            phase = .failed
        }
    }

    /// Restores and drops the row once the server agrees. A post already
    /// back (restored elsewhere) leaves the list too.
    func restore(_ deleted: DeletedPost) async throws {
        guard let author = await viewer.viewerProfileID() else { throw PostRestoreError.transport(message: "no viewer") }
        do {
            try await trash.restorePost(deleted.post.id, author: author)
        } catch PostRestoreError.notDeleted {
            // Already back: nothing left to do but drop the row.
        }
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.post.id != deleted.post.id })
        }
    }

    /// The row's title: the caption with its `:codes:` as their emoji (the
    /// card renders them; a settings row shows the glyph), or what kind of
    /// post it was.
    static func title(of deleted: DeletedPost) -> String {
        var caption = deleted.post.caption
        if EmoteParser.mayContainEmotes(caption) {
            for match in EmoteParser.matches(in: caption).reversed() where match.isCode {
                caption.replaceSubrange(match.range, with: match.emote.glyph)
            }
        }
        caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { return caption }
        switch deleted.post.kind {
        case .video: return "Video"
        case .photo: return "Photo"
        case .text: return "Post"
        }
    }

    /// "27 days left", "1 day left", "Last day".
    static func remaining(_ deleted: DeletedPost, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let days = deleted.daysLeft(now: now, calendar: calendar) else { return nil }
        switch days {
        case 0: return "Last day"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }
}
