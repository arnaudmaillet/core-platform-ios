import CacheKit
import CoreStorage
import Foundation
import LocalStore

/// The wallet's history on the device (#1776), in the LocalStore: each
/// filter (All, Likes, Gems) opens on its last first page, at the next visit
/// or launch and on a filter change, then revalidates in place — it cleared
/// and reloaded every time.
///
/// One list per filter (`wallet.history.<filter>`), the first page only with
/// the cursor past it, each movement a versioned `wallet.transaction` record
/// whose kind and currency are fixed words. The viewer's own ledger, so
/// `retained`; the store's viewer scope keeps it the viewer's, and a sign-out
/// or a switch wipes it with the other device caches (the history then reads
/// again after a profile switch, the wallet being the account's).
///
/// Reads are synchronous (the screen's first frame); writes go to a serial
/// queue, each as the viewer captured BEFORE its network call.
public nonisolated final class WalletHistoryLocalCache: Sendable {
    static let entityType = "wallet.transaction"
    static let format = 1

    private let list: LocalRecordList<Record>

    public init(store: LocalStore) {
        list = LocalRecordList(store: store, entityType: Self.entityType, format: Self.format, name: "wallet-history")
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { list.viewer }

    /// `filter`'s first page as last read; nil when none is stored.
    func firstPage(_ filter: String) -> WalletTransactionPage? {
        guard let stored = list.read(Self.listKey(filter), maxPages: 1) else { return nil }
        return WalletTransactionPage(transactions: stored.records.compactMap(\.transaction), nextPageToken: stored.nextCursor)
    }

    func storeFirstPage(_ page: WalletTransactionPage, of filter: String, as viewer: LocalStoreViewer?) {
        list.write(
            page.transactions.map { (id: $0.id, record: Record($0)) }, to: Self.listKey(filter),
            nextCursor: page.nextPageToken, as: viewer, lifetime: LocalStorePolicy.transcriptLifetime
        )
    }

    static func listKey(_ filter: String) -> String { "wallet.history.\(filter)" }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        list.waitForPendingWrites()
    }

    /// One movement as stored, its enums in fixed words: the file outlives
    /// the enums' shape, and a word this build does not know reads as
    /// `.other`, as the server's own unknown kinds do.
    struct Record: Codable, Equatable {
        var id: String
        var currency: String
        var delta: Int
        var balanceAfter: Int
        var kind: String
        var createdAt: Date?
        var reference: String?

        init(_ transaction: WalletTransaction) {
            id = transaction.id
            currency = transaction.currency == .gems ? "gems" : "likes"
            delta = transaction.delta
            balanceAfter = transaction.balanceAfter
            kind = Self.word(for: transaction.kind)
            createdAt = transaction.createdAt
            reference = transaction.reference
        }

        var transaction: WalletTransaction? {
            let decodedCurrency: WalletTransaction.Currency
            switch currency {
            case "gems": decodedCurrency = .gems
            case "likes": decodedCurrency = .likes
            default: return nil
            }
            return WalletTransaction(
                id: id, currency: decodedCurrency, delta: delta, balanceAfter: balanceAfter,
                kind: Self.kinds[kind] ?? .other, createdAt: createdAt, reference: reference
            )
        }

        private static let kinds: [String: WalletTransaction.Kind] = [
            "claim": .claim, "starterGift": .starterGift, "stakePack": .stakePack, "countryUnlock": .countryUnlock,
            "stake": .stake, "welcomeGift": .welcomeGift, "appIcon": .appIcon, "theme": .theme,
            "countryVisa": .countryVisa, "profileSlot": .profileSlot, "handleChange": .handleChange,
            "avatarFrame": .avatarFrame, "animatedBanner": .animatedBanner, "cardStyle": .cardStyle,
            "animatedAvatar": .animatedAvatar, "other": .other,
        ]

        static func word(for kind: WalletTransaction.Kind) -> String {
            kinds.first { $0.value == kind }?.key ?? "other"
        }
    }
}
