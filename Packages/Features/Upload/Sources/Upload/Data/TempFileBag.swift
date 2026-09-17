import Foundation
import Synchronization

/// Temporary files the upload flow made and has to keep until it ends: a song
/// imported from Files, the sound copied out of another video.
///
/// ⚠️ **THE FILES DIE WITH THE BAG, AND THE BAG LIVES AS LONG AS THE SHEET.**
/// `PostDraft` holds it, and the draft lives exactly as long as the flow's
/// sheet — which publishing dismisses only once the post is out, so a song is
/// never deleted under the export that is reading it. A song replaced by
/// another stays until then too: the few megabytes are cheaper than knowing
/// whether anything still reads the old one.
///
/// ⚠️ **`Sendable`, BECAUSE THE COPY IS MADE WHERE THE PICKER CALLS BACK.**
/// `NSItemProvider` deletes the file it hands over as soon as its callback
/// returns, on a queue of its own, so the copy has to happen there — and the
/// bag is what it is copied into.
///
/// ⚠️ **NOTHING HERE IS A DRAFT STORE.** A media draft that outlived the sheet
/// would have to copy these into Application Support; the temporary directory
/// is right only for a session.
final class TempFileBag: Sendable {
    /// Where the copies go.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UploadSoundtracks", isDirectory: true)
    }

    private let kept = Mutex<[URL]>([])

    init() {}

    /// Copies `source` into the bag under a name of its own, and keeps the copy.
    /// Nil when it cannot be copied.
    ///
    /// ⚠️ **THE EXTENSION TRAVELS WITH IT** — `AVURLAsset` reads a file's type
    /// from it — and `fallbackExtension` stands in when the source has none.
    func keepCopy(of source: URL, fallbackExtension: String) -> URL? {
        let manager = FileManager.default
        let suffix = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
        let copy = Self.folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        do {
            try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: copy)
        } catch {
            return nil
        }
        kept.withLock { $0.append(copy) }
        return copy
    }

    /// The files the bag is holding.
    var files: [URL] { kept.withLock { $0 } }

    deinit {
        for file in kept.withLock({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
