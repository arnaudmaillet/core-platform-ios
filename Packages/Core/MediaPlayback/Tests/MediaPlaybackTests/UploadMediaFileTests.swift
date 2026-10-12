import AVFoundation
import Foundation
import Testing
@testable import MediaPlayback

/// The upload flows' intermediate files (#898): `export-*.mp4` and
/// `picked-*.mov` used to stay in the temporary directory for good. Each is
/// now owned, deleted with its owner, and swept when a dead process left it.
/// Every test works in a folder of its own.
@Suite(.exclusiveMediaWork)
struct UploadMediaFileTests {
    private final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadMediaFileTests-\(UUID().uuidString)", isDirectory: true)

        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        deinit { try? FileManager.default.removeItem(at: url) }

        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        }
    }

    private let folder = Folder()

    private func sweep(_ folder: URL, legacy: URL?) async {
        await withCheckedContinuation { continuation in
            UploadMediaFile.sweepOrphans(in: folder, legacyFolder: legacy) { continuation.resume() }
        }
    }

    @Test func theFileGoesWithItsOwner() throws {
        var file: UploadMediaFile? = UploadMediaFile(prefix: "export", pathExtension: "mp4", folder: folder.url)
        let url = try #require(file?.url)
        #expect(url.lastPathComponent.hasPrefix("export-") && url.pathExtension == "mp4")
        try Data([1, 2, 3]).write(to: url)
        #expect(UploadMediaFile.liveNames.contains(url.lastPathComponent))

        file = nil
        UploadMediaFile.waitForDeletions()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!UploadMediaFile.liveNames.contains(url.lastPathComponent))
    }

    @Test func aSweepDeletesOrphansAndSparesWhatALiveOwnerHolds() async throws {
        let held = UploadMediaFile(prefix: "picked", pathExtension: "mov", folder: folder.url)
        try Data([1]).write(to: held.url)
        let orphan = folder.url.appendingPathComponent("export-\(UUID().uuidString).mp4")
        try Data([2]).write(to: orphan)

        await sweep(folder.url, legacy: nil)
        #expect(folder.names == [held.url.lastPathComponent])
        withExtendedLifetime(held) {}
    }

    /// Before #898 both files were written at the root of the temporary
    /// directory, where nothing owns them any more. The sweep takes those,
    /// and nothing else there (the video sources' clips, captures).
    @Test func aSweepTakesTheLegacyRootFilesAndNothingElse() async throws {
        let root = Folder()
        let names = [
            "export-\(UUID().uuidString).mp4", "picked-\(UUID().uuidString).mov",
            "synthvid-1234.mp4", "fixture-v2-99.mp4", "export-notes.txt"
        ]
        for name in names { try Data([0]).write(to: root.url.appendingPathComponent(name)) }

        await sweep(folder.url, legacy: root.url)
        #expect(root.names == ["export-notes.txt", "fixture-v2-99.mp4", "synthvid-1234.mp4"])
    }

    /// The export itself: written in the exporter's folder, kept while the
    /// value lives, deleted with its last copy. Nothing left behind.
    @Test func anExportIsDeletedWithItsLastCopy() async throws {
        let source = try await PlaceholderVideoFetcher(durationSeconds: 0.5)
            .playableURL(for: URL(string: "mock://video/upload-media-file?w=160&h=160")!)
        var exported: ExportedVideo? = try await VideoExporter(folder: folder.url).export(VideoExportPlan(sourceURL: source))
        let url = try #require(exported?.fileURL)
        #expect(url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))

        var copy = exported
        exported = nil
        #expect(FileManager.default.fileExists(atPath: url.path), "a copy still holds it")
        #expect(copy?.fileURL == url)
        copy = nil
        UploadMediaFile.waitForDeletions()
        #expect(folder.names.isEmpty, "the export outlived every copy: \(folder.names)")
    }
}
