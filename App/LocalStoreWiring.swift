import CoreStorage
import Foundation
import LocalStore

extension LocalStoreViewer {
    /// Whose rows the device store may hold, from `StorageScope`: nobody
    /// before the first render (`unscoped`), so nothing is read or written
    /// until the app knows who is here. Asked by the store on any thread.
    nonisolated init?(_ owner: StorageScope.Owner) {
        switch owner {
        case .unscoped: return nil
        case .guest: self = .guest
        case .member(let account, let profile): self = .member(account: account, profile: profile)
        }
    }
}
