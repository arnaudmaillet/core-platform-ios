import Foundation

/// How close to the end of an inbox list a row has to be for its coming on
/// screen to ask for the next page (#593).
enum InboxPaging {
    static let nearEndRowCount = 5
    /// The rows whose peers' relations are asked for before the list has
    /// laid out (#2049): about two screens.
    static let relationLookahead = 20
}
