import CacheKit
import CoreStorage
import Foundation
import LocalStore
import OSLog

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
nonisolated final class WalletHistoryLocalCache: Sendable {
    static let entityType = "wallet.transaction"
    static let format = 1

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.wallet-history-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "wallet-history-cache")

    init(store: LocalStore) {
        self.store = store
    }

    /// Who a page is being fetched for, captured before the fetch.
    var viewer: LocalStoreViewer? { store.currentViewer }

    /// `filter`'s first page as last read; nil when none is stored.
    func firstPage(_ filter: String) -> WalletTransactionPage? {
        guard let list = store.list(Self.listKey(filter), maxPages: 1) else { return nil }
        let transactions = list.entries.compactMap { entity -> WalletTransaction? in
            guard entity.key.type == Self.entityType, entity.format == Self.format,
                  let record = try? JSONDecoder().decode(Record.self, from: entity.payload) else { return nil }
            return record.transaction
        }
        return WalletTransactionPage(transactions: transactions, nextPageToken: list.nextCursor)
    }

    func storeFirstPage(_ page: WalletTransactionPage, of filter: String, as viewer: LocalStoreViewer?) {
        let store = store
        let logger = logger
        queue.async {
            let encoder = JSONEncoder()
            let writes = page.transactions.compactMap { transaction -> LocalEntityWrite? in
                guard let payload = try? encoder.encode(Record(transaction)) else { return nil }
                return LocalEntityWrite(
                    key: LocalEntityKey(type: Self.entityType, id: transaction.id),
                    payload: payload, format: Self.format, lifetime: LocalStorePolicy.transcriptLifetime
                )
            }
            let listPage = LocalListPage(
                items: writes.map(\.key), entities: writes, nextCursor: page.nextPageToken, tier: .retained
            )
            do {
                try store.replaceList(
                    Self.listKey(filter), with: listPage, as: viewer, lifetime: LocalStorePolicy.transcriptLifetime
                )
            } catch {
                logger.error("wallet history cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func listKey(_ filter: String) -> String { "wallet.history.\(filter)" }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
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
