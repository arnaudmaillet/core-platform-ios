import Foundation

/// The voice messages the mock's conversations are seeded with (#2103), so
/// the thread's voice bubble (#2104) has something to play with no recording.
///
/// Spoken by macOS `say` and encoded as #2101 records (AAC-LC in `.m4a`,
/// mono, 24 kHz, 32 kbps): license-free, about 215 KB in all. Each one's
/// length and waveform were read from its file with `VoiceWaveform`'s
/// rule (each bin's peak in decibels against the take's loud parts, 0–31,
/// read again 2026-11-06) and are written here as the sender's client would
/// send them.
public struct MockVoiceCatalog: Sendable {
    public struct Voice: Sendable, Equatable {
        public let id: String
        public let duration: Double
        /// 100 levels, one base-32 digit each (`ChatMediaRef`'s `wf`).
        public let waveform: String
    }

    public static let shared = MockVoiceCatalog(bundle: .module)

    public static let voices = [
        Voice(id: "voice-short", duration: 2.9,
              waveform: "11rssrrqnie31000000uvvvpooqqqnopmrvvsrmni4djrnmrupoqoi4111000000016kvvttspoqppm91fsssstqmf1011000000"),
        Voice(id: "voice-long", duration: 34.0,
              waveform: "qpsnmrpuovor3tvpesopqo9rspoprinnspulssrovutuvtm4qptsqoqqnqo7qnpqm4stqruns1odqrkoevtrsopcqppvuorqsts1"),
        Voice(id: "voice-pair1", duration: 3.3,
              waveform: "vvvp175mssstrmhc1000000115ssuoia11114vvuvvsme111000001std8bbsvurtnnnrrprn6abttq1oqruvvstqojd91000000"),
        Voice(id: "voice-pair2", duration: 2.6,
              waveform: "lstoodfebkuqsm17rsqpg41117vvvvvvvpng10100000001stvuunf111lqm7ntupo8admsttp18ditsp618sstoj41110000000"),
        Voice(id: "voice-mine", duration: 1.8,
              waveform: "157b99buvvusrrqnon8664117qqtrsmooi811110000000000139ab8hrrqssronprrutsqpb3euutuvvvtqnlfc210000000000"),
    ]

    private let directory: URL?

    init(bundle: Bundle) {
        directory = bundle.url(forResource: "MockVoices", withExtension: nil)
    }

    public func voice(id: String) -> Voice? {
        Self.voices.first { $0.id == id }
    }

    /// The bundled file of the voice named `id`.
    public func fileURL(voiceID id: String) -> URL? {
        guard let url = directory?.appendingPathComponent("\(id).m4a"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The voice as the client's `ChatMediaRef` writes one:
    /// `cpmedia://v1?kind=voice&url=…&d=…&wf=…&a=…` (#2103).
    public func reference(voiceID id: String) -> String? {
        guard let voice = voice(id: id), let url = fileURL(voiceID: id) else { return nil }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return "cpmedia://v1?kind=voice&url=\(encoded)&d=\(String(format: "%.1f", voice.duration))"
            + "&wf=\(voice.waveform)&a=\(voice.id)"
    }

    /// What the backend's preview says for a voice message (backend#993):
    /// "🎤 Voice message (0:12)" — nil for any other reference.
    public static func preview(forReference reference: String) -> String? {
        guard let components = URLComponents(string: reference), components.scheme == "cpmedia",
              components.queryItems?.first(where: { $0.name == "kind" })?.value == "voice" else { return nil }
        guard let seconds = components.queryItems?.first(where: { $0.name == "d" })?.value.flatMap(Double.init) else {
            return "🎤 Voice message"
        }
        let whole = max(0, Int(seconds.rounded()))
        return "🎤 Voice message (\(whole / 60):\(String(format: "%02d", whole % 60)))"
    }
}
