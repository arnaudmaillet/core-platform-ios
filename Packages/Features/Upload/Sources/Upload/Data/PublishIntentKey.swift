import CoreNetworking
import Foundation

/// A compose screen's CreatePost key (#795): one per publish intent, handed
/// back by every retry of the same post, and a new one once its content
/// changes.
///
/// ⚠️ **KEYED BY CONTENT, AND FORGOTTEN ON SUCCESS.** A retry of the same
/// post after a lost answer must be answered with the post it created, so
/// the same content gets the same key. An edit makes it another post — the
/// old key would be answered with the OLD post — so other content gets a new
/// key. And once a post is up, the same content again is a deliberate second
/// post, so a success forgets the key.
final class PublishIntentKey: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (content: String, key: String)?

    init() {}

    /// The key for a publish of `content`: the one the last unsettled
    /// attempt at the same content used, or a new one.
    func key(for content: String) -> String {
        lock.withLock {
            if let held = current, held.content == content { return held.key }
            let minted = IdempotencyKey.mint()
            current = (content, minted)
            return minted
        }
    }

    /// The post is up: the next publish is a new intent.
    func settle() {
        lock.withLock { current = nil }
    }
}
