import CacheKit
import Foundation
import Synchronization

/// One video namespace as the coordinator sees it, registered before its
/// `DiskStore` has opened (#1018), as the image pipeline's signed disk is
/// (#991). Limits and a wipe that arrive meanwhile are kept and applied to the
/// store when it attaches, so a logout during the open still wipes
/// `video.signed`, and a Settings clear still empties `video`.
final class DeferredVideoDisk: ManagedCache {
    let namespace: CacheNamespace
    private let diskBudget: DiskBudget

    private struct State {
        var store: DiskStore?
        var limits: (CacheLimits, CacheEvictionReason)?
        var wipePending: CacheEvictionReason?
    }

    private let state = Mutex(State())

    init(namespace: CacheNamespace, budget: DiskBudget) {
        self.namespace = namespace
        diskBudget = budget
    }

    /// The store opened: what arrived before it is applied now.
    func attach(_ store: DiskStore) {
        let pending = state.withLock { state -> ((CacheLimits, CacheEvictionReason)?, CacheEvictionReason?) in
            state.store = store
            let taken = (state.limits, state.wipePending)
            state.wipePending = nil
            return taken
        }
        if let limits = pending.0 { store.setLimits(limits.0, reason: limits.1) }
        if let reason = pending.1 { store.removeAll(reason: reason) }
    }

    var store: DiskStore? { state.withLock { $0.store } }

    var budget: CacheBudget { .disk(diskBudget) }

    var usage: CacheUsage {
        if let store { return store.usage }
        return CacheUsage(byteLimit: state.withLock { $0.limits?.0.bytes ?? .max })
    }

    var statistics: CacheStatistics { store?.statistics ?? CacheStatistics() }

    func trim(_ depth: TrimDepth) { trim(depth, reason: .trim) }
    func trim(_ depth: TrimDepth, reason: CacheEvictionReason) { store?.trim(depth, reason: reason) }
    func flush() { store?.flush() }

    func setLimits(_ limits: CacheLimits) { setLimits(limits, reason: .budget) }

    func setLimits(_ limits: CacheLimits, reason: CacheEvictionReason) {
        let attached = state.withLock { state -> DiskStore? in
            state.limits = (limits, reason)
            return state.store
        }
        attached?.setLimits(limits, reason: reason)
    }

    func removeAll() { removeAll(reason: .wipe) }

    func removeAll(reason: CacheEvictionReason) {
        let attached = state.withLock { state -> DiskStore? in
            if state.store == nil { state.wipePending = reason }
            return state.store
        }
        attached?.removeAll(reason: reason)
    }
}
