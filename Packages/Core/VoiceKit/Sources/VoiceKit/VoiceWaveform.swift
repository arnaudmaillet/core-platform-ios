import AVFoundation

/// A voice message's waveform: 100 levels of 5 bits (0–31), Telegram's shape
/// (#2101) — 63 bytes on the wire, whatever the take's length.
///
/// ONE FUNCTION FOR BOTH SOURCES. A take's levels come from the recorder's
/// metering while it records; a received message with none (an older
/// client, a failure) is read from its file. Both end in `levels(from:)`, so
/// the two draw the same message the same way.
///
/// ⚠️ THE LOUDEST SAMPLE PER BIN, CLIPPED AT 1.8 × THE MEAN. A peak shows
/// where the voice is; a mean flattens every syllable to the same height. The
/// clip keeps one cough or a knock on the phone from becoming the only tall
/// bar, every word squashed under it.
public enum VoiceWaveform {
    /// How many levels a waveform carries.
    public static let levelCount = 100
    /// The loudest level: 5 bits.
    public static let maxLevel: UInt8 = 31
    /// A peak higher than this many times the take's mean is cut to it.
    public static let clipFactor: Float = 1.8
    /// Metering below this is silence.
    public static let silenceFloor: Float = -60

    /// A meter reading in dBFS (−160…0) as an amplitude, 0…1.
    public static func amplitude(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > silenceFloor else { return 0 }
        return min(1, pow(10, decibels / 20))
    }

    /// `samples` (amplitudes, 0…1, in time order) as `count` levels: the
    /// loudest sample of each bin, clipped at `clipFactor` × their mean,
    /// scaled so the loudest bin reaches `maxLevel`. A take shorter than
    /// `count` samples repeats each across the bins it spans. Silence, or no
    /// samples, is all zeros.
    public static func levels(from samples: [Float], count: Int = levelCount) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: count) }
        let n = samples.count
        var peaks = [Float](repeating: 0, count: count)
        for bin in 0..<count {
            let start = bin * n / count
            let end = max(start + 1, (bin + 1) * n / count)
            peaks[bin] = samples[start..<min(end, n)].max() ?? 0
        }
        let mean = samples.reduce(0, +) / Float(n)
        guard mean > 0 else { return Array(repeating: 0, count: count) }
        let ceiling = mean * clipFactor
        let clipped = peaks.map { min($0, ceiling) }
        guard let loudest = clipped.max(), loudest > 0 else { return Array(repeating: 0, count: count) }
        let scale = Float(maxLevel) / loudest
        return clipped.map { UInt8(min(Float(maxLevel), ($0 * scale).rounded())) }
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
