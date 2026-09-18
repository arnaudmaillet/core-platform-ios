import CoreModels
import FeedInterface
import Foundation
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// The camera screen driven through its own code paths on the SIMULATED
/// source — photograph, hold, lock, undo, Next — up to the editor it hands
/// over to, and, through the builder, to a published post.
///
/// ⚠️ **SERIALIZED, AND NOT TIME-LIMITED** — `CaptureSourceTests` says why for
/// both: every test runs a live camera, a Metal renderer and a window on the
/// main actor.
@MainActor
@Suite(.serialized)
struct CaptureFlowTests {
    /// The simulated camera, with the calls the screen makes written down.
    @MainActor
    final class SpySource: CaptureSource {
        let inner = SimulatedCaptureSource(frameSize: CGSize(width: 180, height: 320))
        var answer: CaptureAuthorization = .authorized(microphone: false)
        private(set) var limits: [TimeInterval] = []
        private(set) var torches: [Bool] = []
        private(set) var photoFlashes: [CaptureFlashMode] = []
        private(set) var deliversFrames: [Bool] = []
        private(set) var starts = 0

        func authorize() async -> CaptureAuthorization { answer }
        func start() {
            starts += 1
            inner.start()
        }
        func stop() { inner.stop() }
        var feed: CaptureFrameFeed { inner.feed }
        /// A stand-in for the real camera's preview layer, when a test asks.
        var plain: UIView?
        var plainPreview: UIView? { plain }
        var onStateChange: (() -> Void)?
        var position: CapturePosition { inner.position }
        func flip() async {
            await inner.flip()
            onStateChange?()
        }
        var lenses: [CaptureLens] { inner.lenses }
        var zoomRange: ClosedRange<CGFloat> { inner.zoomRange }
        var zoom: CGFloat { inner.zoom }
        func setZoom(_ factor: CGFloat, smoothly: Bool) { inner.setZoom(factor, smoothly: smoothly) }
        func focus(at point: CGPoint) {}
        var hasFlash: Bool { true }
        func capturePhoto(flash: CaptureFlashMode, into folder: CaptureFolder) async throws -> CapturedPhoto {
            photoFlashes.append(flash)
            return try await inner.capturePhoto(flash: flash, into: folder)
        }
        /// Recordings that FAIL when stopped, having recorded `failingRecorded`
        /// seconds — a movie output stopped before its first sample.
        var failsRecordings = false
        var failingRecorded: TimeInterval = 0
        private var failing: CaptureClipPromise?
        func startRecording(to url: URL, torch: Bool, limit: TimeInterval) -> CaptureClipPromise {
            limits.append(limit)
            torches.append(torch)
            if failsRecordings {
                let promise = CaptureClipPromise()
                failing = promise
                return promise
            }
            return inner.startRecording(to: url, torch: torch, limit: limit)
        }
        func stopRecording() {
            if let failing {
                self.failing = nil
                failing.fulfil(.failure(CaptureSourceError.recordingFailed))
                return
            }
            inner.stopRecording()
        }
        var recordedDuration: TimeInterval { failsRecordings ? failingRecorded : inner.recordedDuration }
        func setDeliversFrames(_ on: Bool) { deliversFrames.append(on) }
    }

    /// The shortcut's face, counting how often it is asked for.
    @MainActor
    final class Face {
        var picture: UIImage?
        private(set) var asked = 0
        func provide() async -> UIImage? {
            asked += 1
            return picture
        }

        static var green: UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }
    }

    @MainActor
    final class Handed {
        /// The screen the last capture was handed to, kept alive as a
        /// publishing finalisation screen keeps itself.
        var holder: UIViewController?
        var items: [MediaLibraryItem] = []
        var edits: [String: MediaEdits] = [:]
        var editors = 0
        var pickers = 0
    }

    struct Screen {
        let camera: CaptureViewController
        let navigation: UINavigationController
        let window: UIWindow
        let source: SpySource
        let handed: Handed
        let folder: CaptureFolder
    }

    /// The screens earlier tests opened, closed before the next one opens.
    ///
    /// ⚠️ **A SHOWN WINDOW OUTLIVES ITS TEST.** Nothing hid them, so every
    /// test's camera went on drawing thirty frames a second into its renderer
    /// for the rest of the run — fifty cameras at once by the end of the
    /// suite, on one simulator. The suite is serialized, so when a test opens
    /// its screen the one before it is finished: its camera is stopped and its
    /// window hidden here.
    private static var opened: [Screen] = []

    private static func closeOpened() {
        for screen in opened {
            screen.source.stop()
            screen.window.isHidden = true
        }
        opened = []
    }

    private func open(
        answer: CaptureAuthorization = .authorized(microphone: false),
        face: Face? = nil,
        takeLimit: TimeInterval = CaptureTake.maximum,
        plainPreview: UIView? = nil,
        motion: Bool = false,
        size: CGSize = CGSize(width: 402, height: 874)
    ) async throws -> Screen {
        Self.closeOpened()
        let source = SpySource()
        source.answer = answer
        source.plain = plainPreview
        let handed = Handed()
        let folder = CaptureFolder()
        let captures = CapturedMediaLibrary()
        var libraryFace: (@MainActor () async -> UIImage?)?
        if let face {
            libraryFace = { await face.provide() }
        }
        let camera = CaptureViewController(
            source: source, folder: folder, captures: captures,
            libraryFace: libraryFace,
            takeLimit: takeLimit, reducesMotion: { !motion },
            makeLibraryPicker: {
                handed.pickers += 1
                return UIViewController()
            }
        ) { items, edits in
            handed.items = items
            handed.edits = edits
            handed.editors += 1
            // What the builder does: the screen a capture goes to holds its file.
            let screen = UIViewController()
            captures.hold(items, by: screen)
            handed.holder = screen
            return screen
        }
        let navigation = UploadNavigationController(rootViewController: camera)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        try await settle { camera.authorization != nil }
        try #require(camera.authorization != nil, "the screen never asked for the camera")
        if case .authorized = answer {
            try await settle { source.feed.latestFrame != nil }
        }
        let screen = Screen(camera: camera, navigation: navigation, window: window, source: source, handed: handed, folder: folder)
        Self.opened.append(screen)
        return screen
    }

    private func settle(for seconds: Double = 5, until condition: () -> Bool) async throws {
        let rounds = Int(seconds * 100)
        for _ in 0..<rounds {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Holds the shutter for `seconds` and waits for the clip to land.
    /// Returns how long the finger was ACTUALLY down, and what the source had
    /// recorded when it lifted — see
    /// `CaptureSourceTests.aClipLastsAsLongAsTheRecordingAndStopsAtItsLimit`.
    @discardableResult
    private func record(_ screen: Screen, seconds: Double) async throws -> (held: TimeInterval, atRelease: TimeInterval) {
        let before = screen.camera.take.clips.count
        let startedAt = CACurrentMediaTime()
        screen.camera.debugBeginHold()
        try await Task.sleep(for: .seconds(seconds))
        let atRelease = screen.source.recordedDuration
        screen.camera.debugEndHold()
        let held = CACurrentMediaTime() - startedAt
        try await settle { screen.camera.take.clips.count == before + 1 && !screen.camera.isRecording }
        try #require(screen.camera.take.clips.count == before + 1, "the clip never landed")
        return (held, atRelease)
    }

    // MARK: - Photograph

    /// A tap on an empty take photographs, and the editor opens on that
    /// photograph — a real file the capture library serves, upright.
    @Test func aTapPhotographsAndOpensTheEditorOnThePhoto() async throws {
        let screen = try await open()
        screen.camera.debugTapShutter()
        try await settle { screen.handed.editors == 1 }

        try #require(screen.handed.editors == 1, "no editor was opened")
        let item = try #require(screen.handed.items.first)
        #expect(screen.handed.items.count == 1)
        #expect(item.kind == .photo)
        #expect(item.id.hasPrefix("capture-"))
        let url = try #require(screen.camera.captures.url(for: item.id))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.path.hasPrefix(screen.folder.url.path), "the file lives in the draft's folder")
        let thumbnail = await screen.camera.captures.thumbnail(for: item.id, size: CGSize(width: 90, height: 160))
        let picture = try #require(thumbnail)
        #expect(abs(picture.size.width / picture.size.height - 9.0 / 16.0) < 0.02, "the photograph's own shape")
        #expect(screen.handed.edits.isEmpty, "9:16 and no look: nothing to hand over")
    }

    /// The look and the ratio chosen while shooting arrive as the editor's
    /// edits — the filter as its filter, the ratio as a centred crop — and the
    /// file itself is untouched.
    @Test func theLookAndTheRatioArriveAsTheEditorsOwnEdits() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        screen.camera.debugRatioRow.debugPick(.square)
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        screen.camera.debugFilterRow.debugTap(.noir)
        screen.camera.debugTapShutter()
        try await settle { screen.handed.editors == 1 }

        let item = try #require(screen.handed.items.first)
        let edits = try #require(screen.handed.edits[item.id])
        #expect(edits.filter == .noir)
        #expect(abs(edits.crop.rect.height - 0.5625) < 1e-6, "a square of 1080×1920: \(edits.crop.rect)")
        #expect(abs(edits.crop.rect.width - 1) < 1e-6)
        #expect(abs(edits.crop.rect.midY - 0.5) < 1e-6)
        #expect(edits.fit == .fit, "the square arrives shown whole, not cut again by the canvas")
        let url = try #require(screen.camera.captures.url(for: item.id))
        #expect(CapturedMediaLibrary.uprightImageSize(at: url) == SimulatedCaptureEngine.photoSize, "the file keeps the whole frame")
    }

    /// The flash chosen is the flash fired.
    @Test func theFlashChosenIsTheFlashFired() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.flash.rawValue)
        screen.camera.debugFlashRow.debugPick(.on)
        screen.camera.debugTapShutter()
        try await settle { screen.handed.editors == 1 }
        #expect(screen.source.photoFlashes == [.on])
    }

    // MARK: - Recording

    /// Hold, release: one clip on the take, a segment on the ring, undo and
    /// Next offered — and a tap now records instead of photographing.
    @Test func aHoldRecordsAClipAndOffersUndoAndNext() async throws {
        let screen = try await open()
        let (held, atRelease) = try await record(screen, seconds: 0.8)

        let clip = try #require(screen.camera.take.clips.first)
        #expect(abs(clip.duration - atRelease) < 0.25, "\(atRelease)s recorded at the release, the clip says \(clip.duration)s")
        #expect(clip.duration <= held + 0.1, "never longer than the hold: \(held)s")
        #expect(FileManager.default.fileExists(atPath: clip.url.path))
        #expect(screen.camera.shutter.debugSegmentCount == 1)
        #expect(screen.camera.debugUndoIsShowing)
        #expect(screen.camera.debugNextIsShowing)
        #expect(screen.source.limits == [CaptureTake.maximum], "the whole budget for the first clip")

        screen.camera.debugTapShutter()
        #expect(screen.camera.isRecording, "with clips in the take, a tap records")
        #expect(screen.camera.shutterLogic.phase == .locked)
        #expect(screen.handed.editors == 0, "and never photographs")
        try await Task.sleep(for: .milliseconds(600))
        screen.camera.debugTapShutter()
        try await settle { screen.camera.take.clips.count == 2 }
        #expect(screen.camera.take.clips.count == 2)
    }

    /// A hold let go at once, whose output then reports a failure because it
    /// never wrote a sample, is a slip: nothing is said.
    @Test func aFailedClipStoppedAtOnceIsASlipNotAnError() async throws {
        let screen = try await open()
        screen.source.failsRecordings = true
        screen.source.failingRecorded = 0
        screen.camera.debugBeginHold()
        screen.camera.debugEndHold()
        try await settle { !screen.camera.isRecording }
        try #require(!screen.camera.isRecording)
        #expect(screen.camera.debugLastToast == nil, "said: \(screen.camera.debugLastToast ?? "")")
        #expect(screen.camera.take.isEmpty)
    }

    /// The same failure after a real recording is an error, and says so.
    @Test func aFailedClipThatHadRecordedSaysSo() async throws {
        let screen = try await open()
        screen.source.failsRecordings = true
        screen.source.failingRecorded = 2
        screen.camera.debugBeginHold()
        screen.camera.debugEndHold()
        try await settle { !screen.camera.isRecording }
        try #require(!screen.camera.isRecording)
        #expect(screen.camera.debugLastToast == "The clip could not be recorded")
    }

    /// Each clip is handed exactly what the take has left — the source's hard
    /// stop is the three-minute budget, not a clock the screen watches.
    @Test func eachClipIsGivenWhatTheTakeHasLeft() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.6)
        let first = try #require(screen.camera.take.clips.first)
        #expect(screen.source.limits.count == 2)
        #expect(abs(screen.source.limits[1] - (CaptureTake.maximum - first.duration)) < 1e-9)
    }

    /// A take that runs out of budget stops by itself — the source's own hard
    /// stop, not a finger — says so, and refuses another clip.
    @Test func theBudgetStopsTheRecordingByItselfAndSaysSo() async throws {
        let screen = try await open(takeLimit: 1.2)
        screen.camera.debugBeginHold()
        try await settle { !screen.camera.isRecording }
        #expect(!screen.camera.isRecording, "stopped with the finger still down")
        let clip = try #require(screen.camera.take.clips.first)
        #expect(abs(clip.duration - 1.2) < 0.01, "a clip stopped by its limit is the limit long: \(clip.duration)")
        #expect(screen.camera.take.isFull)
        #expect(screen.camera.debugLastToast == "1-second limit reached")
        screen.camera.debugEndHold()

        screen.camera.debugBeginHold()
        #expect(!screen.camera.isRecording, "a full take records nothing more")
        screen.camera.debugEndHold()
        screen.camera.debugTapShutter()
        #expect(!screen.camera.isRecording)
        #expect(screen.camera.take.clips.count == 1)
    }

    /// The three minutes are spelled on the clock.
    @Test func theClockSpellsTheTakeAgainstItsBudget() {
        #expect(CaptureViewController.clock(65.9, of: CaptureTake.maximum) == "1:05 / 3:00")
        #expect(CaptureTake().limitReachedMessage == "3-minute limit reached")
    }

    /// Cancel with clips in the take asks before throwing them away.
    @Test func cancelWithClipsAsksFirst() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        screen.camera.debugTapCancel()
        let alert = try #require(screen.camera.presentedViewController as? UIAlertController)
        #expect(alert.actions.contains { $0.style == .destructive })
        #expect(screen.navigation.isModalInPresentation, "and the sheet does not swipe away")
    }

    /// Sliding onto the padlock locks: the lifted finger no longer stops the
    /// clip, and a tap does.
    @Test func slidingOntoTheLockKeepsRecordingAfterTheFingerLifts() async throws {
        let screen = try await open()
        screen.camera.debugBeginHold()
        #expect(screen.camera.isRecording)
        #expect(screen.camera.debugLockIsShowing)
        screen.camera.debugMoveHold(CGPoint(x: -CaptureShutterLogic.lockDistance - 4, y: 0))
        #expect(screen.camera.shutterLogic.phase == .locked)
        screen.camera.debugEndHold()
        try await Task.sleep(for: .milliseconds(500))
        #expect(screen.camera.isRecording, "still recording, hands-free")
        #expect(screen.camera.take.isEmpty)
        screen.camera.debugTapShutter()
        try await settle { screen.camera.take.clips.count == 1 }
        #expect(screen.camera.take.clips.count == 1)
        #expect(!screen.camera.isRecording)
    }

    /// The first tap on undo only points at the last clip; the second deletes
    /// it — file and all.
    @Test func undoArmsThenDeletesTheLastClipAndItsFile() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.6)
        let last = try #require(screen.camera.take.clips.last)

        screen.camera.debugTapUndo()
        #expect(screen.camera.take.clips.count == 2)
        #expect(screen.camera.shutter.debugArmedLast, "the segment it would take is highlighted")
        screen.camera.debugTapUndo()
        #expect(screen.camera.take.clips.count == 1)
        #expect(!FileManager.default.fileExists(atPath: last.url.path), "an undone clip's file goes at once")
        #expect(screen.camera.shutter.debugSegmentCount == 1)
        #expect(!screen.camera.shutter.debugArmedLast)
    }

    /// Next joins the clips into ONE video and the editor opens on it.
    @Test func nextStitchesTheTakeIntoOneVideoForTheEditor() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.7)
        let total = screen.camera.take.total

        screen.camera.debugTapNext()
        try await settle(for: 10) { screen.handed.editors == 1 }
        try #require(screen.handed.editors == 1, "no editor was opened")
        #expect(screen.handed.items.count == 1, "one video, not one page per clip")
        let item = try #require(screen.handed.items.first)
        guard case .video(let duration) = item.kind else {
            Issue.record("the take arrived as \(item.kind)")
            return
        }
        #expect(abs(duration - total) < 0.15, "\(duration) vs \(total)")
        let file = await screen.camera.captures.videoFile(for: item.id)
        let url = try #require(file)
        #expect(!screen.camera.take.clips.map(\.url).contains(url), "a new file, not one of the clips")
        #expect(url.path.hasPrefix(screen.folder.url.path))
    }

    // MARK: - The selector

    /// An icon opens its controls in the band; a second tap on it puts them
    /// away; another icon swaps them.
    @Test func anIconOpensItsBandAndASecondTapClosesIt() async throws {
        let screen = try await open()
        let selector = screen.camera.debugSelector
        selector.debugTap(CaptureOption.flash.rawValue)
        #expect(screen.camera.openOption == .flash)
        #expect(screen.camera.debugBand.content === screen.camera.debugFlashRow)

        selector.debugTap(CaptureOption.timer.rawValue)
        #expect(screen.camera.openOption == .timer)
        #expect(screen.camera.debugBand.content === screen.camera.debugTimerRow)

        selector.debugTap(CaptureOption.timer.rawValue)
        #expect(screen.camera.openOption == nil)
        #expect(screen.camera.debugBand.content == nil)
        #expect(selector.selection == nil, "the selector rests on nothing again")
    }

    /// The grid is a toggle: it opens no band.
    @Test func theGridTogglesAndOpensNothing() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.grid.rawValue)
        #expect(screen.camera.settings.showsGrid)
        #expect(screen.camera.debugGridIsShowing)
        #expect(screen.camera.debugBand.content == nil)
        #expect(screen.camera.debugSelector.selection == nil)
        screen.camera.debugSelector.debugTap(CaptureOption.grid.rawValue)
        #expect(!screen.camera.settings.showsGrid)
    }

    /// The ratio's window is the shape chosen.
    @Test func theRatioReshapesThePreviewsWindow() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        screen.camera.debugRatioRow.debugPick(.classic)
        screen.window.layoutIfNeeded()
        let window = screen.camera.debugWindow
        #expect(abs(window.width / window.height - 0.75) < 0.01, "\(window)")
        #expect(window.width == screen.camera.debugPreviewBounds.width)
    }

    /// A look is drawn live: the filter reaches the preview's renderer.
    @Test func aLookIsDrawnLive() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        screen.camera.debugFilterRow.debugTap(.mono)
        #expect(screen.camera.settings.filter == .mono)
        #expect(screen.camera.debugLiveView.debugLook == FrameLook(preset: .mono), "the renderer draws Mono")
        #expect(!screen.camera.debugLiveView.isHidden)
        try await settle { screen.camera.debugLiveView.debugFrameStats.drawn > 3 }
        #expect(screen.camera.debugLiveView.debugFrameStats.drawn > 3, "frames are being drawn")
    }

    /// ⚠️ With a plain preview to show (the real camera's preview layer), the
    /// drawn path costs nothing until it is needed: no look, no frames. A look
    /// turns it on; so does the filter row, whose cards are the live frame.
    @Test func theDrawnPreviewRunsOnlyWhenALookOrTheFilterRowNeedsIt() async throws {
        let screen = try await open(plainPreview: UIView())
        #expect(screen.camera.debugLiveView.isHidden, "the plain preview shows an unfiltered camera")
        #expect(screen.source.deliversFrames.last == false, "and no frame is produced for nobody")

        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        #expect(screen.source.deliversFrames.last == true, "the cards need the live frame")
        #expect(screen.camera.debugLiveView.isHidden, "but the picture itself is still plain")
        let drawnWhileHidden = screen.camera.debugLiveView.debugFrameStats.drawn
        screen.source.feed.forgetLatest()
        try await settle { screen.source.feed.latestFrame != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(screen.source.feed.latestFrame != nil, "the cards still get their frame")
        #expect(screen.camera.debugLiveView.debugFrameStats.drawn == drawnWhileHidden, "and the hidden view draws none of it")

        screen.camera.debugFilterRow.debugTap(.fade)
        #expect(!screen.camera.debugLiveView.isHidden, "a look is drawn")
        let before = screen.camera.debugLiveView.debugFrameStats.drawn
        try await settle { screen.camera.debugLiveView.debugFrameStats.drawn > before + 2 }
        #expect(screen.camera.debugLiveView.debugFrameStats.drawn > before + 2, "and drawn it is")

        screen.camera.debugFilterRow.debugTap(.original)
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        #expect(screen.camera.debugLiveView.isHidden)
        #expect(screen.source.deliversFrames.last == false, "back to the free path")
    }

    /// The filter row's cards are drawn from the live frame.
    @Test func theFilterCardsShowTheLiveFrame() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        try await settle { screen.camera.debugFilterRow.debugAllChipsHaveAPicture }
        #expect(screen.camera.debugFilterRow.debugAllChipsHaveAPicture)
    }

    /// A timer counts down before the shutter acts, and a tap calls it off.
    @Test func theTimerCountsDownFirstAndATapCallsItOff() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        screen.camera.debugTimerRow.debugPick(.three)
        screen.camera.debugTapShutter()
        try await Task.sleep(for: .milliseconds(700))
        // ⚠️ THE CALL TO THE CAMERA, NOT THE EDITOR: a photograph taken at once
        // could still be on its way to the editor after 700ms on a loaded
        // machine, and the check would pass for the wrong reason.
        #expect(screen.source.photoFlashes.isEmpty, "nothing is taken during the countdown")
        screen.camera.debugTapShutter()
        try await Task.sleep(for: .seconds(3))
        #expect(screen.source.photoFlashes.isEmpty, "a cancelled countdown takes nothing")
    }

    /// The countdown ends in the photograph it counted down to. A countdown
    /// can only run LONG on a loaded machine, so "not before 2.5s" is safe.
    @Test func theTimerTakesThePhotoWhenItsCountdownEnds() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        screen.camera.debugTimerRow.debugPick(.three)
        screen.camera.debugTapShutter()
        try await Task.sleep(for: .milliseconds(2500))
        #expect(screen.source.photoFlashes.isEmpty, "not before the countdown ends")
        try await settle(for: 10) { screen.handed.editors == 1 }
        #expect(screen.source.photoFlashes.count == 1)
        #expect(screen.handed.editors == 1)
    }

    /// A hold with a timer set records hands-free once the countdown ends —
    /// the finger that started it has long gone.
    @Test func aHoldWithATimerRecordsHandsFreeAfterTheCountdown() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        screen.camera.debugTimerRow.debugPick(.three)
        screen.camera.debugBeginHold()
        screen.camera.debugEndHold()
        #expect(!screen.camera.isRecording, "counting down, not recording")
        #expect(screen.camera.shutterLogic.phase == .locked, "and the release did not stop it")
        try await settle(for: 10) { screen.camera.isRecording }
        try #require(screen.camera.isRecording)
        try await Task.sleep(for: .milliseconds(500))
        screen.camera.debugTapShutter()
        try await settle { screen.camera.take.clips.count == 1 }
        #expect(screen.camera.take.clips.count == 1)
    }

    // MARK: - Zoom, flip, library

    /// A lens chip zooms to its stop, and the chip wears the zoom.
    @Test func aLensChipZoomsToItsStop() async throws {
        let screen = try await open()
        try await settle { screen.camera.debugLensChips.debugTitles.count == 4 }
        #expect(screen.camera.debugLensChips.debugTitles == ["0.5", "1×", "2", "3"])
        screen.camera.debugLensChips.debugTap(2)
        #expect(screen.source.zoom == 2)
        #expect(screen.camera.debugLensChips.debugTitles == ["0.5", "1", "2×", "3"])
    }

    /// Flip turns to the other camera — and not while a clip records.
    @Test func flipTurnsToTheOtherCameraButNeverMidClip() async throws {
        let screen = try await open()
        screen.camera.debugFlip()
        try await settle { screen.source.position == .front }
        #expect(screen.source.position == .front)
        screen.camera.debugBeginHold()
        screen.camera.debugFlip()
        try await Task.sleep(for: .milliseconds(200))
        #expect(screen.source.position == .front, "refused while recording")
        screen.camera.debugEndHold()
    }

    /// The shortcut opens the ordinary picker ON the camera's stack, with the
    /// chevron back to the camera instead of a Cancel that would close it.
    @Test func theLibraryShortcutPushesThePickerWithAWayBack() throws {
        let builder = UploadFeatureBuilder(composer: RecordingComposer(), textPostScreens: { NoTextPosts() })
        let navigation = try #require(builder.makeCameraViewController() as? UINavigationController)
        let camera = try #require(navigation.viewControllers.first as? CaptureViewController)
        camera.debugTapLibrary()
        let picker = try #require(navigation.viewControllers.last as? MediaPickerViewController)
        #expect(navigation.viewControllers.count == 2)
        #expect(picker.navigationItem.leftBarButtonItems?.isEmpty ?? true, "no Cancel over the back chevron")
    }

    /// ⚠️ The shortcut is always offered — with the newest picture as its face
    /// where there is one, a neutral glyph otherwise — and its face is asked
    /// for once, as one picture.
    @Test func theLibraryShortcutIsAlwaysOfferedWithOnePictureAsItsFace() async throws {
        let face = Face()
        face.picture = Face.green
        let shown = try await open(face: face)
        try await settle { shown.camera.hasLibraryThumbnail }
        #expect(shown.camera.debugLibraryIsShowing)
        #expect(shown.camera.hasLibraryThumbnail, "the newest picture")
        #expect(face.asked == 1, "asked for once")
        shown.camera.debugTapLibrary()
        #expect(shown.handed.pickers == 1)

        let faceless = Face()
        let neutral = try await open(face: faceless)
        try await Task.sleep(for: .milliseconds(300))
        #expect(neutral.camera.debugLibraryIsShowing, "offered all the same")
        #expect(!neutral.camera.hasLibraryThumbnail, "with its neutral face")
        neutral.camera.debugTapLibrary()
        #expect(neutral.handed.pickers == 1, "the picker it opens asks for access")
    }

    /// ⚠️ The face is ONE asset, the newest photo or video — never a walk of
    /// the whole library.
    @Test func theShortcutsFaceIsOneAssetNewestFirst() throws {
        let options = CaptureLibraryFace.newestFetchOptions
        #expect(options.fetchLimit == 1)
        let order = try #require(options.sortDescriptors?.first)
        #expect(order.key == "creationDate")
        #expect(!order.ascending, "newest first")
        #expect(options.predicate != nil, "photos and videos only")
    }

    /// A refused camera says so, with the way to Settings, and shoots nothing.
    @Test func aRefusedCameraShowsTheNoticeAndShootsNothing() async throws {
        let screen = try await open(answer: .denied)
        #expect(screen.camera.debugNoticeIsShowing)
        #expect(screen.camera.debugNotice?.debugOffersSettings == true, "the way to Settings")
        #expect(screen.source.starts == 0, "the session is never started")
        screen.camera.debugTapShutter()
        screen.camera.debugBeginHold()
        #expect(!screen.camera.isRecording)
        #expect(screen.source.photoFlashes.isEmpty, "no photograph was asked for")
        #expect(screen.source.limits.isEmpty, "no recording was asked for")
    }

    /// No camera at all is not a refusal: the notice says so, offers no
    /// Settings, and the session is never started.
    @Test func aDeviceWithNoCameraSaysSoAndOffersNoSettings() async throws {
        let screen = try await open(answer: .unavailable)
        let notice = try #require(screen.camera.debugNotice)
        #expect(notice.kind == .unavailable)
        #expect(notice.debugTitle == "No camera available")
        #expect(!notice.debugOffersSettings)
        #expect(screen.source.starts == 0)
        screen.camera.debugTapShutter()
        #expect(screen.source.photoFlashes.isEmpty)
    }

    /// ⚠️ While Next joins the take, undo is dead: a double tap there deleted
    /// a clip the stitcher was reading.
    @Test func undoDoesNothingWhileNextIsJoiningTheTake() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.6)
        let clips = screen.camera.take.clips
        screen.camera.debugTapNext()
        #expect(!screen.camera.debugUndoIsEnabled, "disabled for as long as the take is being joined")
        screen.camera.debugTapUndo()
        screen.camera.debugTapUndo()
        #expect(screen.camera.take.clips == clips, "nothing was armed or deleted")
        #expect(clips.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        try await settle(for: 10) { screen.handed.editors == 1 }
        #expect(screen.handed.editors == 1)
    }

    /// ⚠️ A tap or a hold while the last clip is still being finished is
    /// refused, the shutter looking busy — never a photograph in the middle of
    /// a video, never a padlock for a recording that does not start.
    @Test func theShutterRefusesWhileAClipIsBeingFinished() async throws {
        let screen = try await open()
        screen.camera.debugBeginHold()
        try await Task.sleep(for: .milliseconds(500))
        screen.camera.debugEndHold()
        #expect(screen.camera.isRecording, "the clip is still being finished")
        #expect(screen.camera.shutter.look == .busy)
        screen.camera.debugTapShutter()
        screen.camera.debugBeginHold()
        screen.camera.debugEndHold()
        try await settle { !screen.camera.isRecording }
        #expect(screen.source.photoFlashes.isEmpty, "no photograph was taken mid-take")
        #expect(screen.source.limits.count == 1, "and no second recording started")
        #expect(screen.camera.take.clips.count == 1)
        #expect(screen.camera.shutter.look == .idle)
    }

    /// Back from the editor, after another clip, Next joins the take again —
    /// and the file of the join it replaced is gone.
    @Test func aReplacedJoinLeavesNoFileBehind() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.6)
        screen.camera.debugTapNext()
        try await settle(for: 10) { screen.handed.editors == 1 }
        let firstItem = try #require(screen.handed.items.first)
        let firstFile = await screen.camera.captures.videoFile(for: firstItem.id)
        let first = try #require(firstFile)
        try await comeBack(to: screen)

        try await record(screen, seconds: 0.6)
        #expect(!FileManager.default.fileExists(atPath: first.path), "the old join went when the take changed")
        screen.camera.debugTapNext()
        try await settle(for: 10) { screen.handed.editors == 2 }
        let secondFile = await screen.camera.captures.videoFile(for: try #require(screen.handed.items.first).id)
        let second = try #require(secondFile)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(screen.camera.take.clips.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    /// A one-clip take is handed over as the clip itself — and that clip is
    /// kept when the take grows.
    @Test func aOneClipTakeKeepsItsClipWhenTheTakeGrows() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        let clip = try #require(screen.camera.take.clips.first)
        screen.camera.debugTapNext()
        try await settle(for: 10) { screen.handed.editors == 1 }
        let handed = await screen.camera.captures.videoFile(for: try #require(screen.handed.items.first).id)
        #expect(handed == clip.url)
        try await comeBack(to: screen)
        try await record(screen, seconds: 0.6)
        #expect(FileManager.default.fileExists(atPath: clip.url.path))
    }

    /// Pops back to the camera once the push has landed, and waits for frames.
    /// The screen the capture went to is let go — as a popped editor is —
    /// unless the test keeps it, as a publishing finalisation screen keeps
    /// itself.
    private func comeBack(to screen: Screen, keepingTheScreen: Bool = false) async throws {
        try await settle { screen.navigation.viewControllers.count == 2 && screen.navigation.transitionCoordinator == nil }
        screen.navigation.popViewController(animated: false)
        if !keepingTheScreen {
            weak var gone = screen.handed.holder
            screen.handed.holder = nil
            try await settle { gone == nil }
        }
        try #require(screen.navigation.topViewController === screen.camera)
        screen.source.feed.forgetLatest()
        try await settle { screen.source.feed.latestFrame != nil }
    }

    /// ⚠️ Once the take has a clip the shape is locked — dimmed, and a tap
    /// says how to free it — because every clip becomes one video in one
    /// shape. Undoing back to an empty take frees it.
    @Test func theShapeIsLockedOnceTheTakeHasAClip() async throws {
        let screen = try await open()
        #expect(!screen.camera.debugShapeIsDimmed)
        try await record(screen, seconds: 0.6)
        #expect(screen.camera.debugShapeIsDimmed)
        screen.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        #expect(screen.camera.openOption == nil, "its row does not open")
        #expect(screen.camera.debugLastToast == "Undo your clips to change the shape")
        #expect(screen.camera.debugSelector.selection == nil)

        screen.camera.debugTapUndo()
        screen.camera.debugTapUndo()
        #expect(screen.camera.take.isEmpty)
        #expect(!screen.camera.debugShapeIsDimmed)
        screen.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        #expect(screen.camera.openOption == .ratio)
    }

    /// The look stays free mid-take, and says once that it is the whole
    /// video's.
    @Test func aLookChangedMidTakeSaysOnceThatItIsTheWholeVideos() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        screen.camera.debugFilterRow.debugTap(.chrome)
        #expect(!screen.camera.debugToasts.contains("The look applies to the whole video"), "nothing to say on an empty take")
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        try await record(screen, seconds: 0.6)
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        screen.camera.debugFilterRow.debugTap(.noir)
        screen.camera.debugFilterRow.debugTap(.mono)
        #expect(screen.camera.settings.filter == .mono)
        #expect(screen.camera.debugToasts.filter { $0 == "The look applies to the whole video" }.count == 1)
    }

    // MARK: - With motion

    /// ⚠️ With motion ON — every other flow test reduces it, which skips the
    /// band's animations — an option closed and opened again within its row's
    /// departure keeps its row in the band, whole.
    @Test func withMotionAnOptionReopenedMidDepartureKeepsItsRow() async throws {
        let screen = try await open(motion: true)
        let selector = screen.camera.debugSelector
        let row = screen.camera.debugFlashRow
        selector.debugTap(CaptureOption.flash.rawValue)
        try await Task.sleep(for: .milliseconds(50))
        selector.debugTap(CaptureOption.flash.rawValue)
        #expect(screen.camera.openOption == nil)
        selector.debugTap(CaptureOption.flash.rawValue)
        try await Task.sleep(for: .seconds(BandPop.departure + BandPop.settled(after: 3) + 0.2))
        #expect(screen.camera.openOption == .flash)
        #expect(screen.camera.debugBand.content === row)
        #expect(row.superview === screen.camera.debugBand, "the row is still in the band")
        #expect(row.alpha == 1)
    }

    /// With motion on, flash → timer → flash in quick succession ends on the
    /// flash row, in the band.
    @Test func withMotionQuickSwitchesEndOnTheLastRow() async throws {
        let screen = try await open(motion: true)
        let selector = screen.camera.debugSelector
        selector.debugTap(CaptureOption.flash.rawValue)
        selector.debugTap(CaptureOption.timer.rawValue)
        selector.debugTap(CaptureOption.flash.rawValue)
        try await Task.sleep(for: .seconds(BandPop.departure + BandPop.settled(after: 3) + 0.2))
        #expect(screen.camera.debugBand.content === screen.camera.debugFlashRow)
        #expect(screen.camera.debugFlashRow.superview === screen.camera.debugBand)
        #expect(screen.camera.debugTimerRow.superview == nil, "the timer's row has left")
    }

    /// With motion on, a row's pills arrive one after another and all land
    /// whole; undo and Next arrive once a clip lands.
    @Test func withMotionRowsAndTakeControlsArriveWhole() async throws {
        let screen = try await open(motion: true)
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        #expect(screen.camera.debugPopIns == 1)
        try await Task.sleep(for: .seconds(BandPop.settled(after: 3) + 0.2))
        for pill in screen.camera.debugTimerRow.poppableElements {
            #expect(pill.alpha == 1)
            #expect(pill.transform == .identity)
        }
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        try await record(screen, seconds: 0.6)
        try await Task.sleep(for: .seconds(BandPop.duration + BandPop.staggerStep + 0.2))
        #expect(screen.camera.debugUndoIsShowing)
        #expect(screen.camera.debugNextIsShowing)
    }

    /// ⚠️ The library shortcut is not offered, and refuses, while a
    /// photograph is being written.
    @Test func theLibraryShortcutWaitsForAPhotographInFlight() async throws {
        let face = Face()
        face.picture = Face.green
        let screen = try await open(face: face)
        try await settle { screen.camera.debugLibraryIsShowing }
        screen.camera.debugTapShutter()
        #expect(!screen.camera.debugLibraryIsShowing, "put away while the photograph is written")
        screen.camera.debugTapLibrary()
        #expect(screen.handed.pickers == 0)
        try await settle(for: 10) { screen.handed.editors == 1 }
        #expect(screen.handed.editors == 1)
    }

    /// A photograph that lands after the author went elsewhere is not pushed
    /// over where they went — it is dropped, file and all.
    @Test func aPhotographLandingOffScreenIsDropped() async throws {
        let screen = try await open()
        screen.camera.debugTapShutter()
        screen.navigation.pushViewController(UIViewController(), animated: false)
        try await settle(for: 10) { !screen.camera.isBusy }
        try #require(!screen.camera.isBusy)
        #expect(screen.handed.editors == 0)
        #expect(!screen.folder.files.contains { $0.pathExtension == "jpg" }, "its file went too")
    }

    /// ⚠️ Under Reduce Motion the focus ring and the toast fade without
    /// scaling; with motion they spring from a scale.
    @Test func reduceMotionFadesTheFocusRingAndTheToastWithoutScaling() async throws {
        let still = try await open()
        still.camera.debugTapPreview(at: CGPoint(x: 100, y: 200))
        #expect(still.camera.debugFocusRingStart == .identity)
        try await record(still, seconds: 0.6)
        still.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        #expect(still.camera.debugToastStart == .identity)

        let moving = try await open(motion: true)
        moving.camera.debugTapPreview(at: CGPoint(x: 100, y: 200))
        #expect(moving.camera.debugFocusRingStart != .identity)
        try await record(moving, seconds: 0.6)
        moving.camera.debugSelector.debugTap(CaptureOption.ratio.rawValue)
        #expect(moving.camera.debugToastStart != .identity)
    }

    // MARK: - Accessibility

    /// ⚠️ The shutter says what a tap does NOW, and offers a video without a
    /// hold — which Switch Control, Voice Control and many VoiceOver users
    /// cannot make.
    @Test func theShutterSaysWhatATapWillDoAndOffersVideoWithoutAHold() async throws {
        let screen = try await open()
        let shutter = screen.camera.shutter
        #expect(shutter.accessibilityHint == "Takes a photo. Touch and hold to record a video.")
        let record = try #require(shutter.accessibilityCustomActions?.first { $0.name == "Record video" })
        #expect(record.actionHandler?(record) == true)
        #expect(screen.camera.isRecording, "a hands-free recording")
        #expect(screen.camera.shutterLogic.phase == .locked)
        #expect(screen.source.photoFlashes.isEmpty, "not a photograph")
        #expect(shutter.accessibilityHint == nil)
        try await Task.sleep(for: .milliseconds(600))
        let stop = try #require(shutter.accessibilityCustomActions?.first { $0.name == "Stop recording" })
        #expect(stop.actionHandler?(stop) == true)
        try await settle { screen.camera.take.clips.count == 1 && !screen.camera.isRecording }
        #expect(screen.camera.take.clips.count == 1)
        #expect(shutter.accessibilityHint == "Records the next clip hands-free.")
    }

    /// The selector speaks the state its icons draw, and the shape pills are
    /// spoken as shapes rather than as times of day.
    @Test func theOptionsSpeakTheirState() async throws {
        let screen = try await open()
        #expect(screen.camera.debugSelectorLabels == ["Flash, off", "Timer, off", "Aspect ratio", "Filters", "Grid, off"])
        screen.camera.debugSelector.debugTap(CaptureOption.grid.rawValue)
        screen.camera.debugSelector.debugTap(CaptureOption.flash.rawValue)
        screen.camera.debugFlashRow.debugPick(.on)
        screen.camera.debugSelector.debugTap(CaptureOption.timer.rawValue)
        screen.camera.debugTimerRow.debugPick(.ten)
        #expect(screen.camera.debugSelectorLabels == ["Flash, on", "Timer, 10 seconds", "Aspect ratio", "Filters", "Grid, on"])
        #expect(screen.camera.debugRatioRow.debugSpoken == ["Nine by sixteen", "Three by four", "Square"])
        #expect(screen.camera.debugTimerRow.debugSpoken == ["Off", "3 seconds", "10 seconds"])
    }

    /// ⚠️ On a sheet too short for a full-width 9:16 picture (an iPhone SE),
    /// the preview narrows and centres at 9:16 rather than widening past it —
    /// so nothing outside the 9:16 frame is shown unmasked.
    @Test func aShortSheetKeepsThePreviewAtNineBySixteen() async throws {
        let screen = try await open(size: CGSize(width: 375, height: 600))
        screen.window.layoutIfNeeded()
        let preview = screen.camera.debugPreviewFrame
        #expect(abs(preview.width / preview.height - 9.0 / 16.0) < 0.002, "\(preview)")
        #expect(abs(preview.height - 600) < 0.5, "as tall as the sheet allows")
        #expect(abs(preview.midX - 187.5) < 0.5, "centred")
        let window = screen.camera.debugWindow
        #expect(window.width <= preview.width + 0.5, "the 9:16 window is the whole preview: \(window)")
    }

    /// ⚠️ Opening the camera deletes capture folders no presentation owns —
    /// left by a process that died with its sheet up — and spares the ones
    /// that are live.
    @Test func openingTheCameraSweepsFoldersNobodyOwns() async throws {
        let orphan = CaptureFolder.parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("clip.mov"))
        let live = CaptureFolder()
        let kept = live.newFile("clip", pathExtension: "mov")
        try Data([2]).write(to: kept)

        let builder = UploadFeatureBuilder(composer: RecordingComposer(), textPostScreens: { NoTextPosts() })
        _ = builder.makeCameraViewController()
        try await settle(for: 5) { !FileManager.default.fileExists(atPath: orphan.path) }
        #expect(!FileManager.default.fileExists(atPath: orphan.path), "the orphan went")
        #expect(FileManager.default.fileExists(atPath: kept.path), "the live folder stayed")
    }

    /// ⚠️ A file handed to a screen that still reads it — "Post" publishing
    /// after the author stepped back — is not deleted by the camera; it goes
    /// once that screen has gone.
    @Test func aHandedTakeOutlivesTheCameraWhileItsScreenReadsIt() async throws {
        let screen = try await open()
        try await record(screen, seconds: 0.6)
        try await record(screen, seconds: 0.6)
        screen.camera.debugTapNext()
        try await settle(for: 10) { screen.handed.editors == 1 }
        let handedFile = await screen.camera.captures.videoFile(for: try #require(screen.handed.items.first).id)
        let joined = try #require(handedFile)
        try await comeBack(to: screen, keepingTheScreen: true)

        try await record(screen, seconds: 0.6)
        #expect(FileManager.default.fileExists(atPath: joined.path), "still read by the screen it went to")

        weak var gone = screen.handed.holder
        screen.handed.holder = nil
        try await settle { gone == nil }
        try #require(gone == nil)
        try await record(screen, seconds: 0.6)
        #expect(!FileManager.default.fileExists(atPath: joined.path), "and deleted once nobody reads it")
    }

    /// ⚠️ A photograph that lands while the sheet is being closed is not
    /// pushed into the closing sheet — it is dropped with its file.
    @Test func aPhotographLandingDuringCancelIsDropped() async throws {
        let screen = try await open()
        screen.camera.debugTapShutter()
        screen.camera.debugTapCancel()
        try await settle(for: 10) { !screen.camera.isBusy }
        try #require(!screen.camera.isBusy)
        #expect(screen.handed.editors == 0)
        #expect(!screen.folder.files.contains { $0.pathExtension == "jpg" }, "its file went too")
    }

    /// ⚠️ Back from another screen with the Filters band still open, the
    /// cards go on following the live frame.
    @Test func theFilterCardsStayLiveAfterComingBack() async throws {
        let screen = try await open()
        screen.camera.debugSelector.debugTap(CaptureOption.filters.rawValue)
        try await settle { screen.camera.debugCardRefreshes > 0 }
        screen.navigation.pushViewController(UIViewController(), animated: false)
        screen.navigation.popViewController(animated: false)
        try #require(screen.navigation.topViewController === screen.camera)
        #expect(screen.camera.openOption == .filters, "the band is still open")
        let before = screen.camera.debugCardRefreshes
        try await Task.sleep(for: .seconds(1.6))
        #expect(screen.camera.debugCardRefreshes >= before + 2, "the cards are redrawn from the live frame")
    }

    /// ⚠️ The options are a REAL bar item in the stack's toolbar, trailing,
    /// drawing no glass of their own — the editor's strip, not a lookalike —
    /// minted fresh under one identifier at every hand-over, and taken away
    /// (the toolbar staying up) while a clip records.
    @Test func theOptionsAreATrailingItemInTheStacksToolbar() async throws {
        let screen = try await open()
        try await settle { screen.camera.toolbarItems?.isEmpty == false }
        #expect(!screen.navigation.isToolbarHidden)
        let items = try #require(screen.camera.toolbarItems)
        #expect(items.count == 2)
        let item = try #require(items.last)
        #expect(item.customView === screen.camera.debugSelector)
        #expect(item.identifier == CaptureViewController.optionsItemID)
        #expect(screen.camera.debugSelector.suppressesBackdrop, "the toolbar supplies the glass")
        #expect(items.first?.customView == nil && items.first !== item, "a flexible space pushes it trailing")

        screen.camera.debugBeginHold()
        #expect(screen.camera.toolbarItems?.isEmpty == true, "away while recording")
        #expect(!screen.navigation.isToolbarHidden, "the toolbar itself stays, and the shutter with it")
        screen.camera.debugEndHold()
        try await settle { screen.camera.take.clips.count == 1 && !screen.camera.isRecording }
        let back = try #require(screen.camera.toolbarItems?.last)
        #expect(back.customView === screen.camera.debugSelector)
        #expect(back !== item, "a fresh item, never the old one re-handed")
        #expect(back.identifier == item.identifier)
    }

    // MARK: - End to end, through the builder

    private actor RecordingComposer: PostComposing {
        private(set) var media: [ComposeMedia] = []

        func publish(media: [ComposeMedia], caption: String, as author: AuthorSummary?) async throws -> FeedEntry {
            self.media = media
            let by = author ?? AuthorSummary(id: ProfileID("me"), handle: "me", displayName: "Me", avatarURL: nil)
            return FeedEntry(
                post: Post(id: PostID("new"), authorID: by.id, caption: caption, attachments: [], publishedAt: Date()),
                author: by
            )
        }
    }

    private final class NoTextPosts: TextPostScreenBuilding {
        func makeTextPostScreen(publisher: any TextPostPublishing) -> UIViewController { UIViewController() }
    }

    /// "+" → Camera: a full-height sheet with Cancel at the top left; a
    /// photograph goes to the editor, Next to the finalisation screen, and Post
    /// publishes the picture.
    @Test func theCameraSheetPublishesAPhotographThroughTheEditorAndFinalisation() async throws {
        let composer = RecordingComposer()
        let builder = UploadFeatureBuilder(composer: composer, textPostScreens: { NoTextPosts() })
        let navigation = try #require(builder.makeCameraViewController() as? UINavigationController)
        #expect(navigation.modalPresentationStyle == .pageSheet)
        #expect(navigation.sheetPresentationController?.detents.count == 1)
        #expect(navigation.sheetPresentationController?.selectedDetentIdentifier == .large)
        let camera = try #require(navigation.viewControllers.first as? CaptureViewController)
        #expect(camera.navigationItem.leftBarButtonItems?.first?.title == "Cancel")

        Self.closeOpened()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        // Hidden, the camera disappears and stops — see `opened`.
        defer { window.isHidden = true }
        try await settle { camera.authorization != nil }
        try await settle { camera.debugLiveView.debugFrameStats.drawn > 0 }
        camera.debugTapShutter()
        try await settle { navigation.topViewController is MediaEditorViewController }
        let editor = try #require(navigation.topViewController as? MediaEditorViewController)
        // ⚠️ THE EDITOR READS THE CAPTURES. Handed the device library instead it
        // draws nothing — and this test stayed GREEN through that break, because
        // the finalisation screen, which publishes, still read the captures.
        #expect(editor.library === camera.captures, "the editor asks the library that holds the photograph")
        let page = await editor.library.thumbnail(for: try #require(editor.items.first).id, size: CGSize(width: 90, height: 160))
        #expect(page != nil, "and gets it")
        editor.debugTapNext()
        try await settle { navigation.topViewController is NewPostViewController }
        let finalisation = try #require(navigation.topViewController as? NewPostViewController)
        finalisation.debugTapPost()
        var published: [ComposeMedia] = []
        for _ in 0..<1000 where published.isEmpty {
            published = await composer.media
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(published.count == 1)
        if case .image = published.first {} else { Issue.record("published \(published)") }
    }

    /// ⚠️ The builder has both screens a capture goes to — the editor and the
    /// finalisation screen — hold its file.
    @Test func theEditorAndTheFinalisationScreenHoldTheCapturesFile() async throws {
        let builder = UploadFeatureBuilder(composer: RecordingComposer(), textPostScreens: { NoTextPosts() })
        let navigation = try #require(builder.makeCameraViewController() as? UINavigationController)
        let camera = try #require(navigation.viewControllers.first as? CaptureViewController)
        Self.closeOpened()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        // Hidden, the camera disappears and stops — see `opened`.
        defer { window.isHidden = true }
        try await settle { camera.authorization != nil }
        try await settle { camera.debugLiveView.debugFrameStats.drawn > 0 }
        camera.debugTapShutter()
        try await settle { navigation.topViewController is MediaEditorViewController }
        let editor = try #require(navigation.topViewController as? MediaEditorViewController)
        let item = try #require(editor.items.first)
        let url = try #require(camera.captures.url(for: item.id))
        #expect(camera.captures.holderCount(of: url) == 1, "the editor holds it")
        editor.debugTapNext()
        try await settle { navigation.topViewController is NewPostViewController }
        #expect(camera.captures.holderCount(of: url) == 2, "and so does the finalisation screen")
    }
}
