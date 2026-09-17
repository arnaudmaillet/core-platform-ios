#if DEBUG
import Photos

/// Creates a few albums in the DEVICE photo library, behind `-seed-photo-albums`.
///
/// ⚠️ **THE ONLY PHOTOKIT WRITE IN THIS APP, AND IT IS DEBUG-ONLY.** Everything
/// else reads. It exists because of a measured gap: a simulator ships assets but
/// NO user albums — its `Photos.sqlite` holds 26 assets and only Apple's own
/// `progress-ota-restore` / `progress-sync` / `progress-fs-import` rows — and
/// `xcrun simctl addmedia` cannot create one, it adds assets and nothing else.
/// So `PhotosMediaLibrary`'s user-album branch had nothing to enumerate and the
/// picker's strip showed smart albums alone. The code was already right; the
/// fixture was empty.
///
/// ⚠️ **ADDITIVE AND IDEMPOTENT.** It creates albums that do not already exist
/// and files EXISTING assets into them. Nothing is deleted, nothing is
/// imported, and a second run finds its own albums and does nothing. That
/// restraint is deliberate: this writes to a library the developer owns and did
/// not ask us to reorganise.
@MainActor
enum DebugPhotoAlbumSeeder {
    private static let flag = "-seed-photo-albums"
    private static var hasRun = false

    /// Which assets land in which album. The ranges overlap a little, exactly as
    /// real albums do — the same photograph is often in two of them.
    ///
    /// ⚠️ **THE FIRST WINDOW STARTS AT ZERO, AND WITH VIDEOS IN THE LIBRARY THAT
    /// IS WHAT PUTS CLIPS IN AN ALBUM.** The fetch is newest-first and
    /// `simctl addmedia` stamps what it adds as the newest thing there, so the
    /// videos `Scripts/seed-simulator-videos.sh` puts in sit at the head of the
    /// run and land in the leading windows. Said out loud because it is ordering
    /// luck rather than a rule: an album is a slice of a sorted list, and nothing
    /// here promises each album a clip.
    private static let plan: [(title: String, drop: Int, take: Int)] = [
        ("Paris 2026", 0, 8),
        ("Family", 5, 6),
        ("Portraits", 11, 7)
    ]

    static func seedIfAsked() async {
        guard ProcessInfo.processInfo.arguments.contains(flag), !hasRun else { return }
        hasRun = true

        // Creating a collection needs write access; add-only is not enough.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            // ⚠️ SAID OUT LOUD. A silent return here looks exactly like a seeder
            // that ran and created nothing, and telling those apart cost a
            // round: the app was in fact parked on the permission dialog, so
            // `albums()` — and this — had never been reached at all.
            print("[seed] refused: photo authorization is \(status.rawValue), not authorized")
            return
        }

        let existing = existingAlbumTitles()
        let wanted = plan.filter { !existing.contains($0.title) }
        print("[seed] \(plan.count) planned, \(existing.count) albums already present, \(wanted.count) to create")
        for entry in wanted {
            await create(entry.title, drop: entry.drop, take: entry.take)
        }
    }

    private static func existingAlbumTitles() -> Set<String> {
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var titles: Set<String> = []
        for index in 0..<fetched.count {
            if let title = fetched.object(at: index).localizedTitle { titles.insert(title) }
        }
        return titles
    }

    /// ⚠️ **THE FETCH HAPPENS INSIDE THE CHANGE BLOCK.** `PHFetchResult` and
    /// `PHAsset` are not `Sendable`, so carrying them into an escaping closure
    /// is precisely what strict concurrency refuses. Fetched in place, nothing
    /// crosses a boundary and the compiler has nothing to complain about.
    private static func create(_ title: String, drop: Int, take: Int) async {
        do {
            try await performCreate(title, drop: drop, take: take)
            print("[seed] created \"\(title)\"")
        } catch {
            // ⚠️ **NOT `try?`.** A swallowed failure is indistinguishable from a
            // seeder that never ran, and that ambiguity is precisely what made
            // the first attempt unreadable.
            print("[seed] FAILED \"\(title)\": \(error)")
        }
    }

    /// ⚠️ **`nonisolated`, AND THE APP CRASHED WITHOUT IT.** This enum is
    /// `@MainActor`, so a closure written inside it inherits main-actor
    /// isolation — but `PHPhotoLibrary` states plainly in its own header that
    /// "handlers are invoked on an arbitrary serial queue", and imports the
    /// block as a bare `dispatch_block_t` with no `@Sendable`. So the compiler
    /// accepts the closure and the RUNTIME traps: `EXC_BREAKPOINT` on
    /// `com.apple.PHPhotoLibrary.changes`, through
    /// `swift_task_isCurrentExecutorWithFlagsImpl` → `dispatch_assert_queue_fail`.
    ///
    /// Taking the isolation off THIS function is the narrow fix. Dropping
    /// `@MainActor` from the type would work too and would cost more: `hasRun`
    /// would then need `nonisolated(unsafe)` for nothing gained.
    nonisolated private static func performCreate(_ title: String, drop: Int, take: Int) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // ⚠️ **IMAGES *AND* VIDEOS, AND FETCHING ONLY IMAGES WAS A HOLE.**
            // `PhotosMediaLibrary` admits both everywhere it looks, so an album
            // seeded from stills alone showed a count and a grid that disagreed
            // with what the same library reports for "Recents" — and the album
            // tabs, which is where a person goes looking for a clip, had none.
            //
            // ⚠️ **AND THE PREDICATE IS WRITTEN OUT HERE RATHER THAN BORROWED.**
            // `PhotosMediaLibrary.contents` is the same shape and cannot be
            // reached: that type conforms to a `@MainActor` protocol, so its
            // statics are main-actor isolated, and this function is deliberately
            // `nonisolated` — see below for what happens when it is not. A
            // `PHFetchOptions` is not `Sendable` either, so it could not cross
            // even if it were reachable.
            options.predicate = NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
            let assets = PHAsset.fetchAssets(with: options)
            guard assets.count > drop else { return }

            var picked: [PHAsset] = []
            var index = drop
            while index < assets.count, picked.count < take {
                picked.append(assets.object(at: index))
                index += 1
            }
            guard !picked.isEmpty else { return }

            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets(picked as NSArray)
        }
    }
}
#endif
