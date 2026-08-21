import CoreModels
import UIKit

/// One row of a post card's "..." menu.
///
/// The SURFACE chooses which rows exist; this type owns what each one says and
/// how it reads. That split is the point: a Following feed and a profile
/// gallery offer different sets — Unfollow means nothing on a screen whose
/// header already owns the relationship — but "Report" must be the same word,
/// the same glyph and the same weight in both, and two hosts writing their own
/// `UIAction`s would agree on the day they were written.
///
/// Each case carries its own handler rather than the menu reporting a
/// selection back through one closure. A host builds the rows it can actually
/// service, so the row and the thing it does are decided in one place and an
/// action that cannot act is simply not built.
@MainActor
public enum PostCardMenuAction {
    /// Stop following the post's author. Offered where the viewer is looking at
    /// a feed OF the people they follow, and withheld where a screen already
    /// centralises the relationship on one control.
    case unfollow(perform: () -> Void)
    /// Raise a moderation case against the post.
    case report(perform: () -> Void)

    /// Public so a surface can audit what it composed — the menu itself is a
    /// system surface no screenshot can read.
    ///
    /// BARE VERBS, the same rule the profile's "..." settled on: the menu
    /// already belongs to a card that names its author two lines above, so the
    /// handle in the row was redundant. It was also actively worse — in the sim
    /// "Unfollow @sofia.reyes" wrapped to two lines and UIKit hyphenated it
    /// mid-handle, as "@sofi-a.reyes".
    public var title: String {
        switch self {
        case .unfollow: "Unfollow"
        case .report: "Report"
        }
    }

    var symbolName: String {
        switch self {
        case .unfollow: "person.badge.minus"
        case .report: "flag"
        }
    }

    /// Report is destructive in the menu's sense — it is the irreversible,
    /// consequence-carrying row. Unfollow deliberately is NOT: it is undone by
    /// following again, and painting it red would make the menu's one genuinely
    /// serious row indistinguishable from its routine one.
    var attributes: UIMenuElement.Attributes {
        switch self {
        case .unfollow: []
        case .report: .destructive
        }
    }

    var handler: () -> Void {
        switch self {
        case .unfollow(let perform), .report(let perform): perform
        }
    }

    var element: UIAction {
        UIAction(
            title: title,
            image: UIImage(systemName: symbolName),
            attributes: attributes
        ) { _ in handler() }
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

/// Builds the card's "..." menu from the rows a surface can service.
@MainActor
public enum PostCardMenu {
    /// `nil` when there is nothing to offer — a caller with no rows must hide
    /// the control rather than show one that opens an empty sheet.
    public static func menu(for actions: [PostCardMenuAction]) -> UIMenu? {
        guard !actions.isEmpty else { return nil }
        return UIMenu(children: actions.map(\.element))
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
