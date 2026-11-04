import AVFoundation
import Foundation
import Testing
import UIKit
@testable import VoiceKit

/// The recorder's state machine (#2101), with a fake device, session and
/// clock: no microphone.
@MainActor
struct VoiceRecorderTests {
    let session = FakeSession()
    let device = FakeDevice()
    let ticker = ManualTicker()
    let center = NotificationCenter()
    let directory = FileManager.default.temporaryDirectory.appending(path: "voice-tests-\(UUID().uuidString)")

    func recorder(_ permission: VoicePermissionState = .granted, awake: ((Bool) -> Void)? = nil) -> (VoiceRecorder, FakePermission) {
        let permission = FakePermission(permission)
        let fake = device
        let recorder = VoiceRecorder(
            session: session, permission: permission, makeDevice: { fake }, ticker: ticker,
            notifications: center, directory: directory, keepAwake: awake ?? { _ in }
        )
        return (recorder, permission)
    }

    @Test func aTakeRecordsPausesResumesAndFinishesIntoOneDraft() async throws {
        var kept: [Bool] = []
        let (recorder, _) = recorder(awake: { kept.append($0) })
        #expect(await recorder.start() == .started)
        #expect(recorder.state == .recording)
        #expect(ticker.interval == VoiceRecorder.meterInterval, "not metered at 20 Hz")
        #expect(kept == [true], "the screen may sleep while recording")
        device.currentTime = 2
        ticker.fire(10)
        recorder.pause()
        #expect(recorder.state == .paused)
        #expect(recorder.level == 0)
        recorder.resume()
        #expect(recorder.state == .recording)
        #expect(device.records == 2, "resume opened a new file instead of continuing")
        device.currentTime = 4.5
        ticker.fire(10)

        let outcome = recorder.finish()
        guard case .draft(let draft) = outcome else { Issue.record("no draft: \(String(describing: outcome))"); return }
        #expect(draft.duration == 4.5)
        #expect(draft.fileURL == device.url)
        #expect(draft.waveform.count == VoiceWaveform.levelCount)
        #expect(FileManager.default.fileExists(atPath: draft.fileURL.path))
        #expect(recorder.state == .finished(draft))
        #expect(kept == [true, false], "the screen stayed awake")
        #expect(!ticker.isRunning)
    }

    @Test func underOneSecondIsTooShortAndItsFileGoes() async throws {
        let (recorder, _) = recorder()
        #expect(await recorder.start() == .started)
        device.currentTime = 0.9
        let url = try #require(device.url)
        #expect(recorder.finish() == .tooShort)
        #expect(!FileManager.default.fileExists(atPath: url.path), "a too-short take kept its file")
        #expect(recorder.state == .cancelled)
    }

    @Test func aCancelledTakeLeavesNoFile() async throws {
        let (recorder, _) = recorder()
        #expect(await recorder.start() == .started)
        device.currentTime = 5
        let url = try #require(device.url)
        recorder.cancel()
        #expect(recorder.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Ten seconds before 15 minutes the caller is told, once; at the limit
    /// the take stops into a draft — never sent on its own.
    @Test func theFifteenMinuteLimitWarnsThenFinishes() async throws {
        let (recorder, _) = recorder()
        var warnings = 0
        var autos: [VoiceRecorder.FinishOutcome] = []
        recorder.onTimeRunningOut = { warnings += 1 }
        recorder.onAutoFinish = { autos.append($0) }
        #expect(await recorder.start() == .started)
        device.currentTime = VoiceRecorder.maximumDuration - 11
        ticker.fire()
        #expect(warnings == 0)
        device.currentTime = VoiceRecorder.maximumDuration - 9
        ticker.fire(3)
        #expect(warnings == 1, "the countdown was told \(warnings) times")
        #expect(recorder.state == .recording)
        device.currentTime = VoiceRecorder.maximumDuration
        ticker.fire()
        guard case .finished(let draft) = recorder.state else { Issue.record("still \(recorder.state)"); return }
        #expect(autos == [.draft(draft)])
    }

    /// A call, Siri or an alarm, the app leaving, the microphone going: the
    /// take stops into a draft, never lost.
    @Test(arguments: [0, 1, 2])
    func anInterruptionLeavesADraft(_ kind: Int) async throws {
        let (recorder, _) = recorder()
        var autos: [VoiceRecorder.FinishOutcome] = []
        recorder.onAutoFinish = { autos.append($0) }
        #expect(await recorder.start() == .started)
        device.currentTime = 3
        switch kind {
        case 0:
            center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ])
        case 1:
            center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        default:
            session.isInputAvailable = false
            center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ])
        }
        guard case .finished(let draft) = recorder.state else { Issue.record("interruption \(kind) left \(recorder.state)"); return }
        #expect(draft.duration == 3)
        #expect(autos == [.draft(draft)])
    }

    /// The first attempt asks and records nothing; a refusal reads denied.
    @Test func thePermissionIsAskedOnTheFirstAttemptAndNothingRecords() async {
        let (recorder, permission) = recorder(.undetermined)
        #expect(await recorder.start() == .askedPermission(granted: true))
        #expect(permission.requests == 1)
        #expect(device.records == 0, "it recorded behind the alert")
        #expect(recorder.state == .idle)
        #expect(await recorder.start() == .started)

        let (refused, _) = self.recorder(.denied)
        #expect(await refused.start() == .denied)
    }

    /// Recording: play-and-record, the default mode, the speaker and
    /// Bluetooth; given back with the others told.
    @Test func theSessionIsTheRecordingRoleThenGivenBack() async {
        let (recorder, _) = recorder()
        let focus = NameLog()
        let observers = [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { focus.names.append($0.name) }
        }
        defer { observers.forEach(center.removeObserver) }
        #expect(await recorder.start() == .started)
        #expect(session.roles == [.recording])
        #expect(VoiceSessionRole.recording.category == .playAndRecord)
        #expect(VoiceSessionRole.recording.mode == .default)
        #expect(VoiceSessionRole.recording.options == [.defaultToSpeaker, .allowBluetoothHFP])
        device.currentTime = 2
        recorder.finish()
        #expect(session.activations.map(\.0) == [true, false])
        #expect(session.activations.last?.1 == .notifyOthersOnDeactivation)
        #expect(focus.names == [VoiceAudioFocus.didTake, VoiceAudioFocus.didRelease])
    }

    /// The live level follows the meter, 0…1.
    @Test func theLevelFollowsTheMeter() async {
        let (recorder, _) = recorder()
        var levels: [Float] = []
        recorder.onLevel = { levels.append($0) }
        _ = await recorder.start()
        device.power = (-6, -3)
        ticker.fire()
        #expect(abs(recorder.level - VoiceWaveform.amplitude(decibels: -6)) < 0.0001)
        #expect(recorder.level > 0.4 && recorder.level <= 1)
        device.power = (-120, -120)
        ticker.fire()
        #expect(recorder.level == 0)
        #expect(levels.count == 2)
    }
}
