import Foundation

/// The directory one camera presentation writes its captures into: the
/// photographs, the clips, and the video a take's clips are stitched into.
///
/// ⚠️ **OWNED BY `PostDraft`, SO IT DIES WITH THE SHEET — `TempFileBag`'S
/// RULE, FOR ITS REASON.** The editor reads these files, the finalisation
/// screen reads them again while "Post" is working, and the sheet is dismissed
/// only once the post is out. A folder deleted by the camera screen when it
/// disappeared would pull a clip out from under the export reading it.
///
/// ⚠️ **ONE DIRECTORY PER PRESENTATION, REMOVED WHOLE.** Every file of the
/// flow is under it, so nothing has to be remembered one by one to be cleaned
/// up; a file the camera throws away early (an undone clip, a slip too short to
/// keep) is removed at once all the same, because a three-minute take is
/// hundreds of megabytes on a phone.
///
/// ⚠️ **NOT THE PHOTO LIBRARY, BY DECISION.** Captures are not saved to Photos;
/// saving belongs to the finalisation screen, where it is being added apart from
/// this.
final class CaptureFolder: Sendable {
    /// Where every presentation's folder is made.
    static var parent: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UploadCaptures", isDirectory: true)
    }

    let url: URL

    init(parent: URL = CaptureFolder.parent) {
        url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A fresh file name in the folder, with `pathExtension`. The folder is made
    /// on first use, so a presentation that captures nothing leaves nothing.
    func newFile(_ prefix: String, pathExtension: String) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("\(prefix)-\(UUID().uuidString)").appendingPathExtension(pathExtension)
    }

    /// Removes one file the flow no longer needs.
    func discard(_ file: URL) {
        guard file.path.hasPrefix(url.path) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Internal for tests: what the folder holds right now.
    var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
