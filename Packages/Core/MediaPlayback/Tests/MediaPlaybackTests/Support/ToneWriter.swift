import AVFoundation
import Foundation

/// Songs made on the spot, for the tests that listen.
///
/// ⚠️ **WRITTEN WITH `AVAudioFile`, NEVER DOWNLOADED.** Each file is a sine whose
/// frequency and level are a function of time, so a test can tell WHICH second
/// of a song is playing from the samples alone: the staircase climbs 300 Hz a
/// second, so its pitch is its clock.
enum ToneWriter {
    /// What the song does at a moment: its pitch in Hz and its level, 0...1.
    typealias Shape = @Sendable (_ seconds: Double) -> (frequency: Double, level: Double)

    static let rate: Double = 44_100

    /// A steady 1 kHz tone, loud.
    static func steady(seconds: Double = 6) throws -> URL {
        try tone(named: "steady-\(seconds)", seconds: seconds) { _ in (1_000, 0.6) }
    }

    /// 300 Hz for the first second, 600 for the second, 900 for the third…
    static func staircase(seconds: Double = 6) throws -> URL {
        try tone(named: "staircase-\(seconds)", seconds: seconds) { at in
            (300 * (at.rounded(.down) + 1), 0.6)
        }
    }

    /// The pitch the staircase plays at `songSeconds`.
    static func staircasePitch(at songSeconds: Double) -> Double {
        300 * (songSeconds.rounded(.down) + 1)
    }

    /// Writes `shape` for `seconds` as a mono file — uncompressed `.caf` unless
    /// `compressed`, which writes AAC in `.m4a`, the shape a song from Files has.
    static func tone(
        named name: String, seconds: Double, compressed: Bool = false, shape: Shape
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(name).\(compressed ? "m4a" : "caf")")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // ⚠️ A NAME OF ITS OWN: two suites run side by side and may both write it.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        let settings: [String: Any] = compressed
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ]
            : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        do {
            let file = try AVAudioFile(
                forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let total = Int(seconds * rate)
            let chunk = 4_410
            var phase = 0.0
            var written = 0
            while written < total {
                let count = min(chunk, total - written)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)
                ), let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
                for index in 0..<count {
                    let (frequency, level) = shape(Double(written + index) / rate)
                    // A phase that accumulates, so a change of pitch never clicks.
                    phase += 2 * .pi * frequency / rate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    channel[index] = Float(sin(phase) * level)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                written += count
            }
        }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }
}

/// What an asset sounds like, read back through a mix exactly as an export or
/// a player would hear it.
struct SoundProbe {
    let samples: [Int16]

    /// Every audio track of `asset`, mixed by `mix`, as 16-bit mono at 44.1 kHz.
    static func listen(to asset: AVAsset, mix: AVAudioMix?) async throws -> SoundProbe {
        try await listen(to: asset, tracks: try await asset.loadTracks(withMediaType: .audio), mix: mix)
    }

    /// `tracks` of `asset` alone, mixed by `mix` — one lane of a composition,
    /// say, heard without the other.
    ///
    /// ⚠️ **FROM THE ASSET'S START, SILENCE INCLUDED.** A composition track that
    /// begins with an empty stretch is read as silence there, so sample `n` is
    /// always `n / 44100` seconds into the asset.
    static func listen(to asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?) async throws -> SoundProbe {
        guard !tracks.isEmpty else { return SoundProbe(samples: []) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: ToneWriter.rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.audioMix = mix
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / 2
            var chunk = [Int16](repeating: 0, count: count)
            _ = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        // ⚠️ A READ THAT STOPPED EARLY IS AN ERROR, NOT A QUIET TAIL: the
        // samples run out, and every level measured past them reads zero.
        guard reader.status == .completed else {
            throw reader.error ?? CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "the sound stopped after \(samples.count) samples, status \(reader.status.rawValue)"
            ])
        }
        return SoundProbe(samples: samples)
    }

    private func window(at centre: Double, width: Double) -> ArraySlice<Int16> {
        let from = max(Int((centre - width / 2) * ToneWriter.rate), 0)
        let to = min(Int((centre + width / 2) * ToneWriter.rate), samples.count)
        return to > from ? samples[from..<to] : []
    }

    /// How loud the sound is around `centre`, as a root mean square.
    func rms(at centre: Double, width: Double = 0.05) -> Double {
        let slice = window(at: centre, width: width)
        guard !slice.isEmpty else { return 0 }
        let energy = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(slice.count)).squareRoot()
    }

    /// The pitch around `centre`, from how often the sound crosses zero — a
    /// pure tone crosses twice per cycle.
    func pitch(at centre: Double, width: Double = 0.2) -> Double {
        let slice = Array(window(at: centre, width: width))
        guard slice.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<slice.count where (slice[index - 1] < 0) != (slice[index] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(slice.count) / ToneWriter.rate)
    }
}
