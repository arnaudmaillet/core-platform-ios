import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// A comment's (or a message's) avatar spans EXACTLY the name line and the
/// body's first line, so it stands centred on the two lines it belongs to.
@MainActor
struct CommentRowAvatarTests {
    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    private func laidOutRow(body: String, width: CGFloat = 300) -> CommentRowView {
        let row = CommentRowView()
        row.configure(with: CommentDisplayModel(
            id: "c", authorID: ProfileID("a"), authorName: "Ava Moreau",
            metaText: "5m", body: body, avatarURL: nil
        ))
        let size = row.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        row.frame = CGRect(origin: .zero, size: size)
        row.layoutIfNeeded()
        return row
    }

    @Test(arguments: [
        "One line.",
        "A body long enough to wrap onto a second line in a row this narrow, and then onto a third one.",
    ])
    func theAvatarSpansTheNameLineAndTheFirstLineOfText(body: String) throws {
        let row = laidOutRow(body: body)
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: row))
        let label = row.bodyTextLabel
        let disc = avatar.convert(avatar.bounds, to: row)
        let text = label.convert(label.bounds, to: row)
        let firstLineBottom = text.minY + (label.font?.lineHeight ?? 0)

        #expect(abs(disc.minY) < 0.5, "the disc starts level with the name line")
        #expect(abs(disc.maxY - firstLineBottom) < 1, "the disc ends with the body's first line")
        #expect(disc.width == disc.height)
    }

    @Test func aReplyStepsInByTheAvatarColumn() {
        #expect(CommentRowView.replyIndent == CommentRowView.avatarSize + 8)
    }
}
