import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

/// Resolves a post's media URL to a locally-playable URL for `AVPlayerItem`.
/// The player subsystem owns pooling and playback; sources only produce a URL
/// an `AVPlayer` can open — a passthrough remote URL in production, or a
/// synthesized file in mock mode. Mirrors `ImageFetching` for video.
/// Where video sources keep the clips they download or synthesise: files in
/// the app's temporary directory whose names start with one of these
/// prefixes. Settings → App Preferences measures and clears exactly these
/// (#409) and never touches the rest of the directory (Upload keeps captures
/// in flight there).
public enum VideoSourceCache {
    public static let filePrefixes = ["fixture-", "synthvid-"]

    public static func files(in directory: URL = FileManager.default.temporaryDirectory) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { name in filePrefixes.contains { name.hasPrefix($0) } }
            .map { directory.appendingPathComponent($0) }
    }
}

public protocol VideoSource: Sendable {
    func playableURL(for url: URL) async throws -> URL
}

/// Production source: the delivery URL is already playable (progressive MP4 or
/// an HLS manifest), so it passes straight through. This lights up for real
/// once the backend serves video renditions (Phase 3).
public struct PassthroughVideoSource: VideoSource {
    public init() {}
    public func playableURL(for url: URL) async throws -> URL { url }
}
