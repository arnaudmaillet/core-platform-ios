import CoreContracts
import CoreNetworkingMocks
import Foundation
import Testing

/// The mock's voice messages (#2103): bundled, referenced as the client
/// writes them, and previewed as the backend will (backend#993).
struct MockVoiceCatalogTests {
    @Test func everySeedIsBundledWithAHundredLevels() throws {
        for voice in MockVoiceCatalog.voices {
            let url = try #require(MockVoiceCatalog.shared.fileURL(voiceID: voice.id), "\(voice.id) is not bundled")
            #expect(url.pathExtension == "m4a")
            #expect(voice.waveform.count == 100)
            #expect(voice.waveform.allSatisfy { "0123456789abcdefghijklmnopqrstuv".contains($0) })
            let reference = try #require(MockVoiceCatalog.shared.reference(voiceID: voice.id))
            #expect(reference.hasPrefix("cpmedia://v1?kind=voice&url="))
            #expect(reference.contains("&wf=\(voice.waveform)"))
        }
        // A received short one, a long one, a pair, the viewer's.
        #expect(MockVoiceCatalog.voices.map(\.duration).contains { $0 > 30 }, "no long voice message to scrub")
    }

    @Test func aVoiceMessageIsPreviewedWithItsLength() throws {
        let reference = try #require(MockVoiceCatalog.shared.reference(voiceID: "voice-long"))
        #expect(MockVoiceCatalog.preview(forReference: reference) == "🎤 Voice message (0:34)")
        #expect(MockVoiceCatalog.preview(forReference: "cpmedia://v1?kind=image&url=x") == nil)
        #expect(MockVoiceCatalog.preview(forReference: "cpmedia://v1?kind=voice&url=x") == "🎤 Voice message")
    }
}
