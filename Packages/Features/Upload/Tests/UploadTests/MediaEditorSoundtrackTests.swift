import AVFoundation
import DesignSystem
import MediaPlayback
import Testing
import UIKit
@testable import Upload

/// **"ADD A SONG": THE PILL, THE TOOLS, AND WHAT THEY STORE.**
///
/// ⚠️ **THE PICKERS ARE STUBBED, THE SONGS ARE NOT.** A system picker cannot be
/// driven from a test, so `StubSourcing` hands over a file the way a pick would
/// — but the file is a real tone written here, and the editor checks it with
/// the same `VideoSoundtrack.vet` a real pick goes through. The player is a stub
/// too: what the screen asked of it is the subject, and
/// `MediaPreviewPlayerSoundTests` asks the real one what it does with that.
@MainActor
@Suite(.serialized)
struct MediaEditorSoundtrackTests {
    private enum Mode {
        static let filters = 3
        static let crop = 4
    }

    private struct Screen {
        let editor: MediaEditorViewController
        let navigation: UINavigationController
        let window: UIWindow
        let preview: StubPreview
        let sourcing: StubSourcing
    }

    @MainActor
    private final class Handed {
        let destination = UIViewController()
    }

    private final class StubLibrary: MediaLibraryReading {
        var access: MediaLibraryAccess { .granted }
        func requestAccess() async -> MediaLibraryAccess { .granted }
        func presentLimitedPicker(from host: UIViewController) {}
        func albums() async -> [MediaLibraryAlbum] { [] }
        func items(in album: MediaLibraryAlbum.ID) async -> [MediaLibraryItem] { [] }

        func thumbnail(for item: MediaLibraryItem.ID, size: CGSize) async -> UIImage? {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }

        /// Nothing opens it — the player is a stub — and the editor falls back to
        /// the declared nine seconds when it cannot read a length.
        func videoFile(for item: MediaLibraryItem.ID) async -> URL? {
            FileManager.default.temporaryDirectory.appendingPathComponent("\(item).mov")
        }
    }

    /// Records what the screen asked the player for.
    private final class StubPreview: MediaVideoPreviewing {
        private(set) var plans: [VideoExportPlan] = []
        private(set) var landings: [VideoLoadLanding] = []
        private(set) var mutes: [Bool] = []
        private(set) var mixLevels: [(music: Double, original: Double)] = []
        /// Where the stub's clip has got to — what a reload lands on.
        var playhead: Double?

        func load(
            _ plan: VideoExportPlan, in surface: VideoRenderView,
            landing: @escaping @MainActor () -> VideoLoadLanding?
        ) async {
            guard let landed = landing() else { return }
            landings.append(landed)
            plans.append(plan)
        }

        func setLoopRange(_ range: ClosedRange<Double>?, in surface: VideoRenderView) {}
        func showAsShot(_ file: URL, in surface: VideoRenderView, atSourceSeconds seconds: Double) {}
        func stop(_ surface: VideoRenderView) {}
        func setPaused(_ paused: Bool, in surface: VideoRenderView) {}
        func isPaused(in surface: VideoRenderView) -> Bool? { false }
        func advancingRate(in surface: VideoRenderView) -> Double { 0 }
        func isBound(_ surface: VideoRenderView) -> Bool { !plans.isEmpty }
        func playheadSeconds(in surface: VideoRenderView) -> Double? { playhead }
        func seek(toSeconds seconds: Double, in surface: VideoRenderView, toleranceSeconds: Double) {}
        func frames(
            of file: URL, atSourceSeconds seconds: [Double], height: CGFloat, spacing: Double
        ) async -> [Double: UIImage] { [:] }
        func setLiveLook(_ look: FrameLook, in surface: VideoRenderView) -> Bool { true }
        func setMuted(_ muted: Bool, in surface: VideoRenderView) { mutes.append(muted) }
        func setMixLevels(music: Double, original: Double, in surface: VideoRenderView) {
            mixLevels.append((music, original))
        }
    }

    /// Hands over whatever `answer` says, as a pick would.
    private final class StubSourcing: MediaSoundtrackSourcing {
        var answer: MediaSoundtrackPick = .cancelled
        private(set) var asked: [MediaSoundtrackOrigin] = []

        func pick(
            from origin: MediaSoundtrackOrigin,
            presenting present: @escaping @MainActor (UIViewController) -> Void
        ) async -> MediaSoundtrackPick {
            asked.append(origin)
            return answer
        }
    }

    private static func items(_ kinds: [Bool]) -> [MediaLibraryItem] {
        kinds.enumerated().map { index, isVideo in
            MediaLibraryItem(
                id: isVideo ? "video-\(index)" : "photo-\(index)",
                kind: isVideo ? .video(duration: 9) : .photo
            )
        }
    }

    private func open(_ items: [MediaLibraryItem]) -> Screen {
        let handed = Handed()
        let preview = StubPreview()
        let sourcing = StubSourcing()
        let editor = MediaEditorViewController(
            items: items, library: StubLibrary(), preview: preview, soundtracks: sourcing
        ) { _, _ in handed.destination }
        let navigation = UINavigationController(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        editor.beginAppearanceTransition(true, animated: false)
        editor.endAppearanceTransition()
        window.layoutIfNeeded()
        return Screen(editor: editor, navigation: navigation, window: window, preview: preview, sourcing: sourcing)
    }

    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The pill, as the toolbar carries it.
    private func pill(_ screen: Screen) throws -> SoundPillView {
        try #require(
            screen.editor.toolbarItems?.compactMap({ $0.customView as? SoundPillView }).first,
            "no sound pill in the toolbar"
        )
    }

    private func tapPill(_ screen: Screen) throws {
        try pill(screen).sendActions(for: .touchUpInside)
        screen.window.layoutIfNeeded()
    }

    /// A tone of `seconds`, written once.
    private static func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-tone-\(seconds).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            let file = try AVAudioFile(forWriting: partial, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let count = AVAudioFrameCount(seconds * 22_050)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(count) {
                channel[index] = Float(sin(2 * .pi * 440 * Double(index) / 22_050) * 0.5)
            }
            buffer.frameLength = count
            try file.write(from: buffer)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }

    /// A video page, playing, with its song tools open.
    private func openTools() async throws -> Screen {
        let screen = open(Self.items([true]))
        screen.editor.debugScrollToPage(0)
        try await settle(until: { !screen.preview.plans.isEmpty })
        try #require(!screen.preview.plans.isEmpty, "guard: the clip never played")
        try tapPill(screen)
        return screen
    }

    /// …and a twenty-second song laid under it through the Files path.
    private func withSong(title: String = "Tone") async throws -> (Screen, URL) {
        let screen = try await openTools()
        let song = try Self.tone(seconds: 20)
        screen.sourcing.answer = .picked(fileURL: song, title: title)
        screen.editor.soundtrackMode.debugTools.debugTapPick(.files)
        try await settle(until: { screen.editor.edits(for: "video-0").soundtrack != nil })
        try #require(screen.editor.edits(for: "video-0").soundtrack != nil, "guard: the song was not stored")
        try await settle(until: { !screen.editor.soundtrackMode.isPicking })
        return (screen, song)
    }

    // MARK: - The pill

    @Test func pillOpensToolsOnAVideo() async throws {
        let screen = try await openTools()

        #expect(screen.editor.debugBand.content === screen.editor.soundtrackMode.debugTools,
                "got \(String(describing: screen.editor.debugBand.content))")
        #expect(screen.editor.soundtrackMode.debugTools.debugMessage == MediaSoundtrackToolsView.emptyHint)
        #expect(!screen.editor.soundtrackMode.debugTools.debugCanRemove, "nothing to remove yet")

        try tapPill(screen)
        #expect(screen.editor.debugBand.content == nil, "a second tap does not put the tools away")
    }

    @Test func noticeOnAPhoto() async throws {
        let screen = open(Self.items([false, true]))
        try tapPill(screen)

        let notice = try #require(screen.editor.debugBand.content as? BandNoticeView)
        #expect(notice.debugText == MediaEditorSoundtrackMode.photoNotice)

        // Swiped on to the video, the open tools follow the page.
        screen.editor.debugScrollToPage(1)
        #expect(screen.editor.debugBand.content === screen.editor.soundtrackMode.debugTools,
                "the notice stayed on a video: \(String(describing: screen.editor.debugBand.content))")
        screen.editor.debugScrollToPage(0)
        #expect(screen.editor.debugBand.content is BandNoticeView, "the tools stayed on a photo")
    }

    /// ⚠️ **THE CROP SURFACE IS LEFT FIRST.** The pill stays tappable under it,
    /// and song tools in a band whose canvas is still locked for a crop would
    /// leave the author with a surface nothing can close.
    @Test func thePillLeavesCropFirst() throws {
        let screen = open(Self.items([false]))
        screen.editor.debugCategoryBar.select(Mode.crop)
        screen.window.layoutIfNeeded()
        try #require(screen.editor.debugIsCropping, "guard: crop did not open")

        try tapPill(screen)

        #expect(!screen.editor.debugIsCropping, "the crop surface is still up")
        #expect(screen.editor.debugBand.content is BandNoticeView)
        #expect(screen.editor.debugCanvasScrolls, "the canvas is still locked")
    }

    @Test func choosingACategoryPutsTheToolsAway() async throws {
        let screen = try await openTools()

        screen.editor.debugCategoryBar.select(Mode.filters)
        screen.window.layoutIfNeeded()

        #expect(screen.editor.debugBand.content !== screen.editor.soundtrackMode.debugTools)
        #expect(screen.editor.debugBand.content != nil, "guard: the category opened nothing")
    }

    // MARK: - Importing

    @Test func importStoresTheSoundtrack() async throws {
        let (screen, song) = try await withSong(title: "A song with a rather long name")
        let stored = try #require(screen.editor.edits(for: "video-0").soundtrack)

        #expect(screen.sourcing.asked == [.files])
        #expect(stored.fileURL == song)
        #expect(stored.title == "A song with a rather long name")
        #expect(stored.startSeconds == 0 && stored.musicVolume == 1 && stored.originalVolume == 1)
        // The item is rebuilt around it.
        try await settle(until: { screen.preview.plans.last?.soundtrack != nil })
        #expect(screen.preview.plans.last?.soundtrack == stored, "the preview was never handed the song")
        // The pill names it, shortened; the tools show it and can remove it.
        let word = try pill(screen).accessibilityLabel
        #expect(word == "Song: A song with a rat…", "the pill says \(String(describing: word))")
        let tools = screen.editor.soundtrackMode.debugTools
        #expect(tools.debugTitle == "A song with a rather long name")
        #expect(tools.debugMessage == nil, "the song's controls are not showing")
        #expect(tools.debugCanRemove && tools.debugCanPick)
        try await settle(until: { screen.editor.soundtrackMode.debugHasWaveform(for: song) })
        #expect(screen.editor.soundtrackMode.debugHasWaveform(for: song), "the waveform was never read")
    }

    /// A pick that is not a song is said so, and nothing is stored.
    @Test func aPickThatIsNotASongIsRefused() async throws {
        let screen = try await openTools()
        screen.sourcing.answer = .picked(fileURL: try Self.tone(seconds: 0.4), title: "Blip")
        let loads = screen.preview.plans.count

        screen.editor.soundtrackMode.debugTools.debugTapPick(.video)
        try await settle(until: { !screen.editor.soundtrackMode.isPicking })

        #expect(screen.sourcing.asked == [.video])
        #expect(screen.editor.edits(for: "video-0").soundtrack == nil)
        #expect(screen.editor.soundtrackMode.debugTools.debugMessage
                == MediaEditorSoundtrackMode.message(for: .tooShort))
        #expect(screen.preview.plans.count == loads, "a refused pick rebuilt the item")
        #expect(try pill(screen).accessibilityLabel == MediaEditorSoundtrackMode.addTitle)
    }

    /// Closing the picker changes nothing, and the tools are usable again.
    @Test func aCancelledPickChangesNothing() async throws {
        let screen = try await openTools()
        screen.sourcing.answer = .cancelled

        screen.editor.soundtrackMode.debugTools.debugTapPick(.files)
        try await settle(until: { !screen.editor.soundtrackMode.isPicking })

        #expect(screen.editor.edits(for: "video-0").soundtrack == nil)
        #expect(!screen.editor.debugHasEdits(for: "video-0"), "a cancel wrote an entry")
        #expect(screen.editor.soundtrackMode.debugTools.debugCanPick)
        #expect(screen.editor.soundtrackMode.debugTools.debugMessage == MediaSoundtrackToolsView.emptyHint)
    }

    // MARK: - The excerpt and the levels

    /// ⚠️ **STORED WHEN THE FINGER LIFTS, AND THE ITEM IS REBUILT AT THE SAME
    /// PLAYED SECOND.** A drag moves nothing that is stored and builds nothing;
    /// the release stores the start and the new item lands where the old one
    /// was playing.
    @Test func excerptStoresOnRelease() async throws {
        let (screen, _) = try await withSong()
        let excerpt = screen.editor.soundtrackMode.debugTools.debugExcerpt
        screen.window.layoutIfNeeded()
        let loads = screen.preview.plans.count
        screen.preview.playhead = 2.5

        excerpt.debugDrag(toSeconds: 4)
        #expect(screen.editor.edits(for: "video-0").soundtrack?.startSeconds == 0, "stored during the drag")
        #expect(screen.preview.plans.count == loads, "a drag rebuilt the item")

        excerpt.debugRelease()
        #expect(screen.editor.edits(for: "video-0").soundtrack?.startSeconds == 4)
        try await settle(until: { screen.preview.plans.count > loads })
        #expect(screen.preview.plans.last?.soundtrack?.startSeconds == 4, "the new start never reached the item")
        #expect(screen.preview.landings.last?.seconds == 2.5,
                "the new item landed at \(String(describing: screen.preview.landings.last?.seconds))")
    }

    /// The excerpt cannot run past the song: a 20s song under a 9s film starts
    /// at 11s at the latest.
    @Test func theExcerptStopsWhereTheSongWouldRunOut() async throws {
        let (screen, _) = try await withSong()
        let excerpt = screen.editor.soundtrackMode.debugTools.debugExcerpt
        screen.window.layoutIfNeeded()

        excerpt.debugDrag(toSeconds: 30)
        excerpt.debugRelease()

        #expect(screen.editor.edits(for: "video-0").soundtrack?.startSeconds == 11)
        let frame = excerpt.debugWindowFrame
        #expect(abs(frame.midX - excerpt.bounds.midX) < 1 && frame.width > 100,
                "the film's window is \(frame) in \(excerpt.bounds)")
    }

    /// ⚠️ **LEVELS ARE LIVE, STORED ON RELEASE, AND NEVER A NEW ITEM.**
    @Test func volumesAreLive() async throws {
        let (screen, _) = try await withSong()
        let tools = screen.editor.soundtrackMode.debugTools
        try await settle(until: { screen.preview.plans.last?.soundtrack != nil })
        let loads = screen.preview.plans.count

        tools.debugDragLevels(music: 0.3, original: 0.6)
        #expect(screen.preview.mixLevels.last.map { $0 == (0.3, 0.6) } == true,
                "the playing item was not told: \(screen.preview.mixLevels)")
        #expect(screen.editor.edits(for: "video-0").soundtrack?.musicVolume == 1, "stored during the drag")

        tools.debugLetGoOfLevels()
        let stored = try #require(screen.editor.edits(for: "video-0").soundtrack)
        #expect(stored.musicVolume == 0.3 && stored.originalVolume == 0.6)
        try await Task.sleep(for: .milliseconds(100))
        #expect(screen.preview.plans.count == loads, "a new level rebuilt the item")
    }

    /// The two changes come off one at a time, and the song stays: it was a
    /// change of its own, one step further back.
    @Test func steppingBackRestoresTheExcerptAndTheLevels() async throws {
        let (screen, song) = try await withSong()
        screen.window.layoutIfNeeded()
        // ⚠️ **THE SONG IS ITSELF A STEP, SO THE ARROW IS ALREADY LIVE.** What
        // this guards is that it arrived wearing nothing else: a whole excerpt
        // and both levels full.
        let arrived = try #require(screen.editor.edits(for: "video-0").soundtrack)
        #expect(arrived.startSeconds == 0 && arrived.musicVolume == 1 && arrived.originalVolume == 1)

        screen.editor.soundtrackMode.debugTools.debugDragLevels(music: 0.2, original: 0)
        screen.editor.soundtrackMode.debugTools.debugLetGoOfLevels()
        screen.editor.soundtrackMode.debugTools.debugExcerpt.debugDrag(toSeconds: 3)
        screen.editor.soundtrackMode.debugTools.debugExcerpt.debugRelease()
        #expect(screen.editor.debugUndoItem.isEnabled, "the back arrow is dead over a changed song")

        // ⚠️ **TWO CHANGES, TWO STEPS.** The levels and the excerpt are separate
        // settled changes, so walking back to the song as it arrived takes one
        // step for each — which is what the arrows promise.
        screen.editor.debugTapUndo()
        screen.editor.debugTapUndo()

        let stored = try #require(screen.editor.edits(for: "video-0").soundtrack)
        #expect(stored.fileURL == song)
        #expect(stored.startSeconds == 0 && stored.musicVolume == 1 && stored.originalVolume == 1)
        #expect(screen.editor.soundtrackMode.debugTools.debugLevels == (1, 1))
        #expect(screen.preview.mixLevels.last.map { $0 == (1, 1) } == true)
    }

    // MARK: - Removing

    @Test func removeMutesAgain() async throws {
        let (screen, _) = try await withSong()
        try await settle(until: { screen.preview.plans.last?.soundtrack != nil })
        let loads = screen.preview.plans.count

        screen.editor.soundtrackMode.debugTools.debugTapRemove()

        #expect(screen.preview.mutes.last == true, "the song ran on: \(screen.preview.mutes)")
        #expect(screen.editor.edits(for: "video-0").soundtrack == nil)
        #expect(!screen.editor.debugHasEdits(for: "video-0"), "an empty song left an entry behind")
        #expect(try pill(screen).accessibilityLabel == MediaEditorSoundtrackMode.addTitle)
        #expect(screen.editor.soundtrackMode.debugTools.debugMessage == MediaSoundtrackToolsView.emptyHint)
        try await settle(until: { screen.preview.plans.count > loads })
        #expect(screen.preview.plans.last.map { $0.soundtrack == nil } == true, "the item kept the song")
    }

    // MARK: - Files and symbols

    /// ⚠️ **THE SONG LIVES AS LONG AS WHOEVER STILL NEEDS IT, AND NO LONGER.**
    /// The draft holds the bag; the editor's source holds it too. The copy goes
    /// only when both are gone.
    @Test func tempFilesDieWithTheDraft() throws {
        let original = try Self.tone(seconds: 1.5)
        var draft: PostDraft? = PostDraft()
        var source: SystemSoundtrackSource? = SystemSoundtrackSource(files: try #require(draft).soundtrackFiles)
        let copy = try #require(draft?.soundtrackFiles.keepCopy(of: original, fallbackExtension: "m4a"))

        #expect(copy != original && copy.pathExtension == "caf")
        #expect(copy.deletingLastPathComponent().lastPathComponent == "UploadSoundtracks")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(source?.files.files == [copy])

        draft = nil
        #expect(FileManager.default.fileExists(atPath: copy.path), "the editor still needs it")
        source = nil
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the copy outlived the flow")
        #expect(FileManager.default.fileExists(atPath: original.path), "the bag deleted what it did not own")
    }

    @Test func everySymbolExists() {
        for symbol in MediaSoundtrackToolsView.symbols {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol) is not a symbol")
        }
    }
}

/// **THE ONE PLAYER THAT SHIPS: HEARD WITH A SONG, SILENT WITHOUT.**
@MainActor
@Suite(.serialized)
struct MediaPreviewPlayerSoundTests {
    private func clip() async throws -> URL {
        try await PlaceholderVideoFetcher(durationSeconds: 2)
            .playableURL(for: URL(string: "mock://video/sound?w=160&h=160")!)
    }

    private func tone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tone.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: partial, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let count = AVAudioFrameCount(3 * 22_050)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(count) { channel[index] = Float(sin(Double(index) * 0.12) * 0.5) }
            buffer.frameLength = count
            try file.write(from: buffer)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }

    private func plan(_ file: URL, song: VideoSoundtrack?) -> VideoExportPlan {
        VideoExportPlan(sourceURL: file, segments: [VideoExportSegment(start: 0, end: 2)], soundtrack: song)
    }

    /// ⚠️ **HEARD, UNDER `.playback`, THE MOMENT AN ITEM WITH A SONG IS IN — AND
    /// SILENT AGAIN WHEN ONE WITHOUT REPLACES IT.** A fresh bind starts muted, so
    /// without this the song would be laid and never heard.
    @Test func previewUnmutesWithASong() async throws {
        let player = MediaPreviewPlayer()
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let file = try await clip()
        let song = VideoSoundtrack(fileURL: try tone(), title: "Tone")

        await player.load(plan(file, song: song), in: surface) { VideoLoadLanding(seconds: 0) }
        #expect(player.debugIsMuted(in: surface) == false, "a clip with a song is silent")
        #expect(AVAudioSession.sharedInstance().category == .playback)
        let sound = try #require(player.debugSound(in: surface))
        #expect(try await sound.asset.loadTracks(withMediaType: .audio).isEmpty == false, "no song in the item")
        #expect(sound.mix != nil, "the song plays without its levels")

        await player.load(plan(file, song: nil), in: surface) { VideoLoadLanding(seconds: 0) }
        #expect(player.debugIsMuted(in: surface) == true, "a clip without a song is heard")
        #expect(AVAudioSession.sharedInstance().category == .ambient)

        await player.load(plan(file, song: song), in: surface) { VideoLoadLanding(seconds: 0) }
        #expect(player.debugIsMuted(in: surface) == false)
        player.stop(surface)
        #expect(AVAudioSession.sharedInstance().category == .ambient, "stopping left the session playing")
    }

    /// An abandoned load leaves the item that is playing — and its voice — alone.
    @Test func anAbandonedLoadKeepsTheVoiceOfWhatIsPlaying() async throws {
        let player = MediaPreviewPlayer()
        let surface = VideoRenderView()
        surface.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        defer { player.stop(surface) }
        let file = try await clip()
        let song = VideoSoundtrack(fileURL: try tone(), title: "Tone")

        await player.load(plan(file, song: song), in: surface) { VideoLoadLanding(seconds: 0) }
        await player.load(plan(file, song: nil), in: surface) { nil }

        #expect(player.debugIsMuted(in: surface) == false, "an abandoned load silenced the song")
    }
}
