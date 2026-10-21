import CoreModels
import DesignSystem
import UIKit

/// One row of a post's menu — the long press's and the card's "..." alike
/// (#1498: ONE menu, built in one place, `PostCardMenu`).
///
/// The SURFACE chooses which rows exist; this type owns what each one says,
/// how it reads and where it goes. That split is the point: a Following feed
/// and a profile gallery offer different sets, but "Report" must be the same
/// word, the same glyph and the same weight in both.
///
/// Each case carries its own handler. A host builds the rows it can actually
/// service; a row that cannot act yet is built DISABLED where the owner wants
/// it seen (Repost until #801, Copy Link until posts have a URL).
@MainActor
public enum PostCardMenuAction {
    // MARK: The palette (one horizontal row of icons)

    /// Keep the post (the star). `isOn`: saved.
    case save(isOn: Bool, perform: () -> Void)
    /// Repost it. Nil `perform`: shown disabled (#801, the owner's choice).
    case repost(isOn: Bool, perform: (() -> Void)?)
    /// Open the post on its comments.
    case comment(perform: () -> Void)
    /// Like it — a Points stake, so the row OPENS the amounts (the owner's
    /// choice, #1498): `amounts` is the card heart's stake menu. `isOn`: the
    /// viewer has staked on it.
    case like(isOn: Bool, amounts: UIMenu)

    // MARK: The post

    /// The share sheet.
    case share(perform: () -> Void)
    /// Copy the caption.
    case copyText(perform: () -> Void)
    /// Copy the post's link. Nil `perform`: shown disabled — posts have no
    /// public URL yet (the owner's choice).
    case copyLink(perform: (() -> Void)?)
    /// Select the caption in place (#1498 §4).
    case selectText(perform: () -> Void)

    // MARK: The viewer's own post

    /// Change it.
    case edit(perform: () -> Void)
    /// Remove it.
    case delete(perform: () -> Void)
    /// Takes the post out of the viewer's viewing history (#1344).
    case removeFromHistory(perform: () -> Void)

    // MARK: The author (the "@handle ▸" submenu)

    /// Their profile.
    case viewProfile(perform: () -> Void)
    /// Start following the author.
    case follow(perform: () -> Void)
    /// Stop following the author.
    case unfollow(perform: () -> Void)
    /// Not interested: the post leaves this feed, with Undo (#957).
    case hide(perform: () -> Void)
    /// Mute the author (#689).
    case mute(perform: () -> Void)
    /// Block the author.
    case block(perform: () -> Void)
    /// Raise a moderation case against the post.
    case report(perform: () -> Void)

    /// Where a row sits in the menu.
    enum Group {
        case palette, post, own, author
    }

    var group: Group {
        switch self {
        case .save, .repost, .comment, .like: .palette
        case .share, .copyText, .copyLink, .selectText: .post
        case .edit, .delete, .removeFromHistory: .own
        case .viewProfile, .follow, .unfollow, .hide, .mute, .block, .report: .author
        }
    }

    /// Public so a surface can audit what it composed — the menu itself is a
    /// system surface no screenshot can read.
    ///
    /// BARE VERBS: the menu belongs to a card that names its author, and the
    /// author's rows sit under their handle — "Unfollow @sofia.reyes" wrapped
    /// and UIKit hyphenated it mid-handle.
    public var title: String {
        switch self {
        case .save(let isOn, _): isOn ? "Saved" : "Save"
        case .repost(let isOn, _): isOn ? "Reposted" : "Repost"
        case .comment: "Comment"
        case .like(let isOn, _): isOn ? "Liked" : "Like"
        case .share: "Share"
        case .copyText: "Copy Text"
        case .copyLink: "Copy Link"
        case .selectText: "Select Text"
        case .edit: "Edit post"
        case .delete: "Delete post"
        case .removeFromHistory: "Remove from History"
        case .viewProfile: "View Profile"
        case .follow: "Follow"
        case .unfollow: "Unfollow"
        case .hide: "Hide This Post"
        case .mute: "Mute"
        case .block: "Block"
        case .report: "Report"
        }
    }

    /// The glyph: the palette's FILLED when its state is on. Save, Like,
    /// Repost and Comment are the app's own symbols (#1128), from their
    /// contracts (`SaveStar`, `LikesSymbol`, #1190), as the card's are.
    var symbolName: String {
        switch self {
        case .save(let isOn, _): SaveStar.symbol(saved: isOn)
        case .repost: PostActionSymbol.repost
        case .comment: PostActionSymbol.comments
        case .like(let isOn, _): isOn ? LikesSymbol.glyph : LikesSymbol.outlineGlyph
        case .share: "square.and.arrow.up"
        case .copyText: "doc.on.doc"
        case .copyLink: "link"
        case .selectText: "selection.pin.in.out"
        case .edit: "pencil"
        case .delete: "trash"
        case .removeFromHistory: "clock.badge.xmark"
        case .viewProfile: "person.crop.circle"
        case .follow: "person.badge.plus"
        case .unfollow: "person.badge.minus"
        case .hide: "eye.slash"
        case .mute: "speaker.slash"
        case .block: "hand.raised"
        case .report: "flag"
        }
    }

    /// Report, Delete and Block are destructive — the irreversible,
    /// consequence-carrying rows. Unfollow is not: following again undoes it.
    var attributes: UIMenuElement.Attributes {
        switch self {
        case .report, .delete, .block: .destructive
        case .repost(_, let perform), .copyLink(let perform): perform == nil ? .disabled : []
        default: []
        }
    }

    var element: UIMenuElement {
        let image = UIImage.symbol(named: symbolName)
        switch self {
        case .like(_, let amounts):
            // The amounts, under the heart (the owner's choice).
            return UIMenu(title: title, image: image, children: amounts.children)
        default:
            let perform = handler
            return UIAction(title: title, image: image, attributes: attributes) { _ in perform?() }
        }
    }

    private var handler: (() -> Void)? {
        switch self {
        case .save(_, let perform), .comment(let perform), .share(let perform), .copyText(let perform),
             .selectText(let perform), .edit(let perform), .delete(let perform),
             .removeFromHistory(let perform), .viewProfile(let perform), .follow(let perform),
             .unfollow(let perform), .hide(let perform), .mute(let perform), .block(let perform),
             .report(let perform):
            perform
        case .repost(_, let perform), .copyLink(let perform):
            perform
        case .like:
            nil
        }
    }
}

/// Who the author submenu is named after: "@handle", their face as its image.
public struct PostCardMenuAuthor {
    public let handle: String
    public let face: UIImage?

    public init(handle: String, face: UIImage? = nil) {
        self.handle = handle
        self.face = face.map(Self.menuFace)
    }

    /// The side a face is drawn at in a menu row.
    static let faceSide: CGFloat = 24

    /// ⚠️ A MENU DRAWS AN IMAGE AT ITS OWN SIZE: the avatar's full picture
    /// filled the submenu's header (filmed). So the face is redrawn as a
    /// small disc, kept in its colours (`.alwaysOriginal`, not tinted).
    static func menuFace(_ image: UIImage) -> UIImage {
        let side = faceSide
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let disc = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(ovalIn: bounds).addClip()
            // Aspect-fill the square.
            let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        return disc.withRenderingMode(.alwaysOriginal)
    }
}

public extension GalleryPost {
    /// The identity slice a pushed profile can title itself with before its own
    /// load returns — assembled from what the row already drew.
    ///
    /// `nil` when the post carries no identity at all, which is the same
    /// condition that hides the author band: a stub with two empty strings
    /// would make the destination render a blank name rather than its
    /// placeholder.
    var authorIdentityStub: ProfileIdentityStub? {
        let name = authorName?.trimmingCharacters(in: .whitespaces) ?? ""
        let handle = authorHandle?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty || !handle.isEmpty else { return nil }
        return ProfileIdentityStub(handle: handle, displayName: name.isEmpty ? handle : name)
    }
}

/// Builds a post's menu from the rows a surface can service (#1498 §3):
///
/// ```
/// [ ☆ ] [ ⟳ ] [ 💬 ] [ ♡ ]        ← the palette: one row of icons
/// Share · Copy Text · Copy Link · Select Text
/// Edit post · Delete post · Remove from History   ← the viewer's own
/// @handle ▸  View Profile · Follow/Unfollow · Hide This Post · Mute · Block · Report
/// ```
///
/// The same builder for the long press and the card's "...", on every host.
@MainActor
public enum PostCardMenu {
    /// `nil` when there is nothing to offer — a caller with no rows must hide
    /// the control rather than show one that opens an empty sheet.
    ///
    /// `author`: the author rows go under a submenu named after them. Nil (a
    /// host that names no author, or the viewer's own post): inline.
    public static func menu(for actions: [PostCardMenuAction], author: PostCardMenuAuthor? = nil) -> UIMenu? {
        guard !actions.isEmpty else { return nil }
        return UIMenu(children: sections(for: actions, author: author))
    }

    /// The menu's sections, in reading order — what `menu` holds, for a host
    /// that adds them to a menu of its own.
    public static func sections(for actions: [PostCardMenuAction], author: PostCardMenuAuthor?) -> [UIMenuElement] {
        func rows(_ group: PostCardMenuAction.Group) -> [UIMenuElement] {
            actions.filter { $0.group == group }.map(\.element)
        }
        var sections: [UIMenuElement] = []
        let palette = rows(.palette)
        if !palette.isEmpty {
            sections.append(UIMenu(options: [.displayInline, .displayAsPalette], children: palette))
        }
        for group in [PostCardMenuAction.Group.post, .own] {
            let section = rows(group)
            if !section.isEmpty { sections.append(UIMenu(options: .displayInline, children: section)) }
        }
        let authorRows = rows(.author)
        if !authorRows.isEmpty {
            if let author, !author.handle.isEmpty {
                sections.append(UIMenu(options: .displayInline, children: [
                    UIMenu(title: "@" + author.handle, image: author.face ?? UIImage(systemName: "person.crop.circle"),
                           children: authorRows)
                ]))
            } else {
                sections.append(UIMenu(options: .displayInline, children: authorRows))
            }
        }
        return sections
    }
}

/// The reason picker a Report row opens.
///
/// `moderation.v1.OpenCase` carries a policy category, so the report asks for
/// one rather than filing everything as "other" — a category-less report is
/// near-useless to the moderation queue. The profile screen has asked this
/// question since its own menu shipped; this is that question, in the one place
/// both screens can reach.
@MainActor
public enum ReportReasonSheet {
    /// - Parameters:
    ///   - subject: what the title names, e.g. "this post".
    ///   - sourceView: the popover anchor. The control that opened the menu, so
    ///     a regular-width layout points the sheet back at the card it belongs
    ///     to rather than at the middle of the screen.
    public static func present(
        from presenter: UIViewController,
        subject: String,
        sourceView: UIView?,
        onPick: @escaping (ReportReason) -> Void
    ) {
        let sheet = UIAlertController(
            title: "Report \(subject)",
            message: "Why are you reporting \(subject)?",
            preferredStyle: .actionSheet
        )
        for reason in ReportReason.allCases {
            sheet.addAction(UIAlertAction(title: reason.title, style: .default) { _ in
                onPick(reason)
            })
        }
        // A Cancel row, unlike the "..." menu itself, because an action sheet
        // has no tap-outside affordance a viewer can be sure of.
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = sourceView ?? presenter.view
        if let sourceView {
            sheet.popoverPresentationController?.sourceRect = sourceView.bounds
        }
        presenter.present(sheet, animated: true)
    }
}
