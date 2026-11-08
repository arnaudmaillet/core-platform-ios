import AVFoundation
import Testing
@testable import VoiceKit

/// Recording on after a listen back (the owner, 2026-11-08): two takes
/// joined into one file and one waveform.
struct VoiceTakeJoinTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "voice-join-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A real AAC `.m4a` of `seconds` of a tone, as the recorder writes.
    private func take(seconds: Double, levels: [UInt8]) throws -> VoiceDraft {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).m4a")
        let rate = 24_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = 0.3 * sin(Float(index) * 2 * .pi * 440 / Float(rate)) }
        try file.write(from: buffer)
        return VoiceDraft(fileURL: url, duration: seconds, waveform: levels)
    }

    @Test func twoTakesBecomeOneFileAsLongAsBoth() async throws {
        let first = try take(seconds: 1.5, levels: Array(repeating: 10, count: VoiceWaveform.levelCount))
        let second = try take(seconds: 1.0, levels: Array(repeating: 20, count: VoiceWaveform.levelCount))
        let joined = try await VoiceTakeJoin.join(first, second, in: directory)
        #expect(joined.duration == 2.5)
        let asset = AVURLAsset(url: joined.fileURL)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 2.5) < 0.15, "the joined file lasts \(seconds) s")
        #expect(!FileManager.default.fileExists(atPath: first.fileURL.path), "the first part was left behind")
        #expect(!FileManager.default.fileExists(atPath: second.fileURL.path), "the second part was left behind")
        #expect(joined.waveform.count == VoiceWaveform.levelCount)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Each part keeps its share: 3 s of quiet then 1 s of loud is three
    /// quarters quiet.
    @Test func eachPartKeepsItsShareOfTheWaveform() {
        let quiet = Array(repeating: UInt8(4), count: VoiceWaveform.levelCount)
        let loud = Array(repeating: UInt8(28), count: VoiceWaveform.levelCount)
        let joined = VoiceWaveform.joined(quiet, lasting: 3, loud, lasting: 1)
        #expect(joined.count == VoiceWaveform.levelCount)
        #expect(joined.filter { $0 == 4 }.count == 75)
        #expect(joined.filter { $0 == 28 }.count == 25)
        #expect(joined.first == 4 && joined.last == 28)
    }

    /// The first part's shape is kept, squeezed into its share.
    @Test func aPartsShapeIsKeptInItsShare() {
        let ramp = (0..<VoiceWaveform.levelCount).map { UInt8($0 * 31 / (VoiceWaveform.levelCount - 1)) }
        let joined = VoiceWaveform.joined(ramp, lasting: 1, ramp, lasting: 1)
        #expect(joined[0] < joined[49], "the first half does not rise")
        #expect(joined[50] < joined[99], "the second half does not rise")
        #expect(joined[49] > joined[50], "the second half does not start again from the bottom")
    }

    @Test func anEmptyPartLeavesTheOther() {
        let levels = Array(repeating: UInt8(9), count: VoiceWaveform.levelCount)
        #expect(VoiceWaveform.joined([], lasting: 0, levels, lasting: 2) == levels)
        #expect(VoiceWaveform.joined(levels, lasting: 2, [], lasting: 0) == levels)
    }
}
