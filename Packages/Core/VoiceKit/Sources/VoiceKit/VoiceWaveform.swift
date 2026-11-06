import AVFoundation

/// A voice message's waveform: 100 levels of 5 bits (0–31), Telegram's shape
/// (#2101) — 63 bytes on the wire, whatever the take's length.
///
/// ONE FUNCTION FOR BOTH SOURCES. A take's levels come from the recorder's
/// metering while it records; a received message with none (an older
/// client, a failure) is read from its file. Both end in `levels(from:)`, so
/// the two draw the same message the same way.
///
/// ⚠️ THE LOUDEST SAMPLE PER BIN, IN DECIBELS, AGAINST THE TAKE'S LOUD PARTS.
/// A peak shows where the voice is; a mean flattens every syllable to the
/// same height. Each bin's peak is read in decibels — as the ear hears it —
/// over `dynamicRange` under the take's 95th-percentile bin: its loud words
/// reach the top, quieter syllables and breaths stand lower, and one cough
/// or a knock on the phone stays one tall bar, never the top everything else
/// is squashed under. A gentle curve (`curve`) spreads the upper half, where
/// speech lives.
///
/// Until 2026-11-06 the peaks were clipped at 1.8 × the take's MEAN — and a
/// mean that counts the pauses is low, so nearly every bin was clipped to it:
/// the owner's device check found the bars "almost always at the max".
public enum VoiceWaveform {
    /// How many levels a waveform carries.
    public static let levelCount = 100
    /// The loudest level: 5 bits.
    public static let maxLevel: UInt8 = 31
    /// Metering below this is silence.
    public static let silenceFloor: Float = -60
    /// A bin quieter than this (dBFS) is drawn flat: a pause.
    public static let pauseFloor: Float = -50
    /// The decibels drawn, from the bottom of a bar to its top.
    public static let dynamicRange: Float = 24
    /// The share of the take's bins at or under the loudness that reaches the
    /// top: its loud parts, not its single loudest instant.
    public static let topPercentile: Float = 0.95
    /// The curve over the range: above 1, the upper half spreads out.
    public static let curve: Float = 1.6

    /// A meter reading in dBFS (−160…0) as an amplitude, 0…1.
    public static func amplitude(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > silenceFloor else { return 0 }
        return min(1, pow(10, decibels / 20))
    }

    /// `samples` (amplitudes, 0…1, in time order) as `count` levels: the
    /// loudest sample of each bin, in decibels, drawn over `dynamicRange`
    /// under the take's `topPercentile` bin (see the type doc). A pause is
    /// 0; any sound at all is at least 1. A take shorter than `count` samples
    /// repeats each across the bins it spans. Silence, or no samples, is all
    /// zeros.
    public static func levels(from samples: [Float], count: Int = levelCount) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: count) }
        let n = samples.count
        let decibels: [Float] = (0..<count).map { bin in
            let start = bin * n / count
            let end = max(start + 1, (bin + 1) * n / count)
            let peak = samples[start..<min(end, n)].max() ?? 0
            return peak > 0 ? 20 * log10(peak) : -.infinity
        }
        let voiced = decibels.filter { $0 > pauseFloor }.sorted()
        guard !voiced.isEmpty else { return Array(repeating: 0, count: count) }
        let top = voiced[Int(Float(voiced.count - 1) * topPercentile)]
        let bottom = top - dynamicRange
        return decibels.map { level in
            guard level > pauseFloor else { return 0 }
            let share = min(1, max(0, (level - bottom) / dynamicRange))
            return UInt8(min(Float(maxLevel), max(1, (pow(share, curve) * Float(maxLevel)).rounded())))
        }
    }

    /// How much sound each sample read from a file covers.
    static let fileSampleSeconds: Double = 0.01

    /// The waveform of the audio file at `url`: its loudest sample per
    /// `fileSampleSeconds`, through `levels(from:)`.
    ///
    /// ⚠️ SYNCHRONOUS AND BLOCKING: it decodes the whole file. Call it off
    /// the main thread (a voice message is minutes at most).
    public nonisolated static func levels(ofFileAt url: URL, count: Int = levelCount) throws -> [UInt8] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(max(1, format.sampleRate * fileSampleSeconds))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / Double(frames)) + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var peak: Float = 0
            for channel in 0..<Int(format.channelCount) {
                let data = channels[channel]
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[frame])) }
            }
            samples.append(min(1, peak))
        }
        return levels(from: samples, count: count)
    }
}
