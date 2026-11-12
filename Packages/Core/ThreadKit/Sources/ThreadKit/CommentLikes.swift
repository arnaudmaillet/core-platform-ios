import Foundation

/// A comment's likes (#637): its count — everyone's points — and the
/// viewer's own points on it.
public struct CommentLikes: Equatable, Sendable {
    public var count: Int64
    public var mine: Int64

    public init(count: Int64, mine: Int64) {
        self.count = count
        self.mine = mine
    }
}
