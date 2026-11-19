import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#2376): the economy's and the storage scope's
/// changes are observed on the instance that changed, typed
/// (`StoreChanges`, `StakePackSelling.observeChanges`,
/// `LikeOutboxSender.onLikesGivenBack`), never through a name posted on
/// `NotificationCenter.default`.
///
/// A raw name was heard by anyone, from any instance: an observer with
/// `object: nil` answered for every wallet in the process, parallel test
/// suites heard each other's posts, and the payload was an untyped
/// `userInfo`. The retired names below must not come back, neither as the
/// string a `Notification.Name` was made of nor as the Swift name it was
/// reached by — in sources or in tests, under `App/` and `Packages/`.
///
/// A repository guard (`RepoGuards`, #2371): every pull request runs it.
struct NotificationNameGuardTests {
    /// The strings the retired `Notification.Name`s were made of.
    static let retiredRawNames: [String] = [
        "wallet.didChange",
        "wallet.stakeRefunded",
        "likeOutbox.didChange",
        "countries.unlocks.didChange",
        "profile.items.didChange",
        "stakePack.didChange",
        "LikeOutboxSender.likesGivenBack",
        "welcomeGift.didChange",
        "storageScope.didChange",
    ]

    /// The Swift names they were reached by.
    static let retiredSymbols: [String] = [
        "WalletStore.didChangeNotification",
        "WalletStore.stakeRefundedNotification",
        "LikeOutbox.didChangeNotification",
        "CountryUnlockStore.didChangeNotification",
        "ProfileItemStore.didChangeNotification",
        "stakePackDidChange",
        "LikeOutboxSender.likesGivenBack",
        "LikeOutboxSender.givenBackKey",
        "WelcomeGift.didChangeNotification",
        "StorageScope.didChangeNotification",
    ]

    /// `text` without its comments (line comments and doc comments), so a
    /// comment that tells the story of a retired name is not a use.
    static func code(_ text: String) -> String {
        ViewerStoreGuardTests.code(text)
    }

    /// The retired names `code` uses: a raw name as a string literal, or a
    /// symbol as a whole word.
    static func retiredNames(in code: String) -> [String] {
        let raw = retiredRawNames.filter { code.contains("\"\($0)\"") }
        let symbols = retiredSymbols.filter { symbol in
            let pattern = #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: symbol) + #"(?!\w)"#
            return code.range(of: pattern, options: .regularExpression) != nil
        }
        return raw + symbols
    }

    /// Every Swift file under `App/` and `Packages/`, tests included: its
    /// path from the repository root, and its code (comments dropped).
    static func files() -> [(path: String, code: String)] {
        var files: [(path: String, code: String)] = []
        let root = ViewerStoreGuardTests.root
        let rootPath = root.path + "/"
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                // This guard names every retired name, on purpose.
                guard url.pathExtension == "swift", !path.contains("/.build/"),
                      !path.hasSuffix("/NotificationNameGuardTests.swift"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
                files.append((relative, code(text)))
            }
        }
        return files
    }

    @Test func theGuardReadsNamesAndSymbols() {
        let text = """
        static let didChangeNotification = Notification.Name("wallet.didChange")
        center.addObserver(forName: WalletStore.didChangeNotification, object: wallet, queue: nil) { _ in }
        NotificationCenter.default.post(name: .stakePackDidChange, object: nil)
        /// Was `WalletStore.didChangeNotification` ("wallet.didChange").
        let fine = Notification.Name("wallet.didChangeSomethingElse")
        let alsoFine = wallet.changes // WalletStore.didChangeNotification
        let notMine = MapFavoritesStore.didChangeNotification
        """
        let found = Self.retiredNames(in: Self.code(text))
        #expect(found.sorted() == ["WalletStore.didChangeNotification", "stakePackDidChange", "wallet.didChange"])
        #expect(Self.retiredNames(in: "let x = myStorageScope.didChangeNotificationCount").isEmpty)
    }

    @Test func noRetiredNotificationNameComesBack() {
        let files = Self.files()
        // The guard sees the files it was written against.
        #expect(files.contains { $0.path.hasSuffix("CoreStorage/StoreChanges.swift") })

        let found = files.flatMap { file in
            Self.retiredNames(in: file.code).map { "\(file.path): \($0)" }
        }
        #expect(
            found.isEmpty,
            "A retired notification name is back — observe the instance's typed changes instead: \(found)"
        )
    }
}
