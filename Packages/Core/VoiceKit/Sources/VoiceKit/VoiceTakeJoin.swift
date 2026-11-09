import AVFoundation

/// Two takes as one (the owner, 2026-11-08): a take listened back is closed
/// (an `.m4a` plays only once finished), so recording on from its end is a
/// second take, joined to the first when it is listened to again or sent.
///
/// - **The sound:** both files in one composition, end to end, written as
///   one `.m4a` beside them; the two parts are deleted once it is written.
/// - **The waveform:** each part's levels keep their share of the whole
///   (`VoiceWaveform.joined`), so a long first part and a short second one
///   read as such.
public enum VoiceTakeJoin {
    public enum Failure: Error { case noAudio, couldNotExport }

    /// `first` then `second`, as one draft in `directory`.
    public static func join(_ first: VoiceDraft, _ second: VoiceDraft, in directory: URL) async throws -> VoiceDraft {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noAudio
        }
        var cursor = CMTime.zero
        for part in [first, second] {
            let asset = AVURLAsset(url: part.fileURL)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.couldNotExport
        }
        try await export.export(to: url, as: .m4a)
        for part in [first, second] { try? FileManager.default.removeItem(at: part.fileURL) }
        return VoiceDraft(
            fileURL: url,
            duration: first.duration + second.duration,
            waveform: VoiceWaveform.joined(first.waveform, lasting: first.duration, second.waveform, lasting: second.duration)
        )
    }
}

public extension VoiceWaveform {
    /// Two waveforms as one of `levelCount` levels, each part over its share
    /// of the joined length: the level at a moment is the part's own there.
    static func joined(_ first: [UInt8], lasting firstDuration: TimeInterval,
                       _ second: [UInt8], lasting secondDuration: TimeInterval) -> [UInt8] {
        let total = firstDuration + secondDuration
        guard total > 0, !first.isEmpty || !second.isEmpty else { return Array(repeating: 0, count: levelCount) }
        guard !first.isEmpty, firstDuration > 0 else { return resampled(second) }
        guard !second.isEmpty, secondDuration > 0 else { return resampled(first) }
        return (0..<levelCount).map { index in
            let moment = (Double(index) + 0.5) / Double(levelCount) * total
            if moment < firstDuration {
                return first[min(first.count - 1, Int(moment / firstDuration * Double(first.count)))]
            }
            let into = moment - firstDuration
            return second[min(second.count - 1, Int(into / secondDuration * Double(second.count)))]
        }
    }

    private static func resampled(_ levels: [UInt8]) -> [UInt8] {
        (0..<levelCount).map { levels[min(levels.count - 1, $0 * levels.count / levelCount)] }
    }
}
