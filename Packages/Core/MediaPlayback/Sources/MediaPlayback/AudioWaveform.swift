import AVFoundation

/// The shape of a song's loudness, for drawing it.
///
/// ⚠️ **THE LOUDEST SAMPLE PER BUCKET, NOT THE AVERAGE.** A waveform is read
/// for its peaks — where the beat hits, where a verse goes quiet — and an
/// average of a sine is 0.64 of its height, so every bar would be drawn short
/// and a quiet passage with one loud hit would vanish into its neighbours.
///
/// ⚠️ **ONE PEAK PER 10 MS AT MOST, AS `Float`.** A four-minute song is 24,000
/// of them — 96 KB — which is finer than any screen draws and cheap enough to
/// keep for every song a session imports.
public enum AudioWaveform {
    /// How much song each peak covers, unless the caller asks for coarser.
    public static let bucketSeconds: Double = 0.01

    /// The rate the song is read at. Well past what a drawing can show, and a
    /// quarter of the work a 44.1 kHz read would be.
    static let readRate: Double = 11_025

    /// The loudest sample in every `bucketSeconds` of `url`'s sound, 0...1,
    /// read as 16-bit mono.
    ///
    /// ⚠️ **`nonisolated` AND ASYNC, AND IT BLOCKS WHILE IT READS.**
    /// `AVAssetReader` hands samples over synchronously; the loop yields every
    /// few buffers so a long song does not hold a cooperative thread, and
    /// checks for cancellation there — a picker closed mid-read stops paying.
    /// The reader never leaves this function: it is not `Sendable`.
    public nonisolated static func peaks(
        of url: URL, bucketSeconds: Double = bucketSeconds
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw SoundtrackProblem.noSound }
        let reader = try AVAssetReader(asset: asset)
        // ⚠️ THE MIX OUTPUT, NOT THE TRACK OUTPUT: it is the one documented to
        // fold any channel layout down to the one channel asked for.
        let output = AVAssetReaderAudioMixOutput(audioTracks: [tracks[0]], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: readRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SoundtrackProblem.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SoundtrackProblem.unreadable }

        let perBucket = max(1, Int((readRate * max(bucketSeconds, 1 / readRate)).rounded()))
        var peaks: [Float] = []
        var loudest: Int32 = 0
        var filled = 0
        var samples: [Int16] = []
        var buffers = 0
        while let buffer = output.copyNextSampleBuffer() {
            buffers += 1
            if buffers % 16 == 0 {
                await Task.yield()
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            // ⚠️ COPIED OUT, NOT READ IN PLACE: a block buffer need not be
            // contiguous, and a pointer to its first piece would read garbage
            // past it.
            samples = [Int16](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * MemoryLayout<Int16>.size,
                    destination: raw.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in samples {
                loudest = max(loudest, abs(Int32(sample)))
                filled += 1
                if filled == perBucket {
                    peaks.append(Float(loudest) / Float(Int16.max))
                    loudest = 0
                    filled = 0
                }
            }
        }
        if filled > 0 { peaks.append(Float(loudest) / Float(Int16.max)) }
        guard reader.status == .completed else { throw reader.error ?? SoundtrackProblem.unreadable }
        return peaks.map { min($0, 1) }
    }
}
