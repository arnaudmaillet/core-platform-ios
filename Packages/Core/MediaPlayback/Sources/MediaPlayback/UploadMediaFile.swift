import Foundation
import Synchronization

/// One intermediate media file of the upload flows (#898): the clip
/// `VideoExporter` writes for an upload (`export-<uuid>.mp4`) and the file a
/// picked library video is flattened into (`picked-<uuid>.mov`).
///
/// ⚠️ **THE FILE DIES WITH ITS OWNER — `TempFileBag`'S RULE.** Whoever holds
/// this object holds the file: an `ExportedVideo` on its way to a post or a
/// message, a library sheet holding what it flattened. The last reference
/// gone, the file is deleted, so nothing has to be remembered one by one to be
/// cleaned up. Both used to stay in the temporary directory for good.
///
/// ⚠️ **AND A PROCESS THAT DIES NEVER RUNS `deinit`.** Every file lives in one
/// folder, `tmp/UploadMedia`, and `sweepOrphans` deletes each one no live
/// owner names: the camera, the library sheet and the background call it.
/// Owners are known by file name, registered in `init` before anything is
/// written, and the folder is listed BEFORE the owners are read, so a file
/// made during a sweep is never taken for an orphan (`CaptureFolder`'s order).
public final class UploadMediaFile: Sendable {
    /// Where every upload media file is made.
    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UploadMedia", isDirectory: true)
    }

    /// The names of the files a live owner holds.
    private static let live = Mutex<Set<String>>([])

    public let url: URL

    /// A fresh file name in `folder`, `<prefix>-<uuid>.<pathExtension>`; the
    /// folder is made now, the file by whoever writes it.
    public init(prefix: String, pathExtension: String, folder: URL = UploadMediaFile.folder) {
        let name = "\(prefix)-\(UUID().uuidString).\(pathExtension)"
        url = folder.appendingPathComponent(name, isDirectory: false)
        Self.live.withLock { _ = $0.insert(name) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Deletes released files, off the thread that let go of them (often
    /// main: a sheet closing, a bubble sent).
    private static let deletions = DispatchQueue(label: "MediaPlayback.UploadMediaFile.deletions", qos: .utility)

    deinit {
        let name = url.lastPathComponent
        Self.live.withLock { _ = $0.remove(name) }
        // Gone already when it was moved into a cache (a published clip).
        let doomed = self.url
        Self.deletions.async { try? FileManager.default.removeItem(at: doomed) }
    }

    /// Waits until every released file is deleted. Tests only.
    static func waitForDeletions() {
        deletions.sync {}
    }

    /// Deletes every file in `folder` no live owner holds, off the caller's
    /// thread, then calls `done`. With `legacyFolder` (the temporary directory
    /// by default), also the `export-*.mp4` and `picked-*.mov` files earlier
    /// builds left at its root, which nothing owns any more.
    public static func sweepOrphans(
        in folder: URL = UploadMediaFile.folder,
        legacyFolder: URL? = FileManager.default.temporaryDirectory,
        then done: (@Sendable () -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .utility).async {
            let manager = FileManager.default
            let found = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let owned = live.withLock { $0 }
            for file in found where !owned.contains(file.lastPathComponent) {
                try? manager.removeItem(at: file)
            }
            if let legacyFolder {
                let legacy = (try? manager.contentsOfDirectory(at: legacyFolder, includingPropertiesForKeys: nil)) ?? []
                for file in legacy where isLegacyUploadFile(file.lastPathComponent) {
                    try? manager.removeItem(at: file)
                }
            }
            done?()
        }
    }

    /// `export-<uuid>.mp4` and `picked-<uuid>.mov`, as written at the root of
    /// the temporary directory before #898.
    static func isLegacyUploadFile(_ name: String) -> Bool {
        (name.hasPrefix("export-") && name.hasSuffix(".mp4")) || (name.hasPrefix("picked-") && name.hasSuffix(".mov"))
    }

    /// The files a live owner holds now, for tests.
    static var liveNames: Set<String> { live.withLock { $0 } }
}
