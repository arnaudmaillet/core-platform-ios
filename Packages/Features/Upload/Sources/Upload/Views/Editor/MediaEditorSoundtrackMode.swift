import MediaPlayback
import UIKit

/// A song under a clip, opened from the sound pill.
///
/// ⚠️ **NOT A CATEGORY.** The pill opens and closes it (`toggle`) whatever the
/// category bar is resting on, so the category bar never opens it — and
/// choosing a category puts it away, as any band change does.
///
/// ⚠️ **ONE SONG PER VIDEO, AND NONE ON A PHOTOGRAPH.** An image attachment
/// cannot carry sound, so a photo page gets a line saying so instead of tools
/// whose result would go nowhere.
///
/// ⚠️ **THE SONG IS HEARD BECAUSE THE PREVIEW PLAYS IT, NOT BECAUSE THIS MODE
/// UN-MUTES ANYTHING.** A clip is heard exactly when the item playing carries
/// a song (`MediaPreviewPlayer.load`), which covers every way a clip is loaded
/// — a settle, a crop, a new excerpt. This mode silences at once on Remove, so
/// the song does not run on while the item without it is built.
///
/// ⚠️ **LEVELS ARE LIVE AND NEED NO NEW ITEM; A NEW START DOES.** A slider moves
/// the playing item's mix as it is dragged and is stored when let go; the
/// screen's "same film" rule ignores levels (`VideoSoundtrack.laysTheSameAudio`),
/// so storing one reloads nothing. The excerpt is stored when the finger lifts,
/// and the item is rebuilt at the played second it had reached.
@MainActor
final class MediaEditorSoundtrackMode: MediaEditorMode {
    /// What the pill says while the page has no song.
    static let addTitle = "Add a song"

    /// What the band says on a photograph.
    static let photoNotice = "Songs go on videos — this photo will be posted as it is."

    /// The longest song name the pill shows before it gives way.
    static let pillTitleLength = 18

    private weak var host: (any MediaEditorHosting)?
    private let sourcing: any MediaSoundtrackSourcing

    init(host: any MediaEditorHosting, sourcing: any MediaSoundtrackSourcing) {
        self.host = host
        self.sourcing = sourcing
    }

    private lazy var tools: MediaSoundtrackToolsView = {
        let tools = MediaSoundtrackToolsView()
        tools.onPick = { [weak self] origin in self?.pick(from: origin) }
        tools.onRemove = { [weak self] in self?.removeSong() }
        tools.onLevels = { [weak self] music, original in self?.preview(music: music, original: original) }
        tools.onLevelsSettled = { [weak self] music, original in self?.store(music: music, original: original) }
        tools.onStartSettled = { [weak self] seconds in self?.store(start: seconds) }
        return tools
    }()

    private lazy var photoNotice = BandNoticeView(Self.photoNotice)

    /// Whether a pick is on screen or being copied — one at a time.
    private(set) var isPicking = false

    /// How long each song imported this session runs, from its check.
    private var songLengths: [URL: Double] = [:]
    /// Each song's waveform, once read — a few kilobytes each.
    private var waveforms: [URL: [Float]] = [:]
    private var reading: Set<URL> = []

    // MARK: - The pill

    /// What the pill says for the page in front of the author.
    var pillTitle: String {
        guard let host, let id = host.currentItemID, let song = host.edits(for: id).soundtrack else {
            return Self.addTitle
        }
        let name = song.title.count > Self.pillTitleLength
            ? String(song.title.prefix(Self.pillTitleLength - 1)) + "…" : song.title
        return "Song: \(name)"
    }

    /// The pill was tapped: open the song tools, or put them away.
    func toggle() {
        guard let host, let id = host.currentItemID, let item = host.item(id) else { return }
        if isShowing {
            host.showInBand(nil)
        } else {
            open(for: id, item: item)
        }
    }

    /// Whether the band is holding this mode's tools or its notice.
    private var isShowing: Bool {
        guard let content = host?.bandContent else { return false }
        return content === tools || content === photoNotice
    }

    // MARK: - MediaEditorMode

    var tenant: UIView? {
        guard let host, let id = host.currentItemID else { return nil }
        return host.item(id)?.isVideo == true ? tools : photoNotice
    }

    func open(for id: String, item: MediaLibraryItem) {
        guard item.isVideo else {
            host?.showInBand(photoNotice)
            return
        }
        dress(for: id)
        host?.showInBand(tools)
    }

    /// ⚠️ **A LEVEL LEFT MID-DRAG IS PUT BACK.** The playing item may be wearing
    /// a level nothing stored; once the tools are gone nothing would ever store
    /// it, so the item goes back to what the edit says.
    func bandWillChange(to accessory: UIView?) {
        guard accessory !== tools, host?.bandContent === tools else { return }
        guard let host, let id = host.currentItemID, let song = host.edits(for: id).soundtrack else { return }
        preview(music: song.musicVolume, original: song.originalVolume)
    }

    /// The pill names the new page's song, and open tools follow the page —
    /// swapping for the notice on a photograph and back.
    func pageDidSettle(on id: String?) {
        host?.refreshSoundPill()
        guard isShowing, let host, let id, let item = host.item(id) else { return }
        let wanted: UIView = item.isVideo ? tools : photoNotice
        if host.bandContent === wanted {
            if item.isVideo { dress(for: id) }
        } else {
            open(for: id, item: item)
        }
    }

    /// Nothing is held: a picker on screen covers the editor, so the screen
    /// cannot go while one is up, and the song's files belong to the draft.
    func screenWillDisappear() {}

    /// A step put a whole edit back: the song, the excerpt and the two levels
    /// may all differ from what the tools are showing.
    ///
    /// ⚠️ **THE LIVE MIX IS STATED AGAIN, NOT ONLY THE CONTROLS.** The levels
    /// reach the player on their own path (`setMixLevels`, so a drag is heard
    /// without rebuilding the item); an item rebuilt from restored edits does
    /// carry them, but nothing would have told the CURRENT item — the author
    /// would see the sliders jump back and go on hearing the mix they undid.
    func editsWereRestored(for id: String) {
        guard let host, host.currentItemID == id else { return }
        dress(for: id)
        let song = host.edits(for: id).soundtrack
        preview(music: song?.musicVolume ?? 1, original: song?.originalVolume ?? 1)
    }

    // MARK: - Picking

    private var currentSong: VideoSoundtrack? {
        guard let host, let id = host.currentItemID else { return nil }
        return host.edits(for: id).soundtrack
    }

    private func pick(from origin: MediaSoundtrackOrigin) {
        guard !isPicking, let host, let id = host.currentItemID, host.item(id)?.isVideo == true else { return }
        isPicking = true
        tools.setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            let picked = await sourcing.pick(from: origin) { [weak self] controller in
                self?.host?.presentSheet(controller)
            }
            await land(picked, on: id)
            isPicking = false
            tools.setBusy(false)
            // ⚠️ **THE SHEET HAS GONE AND UIKIT SAID NOTHING** — a page sheet
            // leaves the editor on screen, so it gets no appearance callback
            // either way. The pick resolving IS the signal, on a cancel as much
            // as on a choice.
            host.sheetDidClose()
        }
    }

    /// Checks what was picked and, if it is a song, lays it under `id`.
    private func land(_ picked: MediaSoundtrackPick, on id: String) async {
        switch picked {
        case .cancelled:
            return
        case .failed:
            tools.showProblem("That file couldn't be opened.")
        case .picked(let fileURL, let title):
            switch await VideoSoundtrack.vet(fileURL) {
            case .failure(let problem):
                tools.showProblem(Self.message(for: problem))
            case .success(let seconds):
                songLengths[fileURL] = seconds
                attach(VideoSoundtrack(fileURL: fileURL, title: title), to: id)
            }
        }
    }

    static func message(for problem: SoundtrackProblem) -> String {
        switch problem {
        case .unreadable: "That file can't be played."
        case .protected: "That song is protected and can't be used."
        case .noSound: "That file has no sound."
        case .tooShort: "That sound is too short — pick one at least a second long."
        }
    }

    private func attach(_ song: VideoSoundtrack, to id: String) {
        guard let host else { return }
        host.change(id) { $0.soundtrack = song }
        // A new song is a new audio track: the item is rebuilt, and the preview
        // lets it be heard once it is in.
        host.editsDidChange(id, .film)
        host.refreshSoundPill()
        if host.currentItemID == id { dress(for: id) }
    }

    private func removeSong() {
        guard let host, let id = host.currentItemID, host.edits(for: id).soundtrack != nil else { return }
        if let surface = surface(for: id) { host.preview.setMuted(true, in: surface) }
        host.change(id) { $0.soundtrack = nil }
        host.editsDidChange(id, .film)
        host.refreshSoundPill()
        dress(for: id)
    }

    // MARK: - Levels and the excerpt

    private func preview(music: Double, original: Double) {
        guard let host, let id = host.currentItemID, let surface = surface(for: id) else { return }
        host.preview.setMixLevels(music: music, original: original, in: surface)
    }

    private func store(music: Double, original: Double) {
        guard let host, let id = host.currentItemID, host.edits(for: id).soundtrack != nil else { return }
        host.change(id) {
            $0.soundtrack?.musicVolume = music
            $0.soundtrack?.originalVolume = original
        }
        host.editsDidChange(id, .film)
    }

    private func store(start: Double) {
        guard let host, let id = host.currentItemID,
              let song = host.edits(for: id).soundtrack, song.startSeconds != start
        else { return }
        host.change(id) { $0.soundtrack?.startSeconds = start }
        host.editsDidChange(id, .film)
    }

    /// The surface `id` is playing in — nil unless it is the page playing.
    private func surface(for id: String) -> VideoRenderView? {
        guard let host, let playing = host.playingSurface,
              host.pageCell(for: id)?.videoSurface === playing
        else { return nil }
        return playing
    }

    // MARK: - Dressing the tools

    /// Hands the tools the page's song, its length and the film's, and its
    /// waveform — read once per song.
    private func dress(for id: String) {
        guard let host else { return }
        let edits = host.edits(for: id)
        let film = filmSeconds(for: id, timeline: edits.timeline)
        guard let song = edits.soundtrack else {
            tools.show(song: nil, songSeconds: nil, filmSeconds: film)
            return
        }
        tools.show(song: song, songSeconds: songLengths[song.fileURL], filmSeconds: film)
        if let peaks = waveforms[song.fileURL] {
            tools.show(peaks: peaks)
        } else {
            read(song.fileURL, for: id)
        }
    }

    /// The length the film plays for — what the excerpt's window is as long as.
    private func filmSeconds(for id: String, timeline: MediaTimeline) -> Double {
        guard let host else { return 0 }
        var file = host.fileSeconds(for: id) ?? 0
        if file <= 0, case .video(let declared)? = host.item(id)?.kind { file = declared }
        return MediaTimelining.playedSeconds(of: timeline, withinSource: file)
    }

    private func read(_ song: URL, for id: String) {
        guard !reading.contains(song) else { return }
        reading.insert(song)
        Task { [weak self] in
            let length = self?.songLengths[song] == nil ? try? await VideoSoundtrack.vet(song).get() : nil
            let peaks = (try? await AudioWaveform.peaks(of: song)) ?? []
            guard let self else { return }
            reading.remove(song)
            if let length { songLengths[song] = length }
            waveforms[song] = peaks
            // Only onto the tools still showing this song.
            guard let host, let current = host.currentItemID,
                  host.edits(for: current).soundtrack?.fileURL == song
            else { return }
            if length != nil { dress(for: current) } else { tools.show(peaks: peaks) }
        }
    }
}

extension MediaEditorSoundtrackMode {
    /// Internal for tests: the song tools, built or not.
    var debugTools: MediaSoundtrackToolsView { tools }
    /// Internal for tests: the notice a photograph gets.
    var debugPhotoNotice: BandNoticeView { photoNotice }
    /// Internal for tests: whether a song's waveform has been read.
    func debugHasWaveform(for song: URL) -> Bool { waveforms[song] != nil }
}
