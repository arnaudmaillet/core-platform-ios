import Foundation

/// The voice messages the mock's conversations are seeded with (#2103), so
/// the thread's voice bubble (#2104) has something to play with no recording.
///
/// Spoken by macOS `say` and encoded as #2101 records (AAC-LC in `.m4a`,
/// mono, 24 kHz, 32 kbps): license-free, about 215 KB in all. Each one's
/// length and waveform were read from its file with `VoiceWaveform`'s
/// rule (the peak per bin, clipped at 1.8 × the mean, 0–31) and are written
/// here as the sender's client would send them.
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
              waveform: "03vvvvvtphd52000000vvvvrqqtusoqsnvvvvvnoh5djuonuvsqupi6110000000047kvvvvvrrtrro92evvvvvune2010000000"),
        Voice(id: "voice-long", duration: 34.0,
              waveform: "vvvuuvvvvvvv6vvvhvvvvvbvvvvvvnvvvvvsvvvvvvvvvvu6vvvvvvvvvvv9vvvvt7vvvvvvv3vgvvqvhvvvvvvfvvvvvvvvvvv2"),
        Voice(id: "voice-pair1", duration: 3.3,
              waveform: "vvvu287qvvvvvoid1000000026vvvsjb10146vvvvvvpe210000002vvd9bbvvvvvrrqvvuvr7abvvv3svvvvvvvvskea3000000"),
        Voice(id: "voice-pair2", duration: 2.6,
              waveform: "ovvstefecnvvvq28vvvvh61138vvvvvvvurh20100000003vvvvvrg223ovq8qvvus9aepvvvu49djvvu719vvvtl60110000000"),
        Voice(id: "voice-mine", duration: 1.8,
              waveform: "068ba9bvvvvvvvvrsq9776028vvvvvprri931100000000000159ab8ivvvvvvrqsvvvvvvtb5evvvvvvvvuqmgc410000000000"),
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
