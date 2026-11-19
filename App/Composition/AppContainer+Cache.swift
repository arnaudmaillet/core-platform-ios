import AuthInterface
import CacheKit
import CoreModels
import CoreStorage
import EntityStore
import Feed
import Foundation
import LocalStore
import MediaCore
import MediaPlayback
import OSLog
import UIKit
import Upload

// Device cache (#2375): the cache coordinator's signals, the entity store and
// the device store. Its properties are declared in `AppContainer.swift`, since
// an extension holds no stored property; they are built here.
extension AppContainer {
    /// Starts the coordinator's signal sources: memory warning and critical
    /// pressure, background and foreground, Low Power, thermal, the network
    /// path, and the viewer's transitions (`AppCacheSignals`). Called once at
    /// launch, before any cache is filled.
    func startCacheCoordinator() {
        guard !cacheSignalsStarted else { return }
        cacheSignalsStarted = true
        cacheCoordinator.startObserving(AppCacheSignals.sources())
        // UI assets (#971): the emote sheets, sticker strips, animated icons
        // and flag palette the kits announced, now and later, join the
        // coordinator as its longest-kept class.
        UIAssetCaches.shared.attach(to: cacheCoordinator)
        // The author's just-published clips (#898): a Videos namespace once
        // the first one is kept.
        publishedVideos.attach(to: cacheCoordinator)
        // What the coordinator's namespaces cannot hold (#898): every memory
        // signal also releases the playback pools' idle players, frame
        // generators and return players; the background sweeps the upload
        // files a dead flow left behind.
        releaseObservation = cacheCoordinator.observeTrims { reason in
            if reason.memoryPressure != nil {
                Task { @MainActor in AppContainer.releasePlaybackMemory() }
            }
            if reason == .background { UploadMediaFile.sweepOrphans() }
        }
        // Every disk store opens (index read, files reconciled) off the main
        // thread, before the first screen asks. The UI assets store is a lazy
        // static: touched here first, a main-thread reader meanwhile waits for
        // this open instead of doing its own.
        DispatchQueue.global(qos: .utility).async { _ = UIAssetCaches.disk }
        // Builds the image pipeline now, which opens its disk stores on a
        // utility task (#894).
        _ = imagePipeline
        #if DEBUG
        // `-cache-audit`: every namespace's bytes, hits, evictions per reason
        // and speculative fates, and the lookahead's counters, every 10 s and
        // after each trim (#900, `dev/CACHE_AUDIT.md`).
        cacheAudit = CacheAudit.startIfRequested(cacheCoordinator)
        #endif
    }

    func makeEntityStore() -> EntityStore {
        let store = EntityStore()
        store.register(with: cacheCoordinator)
        // The app's saved pile writes its fact here, and every save glyph
        // reads and observes it.
        postBookmarks.facts = store
        entityFollowSubscription = store.follow(followGraphEvents)
        // Every point the viewer stakes, from any surface, moves the post's
        // count (and every undo or refund moves it back).
        walletStakeLikes = WalletStakeLikes(wallet: walletStore, entities: store, scope: storageScope)
        // Rebuilt from the device at a cold start, and a delete reaches the
        // device's lists (`restoreEntitiesFromDevice`).
        entityDeviceBacking = feedLocalCache.map { EntityDeviceBacking(entities: store, cache: $0) }
        return store
    }

    func makeLocalStore() -> LocalStore? {
        // The JSON snapshot of the Following feed's first page, which the
        // store replaces (`FeedLocalCache.ListKey.following`). Not migrated:
        // it refills on the first online load.
        try? CodableFileStore<[FeedEntry]>(name: "feed-first-page").clear()
        do {
            let store = try LocalStore(viewer: { [storageScope] in LocalStoreViewer(storageScope.owner) })
            self.cacheCoordinator.register(store)
            return store
        } catch {
            Logger(subsystem: "cn.wynn.core-platform-ios", category: "local-store")
                .error("local store unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
