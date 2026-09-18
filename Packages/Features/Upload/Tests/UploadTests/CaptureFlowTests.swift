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

    /// A library that is ALREADY granted, counting whether anybody asked.
    final class Recents: MediaLibraryReading {
        var granted: MediaLibraryAccess = .granted
        private(set) var asked = 0
        var access: MediaLibraryAccess { granted }
        func requestAccess() async -> MediaLibraryAccess {
            asked += 1
            return granted
        }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [MediaLibraryAlbum(id: "recents", title: "Recents", count: 1)] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [MediaLibraryItem(id: "newest", kind: .photo)] }
        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? { nil }
    }

    @MainActor
    final class Handed {
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

    private func open(
        answer: CaptureAuthorization = .authorized(microphone: false),
        recents: Recents? = nil,
        takeLimit: TimeInterval = CaptureTake.maximum,
        plainPreview: UIView? = nil
    ) async throws -> Screen {
        let source = SpySource()
        source.answer = answer
        source.plain = plainPreview
        let handed = Handed()
        let folder = CaptureFolder()
        let camera = CaptureViewController(
            source: source, folder: folder, captures: CapturedMediaLibrary(), recents: recents,
            takeLimit: takeLimit, reducesMotion: { true },
            makeLibraryPicker: {
                handed.pickers += 1
                return UIViewController()
            }
        ) { items, edits in
            handed.items = items
            handed.edits = edits
            handed.editors += 1
            return UIViewController()
        }
        let navigation = UploadNavigationController(rootViewController: camera)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        try await settle { camera.authorization != nil }
        try #require(camera.authorization != nil, "the screen never asked for the camera")
        if case .authorized = answer {
            try await settle { source.feed.latestFrame != nil }
        }
        return Screen(camera: camera, navigation: navigation, window: window, source: source, handed: handed, folder: folder)
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
        #expect(clip.duration <= 1.25 && clip.duration >= 1.0, "\(clip.duration)")
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

        screen.camera.debugFilterRow.debugTap(.fade)
        #expect(!screen.camera.debugLiveView.isHidden, "a look is drawn")

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
        #expect(screen.handed.editors == 0, "nothing is taken during the countdown")
        screen.camera.debugTapShutter()
        try await Task.sleep(for: .seconds(3))
        #expect(screen.handed.editors == 0, "a cancelled countdown takes nothing")
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

    /// The shortcut shows the newest picture only where access is ALREADY
    /// granted, and never asks.
    @Test func theLibraryShortcutNeverAsksForAccess() async throws {
        let granted = Recents()
        let shown = try await open(recents: granted)
        try await settle { shown.camera.debugLibraryIsShowing }
        #expect(shown.camera.debugLibraryIsShowing)
        shown.camera.debugTapLibrary()
        #expect(shown.handed.pickers == 1)

        let unasked = Recents()
        unasked.granted = .undetermined
        let hidden = try await open(recents: unasked)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!hidden.camera.debugLibraryIsShowing)
        #expect(unasked.asked == 0, "the camera must not put the Photos prompt up")
        #expect(granted.asked == 0)
    }

    /// A refused camera says so, with the way to Settings, and shoots nothing.
    @Test func aRefusedCameraShowsTheNoticeAndShootsNothing() async throws {
        let screen = try await open(answer: .denied)
        #expect(screen.camera.debugNoticeIsShowing)
        #expect(screen.camera.debugNotice?.debugOffersSettings == true, "the way to Settings")
        #expect(screen.source.starts == 0, "the session is never started")
        screen.camera.debugTapShutter()
        screen.camera.debugBeginHold()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!screen.camera.isRecording)
        #expect(screen.handed.editors == 0)
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

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
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
}
