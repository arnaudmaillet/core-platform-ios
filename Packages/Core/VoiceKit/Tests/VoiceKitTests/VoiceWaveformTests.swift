import AVFoundation
import Foundation
import Testing
@testable import VoiceKit

/// The waveform (#2101): 100 levels, 0–31, each bin's peak in decibels
/// against the take's loud parts (2026-11-06), from metering and from a file.
struct VoiceWaveformTests {
    @Test func aHundredLevelsOfFiveBits() {
        let samples = (0..<1_000).map { Float(abs(sin(Double($0) / 30))) }
        let levels = VoiceWaveform.levels(from: samples)
        #expect(levels.count == 100)
        #expect(levels.allSatisfy { $0 <= 31 })
        #expect(levels.max() == 31, "the loudest bin does not reach 31")
    }

    /// Louder bins stand taller: three loudnesses, three heights in order.
    @Test func louderStandsTaller() {
        let samples = [Float](repeating: 0.05, count: 100) + [Float](repeating: 0.2, count: 100)
            + [Float](repeating: 0.8, count: 100)
        let levels = VoiceWaveform.levels(from: samples)
        #expect(levels[10] < levels[50] && levels[50] < levels[90], "\(levels[10]), \(levels[50]), \(levels[90])")
    }

    /// ⚠️ SPEECH IS NOT ALL AT THE TOP (the owner, 2026-11-06: "almost always
    /// at the max"). Loud words, quieter syllables and pauses, as a voice
    /// has them: several heights, and most bars under the top.
    @Test func speechIsNotAllAtTheTop() {
        var samples: [Float] = []
        for word in 0..<20 {
            samples += [Float](repeating: [0.6, 0.3, 0.15, 0.08][word % 4], count: 12)
            samples += [Float](repeating: 0.001, count: 3)
        }
        let levels = VoiceWaveform.levels(from: samples)
        let atTheTop = levels.filter { $0 >= 30 }.count
        #expect(atTheTop < 40, "\(atTheTop) bars of 100 at the top")
        #expect(Set(levels.filter { $0 > 0 }).count >= 4, "too few heights: \(Set(levels))")
        #expect(levels.contains(0), "the pauses are not flat")
    }

    /// One cough does not flatten the rest: the words keep their height.
    @Test func onePeakDoesNotFlattenTheRest() {
        var samples = [Float](repeating: 0.1, count: 100)
        samples[50] = 1
        let levels = VoiceWaveform.levels(from: samples)
        #expect(levels[50] == 31)
        #expect(levels[0] == 31, "the speech was flattened under one peak: \(levels[0])")
    }

    @Test func silenceAndNothingAreFlat() {
        #expect(VoiceWaveform.levels(from: []) == Array(repeating: 0, count: 100))
        #expect(VoiceWaveform.levels(from: Array(repeating: 0, count: 300)) == Array(repeating: 0, count: 100))
    }

    /// A take shorter than 100 samples still gives 100 levels.
    @Test func aShortTakeStretchesToAHundred() {
        let levels = VoiceWaveform.levels(from: [0.5, 1, 0.25])
        #expect(levels.count == 100)
        #expect(levels.first! > 0 && levels.last! > 0)
    }

    @Test func meteringIsReadAsAnAmplitude() {
        #expect(VoiceWaveform.amplitude(decibels: 0) == 1)
        #expect(abs(VoiceWaveform.amplitude(decibels: -20) - 0.1) < 0.0001)
        #expect(VoiceWaveform.amplitude(decibels: -160) == 0)
        #expect(VoiceWaveform.amplitude(decibels: .nan) == 0)
    }

    /// The same function reads a file: a loud second after a quiet one is
    /// drawn louder, on the right.
    @Test func aFileIsReadIntoTheSameLevels() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-wave-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(24_000)
            for amplitude in [Float(0.1), 0.8] {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let data = try #require(buffer.floatChannelData)[0]
                for frame in 0..<Int(frames) { data[frame] = amplitude * Float(sin(Double(frame) * 0.2)) }
                try file.write(from: buffer)
            }
        }
        let levels = try VoiceWaveform.levels(ofFileAt: url)
        #expect(levels.count == 100)
        let quiet = levels[0..<50].map(Int.init).reduce(0, +)
        let loud = levels[50..<100].map(Int.init).reduce(0, +)
        #expect(loud > quiet * 2, "quiet \(quiet), loud \(loud)")
        #expect(levels.max() == 31)
    }
}
