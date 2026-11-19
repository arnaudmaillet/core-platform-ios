import CoreModels
import CoreNavigation
import MediaCore
import MediaPlayback
import PostSurfaces
import UIKit

/// What the full-screen feed's sound asks of its screen (#2387): where the
/// screen stands, which page owns it, and the records it draws.
@MainActor
protocol SnapSoundPlaybackHost: AnyObject {
    /// The screen is on screen (appeared, not yet gone).
    var isOnScreen: Bool { get }
    /// The page covering most of the screen — the one heard.
    var playbackOwner: Int? { get }
    var orderedIDs: [PostID] { get }
    /// The posts learnt unavailable (#1409): their track never runs.
    var unavailablePostIDs: Set<PostID> { get }
    var activeSnapCell: SnapFeedCell? { get }
    /// The screen's view when loaded: a surface inside it is the screen's own.
    var viewIfLoaded: UIView? { get }
    /// The view the share of the screen is measured on.
    var viewportShareHost: UIView { get }
    func displayModel(for id: PostID) -> FeedItemDisplayModel?
    func lifecycleCell(at index: Int) -> SnapCellLifecycle?
    /// The screen's watched state, asked again: the share crossed half, or
    /// the app left or came back.
    func refreshVisibility()
    /// Turns (or stops) every record of the post's sound the screen draws:
    /// the page's bubble, the footer's, the panels' rail slots.
    func drawSoundSpinning(_ playing: Bool)
    #if DEBUG
    func publishViewportProbe()
    #endif
}

/// The full-screen feed's sound, the impure half (#2387): what is heard and
/// through which surface, the song player, the records' spin timer, the
/// share of the screen its volume follows, Background Play and Picture in
/// Picture. The pure half — which sound a post is set to, whether its song
/// may be heard — is `SnapSoundState`.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN. Every entry point runs in the caller's
/// turn: the picture's owner changing hands (`updateViewportPlayback`)
/// hands the sound over on the same frame (#1791), and the share's change is
/// heard before `plays` is updated (`viewportShareDidChange`).
@MainActor
final class SnapSoundPlayback {
    private unowned let host: any SnapSoundPlaybackHost
    private let videoPlayback: VideoPlaybackController?
    private let imagePipeline: ImagePipeline
    private let soundState: SnapSoundState

    /// The surface THIS screen last made audible, so leaving only clears its own.
    private weak var ownAudibleSurface: VideoRenderView?
    private var isAudioYielded = false
    /// Through the pool's byte cache when there is one (#895).
    private lazy var songPlayer = FeedSongPlayer(playback: videoPlayback)
    /// The page whose song the viewer paused from the sound sheet's record
    /// (#1148): its song stays paused, where it was, until resumed — another
    /// page plays its own. A carousel's page turn clears it (the screen's
    /// `onMediaPageChanged`).
    var songPausedFor: PostID?
    /// The post whose track the song player holds (#1849): another post's
    /// starts it again from its start.
    private var songPostID: PostID?
    /// A hold on a carousel's page is holding its track.
    private var isSongHeld = false
    /// The sound sheet open over the page, mirroring it (#1148).
    weak var soundSheet: SoundSheetViewController?
    private var coverSpinTimer: Timer?
    /// The app is in the foreground — or is not, but kept the screen as it
    /// was for Background Play or the floating window.
    private(set) var isForeground = true
    /// Background Play (#483): this screen's clip went on playing when the
    /// app left the screen, and the screen was left exactly as it was.
    private var isPlayingInBackground = false
    /// Picture in Picture (#483): the surface this screen readied for the
    /// floating window, so leaving only lets go of its own.
    private weak var ownPictureInPictureSurface: VideoRenderView?
    /// The app left with a clip readied: the screen waits, untouched, for the
    /// system to open the window — or gives up and pauses as usual.
    private var isAwaitingPictureInPicture = false

    init(
        host: any SnapSoundPlaybackHost, videoPlayback: VideoPlaybackController?,
        imagePipeline: ImagePipeline, soundState: SnapSoundState
    ) {
        self.host = host
        self.videoPlayback = videoPlayback
        self.imagePipeline = imagePipeline
        self.soundState = soundState
    }

    // MARK: - The share of the screen (#1914)

    /// The share of this screen still on screen (#1914): what its clip's gate
    /// reads — it plays at half and above, and its sound follows the share.
    private(set) lazy var viewportShare: ViewportShare = {
        let share = ViewportShare(host: host.viewportShareHost)
        share.onChange = { [weak self] value in self?.viewportShareDidChange(value) }
        return share
    }()

    private var viewportSharePlays = true

    private func viewportShareDidChange(_ share: CGFloat) {
        #if DEBUG
        host.publishViewportProbe()
        #endif
        let volume = ViewportShare.volume(at: share)
        videoPlayback?.setAudibleVolume(volume)
        songPlayer.volume = volume
        let plays = ViewportShare.plays(at: share)
        guard plays != viewportSharePlays else { return }
        viewportSharePlays = plays
        host.refreshVisibility()
        // Every record of the post's sound turns with it (#1148), the sound
        // sheet's included (the owner 2026-10-31: the sheet's record kept
        // turning over a post its expansion had paused). Asked now, and once
        // more after the turn, for a pause the player settles a beat later.
        refreshCoverSpin()
        DispatchQueue.main.async { [weak self] in self?.refreshCoverSpin() }
    }

    // MARK: - The audible surface and the song

    /// Hears the page that owns the screen — or nothing, when the feed is
    /// muted, covered, or in the background.
    ///
    /// Asked on every change of any of those: the owner moving (a scroll), a
    /// carousel turning its page, the screen appearing or leaving, the app
    /// going to the background, and the viewer's toggle.
    ///
    /// - Parameter ownerCell: the owner's cell when the caller holds it — a
    ///   cell being displayed is not yet one the collection view hands back.
    func refreshAudibleSurface(ownerCell: SnapFeedCell? = nil) {
        refreshSong()
        refreshPictureInPicture(ownerCell: ownerCell)
        guard let videoPlayback else { return }
        var surface: VideoRenderView?
        // A carousel's clips are never heard: the post's track is its sound
        // (#1849, `refreshSong`).
        // A volume key turns the sound on while this screen owns it (#1931).
        videoPlayback.feedSound.setWatching(
            host.isOnScreen && isForeground && !isAudioYielded, by: host,
            readsRinger: MediaPlaybackPolicy.playsInBackground || MediaPlaybackPolicy.floatsInPictureInPicture
        )
        if host.isOnScreen, isForeground, !isAudioYielded,
           let owner = host.playbackOwner, ownerModel.map(SnapSoundState.clipIsHeard(in:)) ?? true,
           let cell = ownerCell ?? host.lifecycleCell(at: owner) as? SnapFeedCell {
            surface = cell.audibleSurface
        }
        // Only ever CLEARS what this screen set: another feed pushed on top
        // owns the sound now, and this one leaving must not silence it.
        if surface == nil, !Self.leavingClearsAudibleSurface(
            videoPlayback.currentAudibleSurface, own: ownAudibleSurface, screen: host.viewIfLoaded
        ) {
            ownAudibleSurface = nil
            return
        }
        ownAudibleSurface = surface
        videoPlayback.setAudibleSurface(surface)
    }

    /// Whether a screen whose page no longer wants to be heard should silence
    /// the surface the pool is hearing now.
    ///
    /// ⚠️ **THE SURFACE THIS SCREEN NAMED IS NOT ALWAYS THE ONE IT HEARS.** A
    /// landing that hands the page the flight card's live view
    /// (`SnapFeedCell.adoptLiveRenderView` → `VideoPlaybackController
    /// .adoptSurface`) moves the pool's audible surface onto that view, and
    /// the one this screen remembered is thrown away. Asked by identity alone,
    /// the screen then took the adopted view for ANOTHER feed's and left it
    /// talking: a map marker's feed closed onto the place page with its clip
    /// still heard, because the Activity row the close lands on plays the very
    /// same player (the post the viewer was on is that row).
    ///
    /// So a surface is this screen's when it is the one it named OR one of its
    /// own views — the page's surface lives in this screen's hierarchy whatever
    /// swapped it in. A surface nobody holds any more (nil) is cleared too: its
    /// player may still be heard, and no screen is listening to it. Only a live
    /// surface elsewhere — a feed pushed on top — is left alone.
    static func leavingClearsAudibleSurface(
        _ current: UIView?, own: UIView?, screen: UIView?
    ) -> Bool {
        guard let current else { return true }
        if current === own { return true }
        guard let screen else { return false }
        return current.isDescendant(of: screen)
    }

    /// The sound of a page with no clip — a photograph, a collection of
    /// them, a text post — played while that page owns the screen, under the
    /// same rules as a clip's (see `FeedSongPlayer`), and nothing under Power
    /// Saving (#580; `SnapSoundState.song`).
    private func refreshSong() {
        // A post's track starts from its start when the post becomes the page
        // that owns the screen, and runs on through its pages (#1849): another
        // post — the same song or not — starts it again.
        if let owned = ownerModel?.id, owned != songPostID {
            songPlayer.stop()
            songPostID = owned
            if songPausedFor != owned { songPausedFor = nil }
            isSongHeld = false
        }
        var song: URL?
        if let model = ownerModel, trackMayRun(model) {
            song = soundState.song(for: model)
        }
        songPlayer.play(song)
    }

    /// Whether `model`'s track may run now, heard or muted: the post owns
    /// the screen in the foreground, nothing took the audio, and the viewer
    /// has neither paused nor held it. The song's rule, and the muted
    /// record's (#1875).
    private func trackMayRun(_ model: FeedItemDisplayModel) -> Bool {
        host.isOnScreen && isForeground && !isAudioYielded && !isSongHeld
            && model.id != songPausedFor && !host.unavailablePostIDs.contains(model.id)
    }

    /// Whether the post on screen PLAYS — what every record of its sound
    /// turns for (#1148), on silent too (#1931).
    private var postIsPlaying: Bool {
        SnapSoundState.postPlays(
            onScreen: host.isOnScreen,
            clipAdvancing: host.activeSnapCell?.isClipAdvancing ?? false,
            songPlaying: songPlayer.isPlaying
        )
    }

    /// The post that owns the screen.
    private var ownerModel: FeedItemDisplayModel? {
        guard let owner = host.playbackOwner, host.orderedIDs.indices.contains(owner) else { return nil }
        return host.displayModel(for: host.orderedIDs[owner])
    }

    /// A tap on a carousel's page (#1849): the post's track and the clip on
    /// screen pause together, or resume together. On a picture page the
    /// picture wears the stopped mark, as a clip's does.
    func togglePostTrack(on cell: SnapFeedCell, id: PostID) {
        let pausing: Bool
        if cell.canTogglePlayback, let paused = cell.togglePlayback() {
            pausing = paused
        } else {
            pausing = songPausedFor != id
            cell.setPausedMarkVisible(pausing)
        }
        songPausedFor = pausing ? id : nil
        refreshSong()
        refreshCoverSpin()
    }

    /// A hold on a carousel's page holds its track, as it holds its clip.
    func holdPostTrack(_ held: Bool) {
        isSongHeld = held
        refreshSong()
        refreshCoverSpin()
    }

    /// Turns the records while the page's media plays — a clip running, or a
    /// song — AND THE POST HAS A SOUND, and stops them when it does not: a
    /// tap-to-pause, a hold, the sound sheet covering the page, the screen
    /// leaving. The sound half is each record's own guard (#1871): a "No
    /// audio" face never turns, so this keeps asking one question for all.
    ///
    /// ASKED rather than told: a clip pauses through half a dozen doors (the
    /// viewer's tap, a hold, a sheet, a flight, a stall), and a quarter-second
    /// look at the player is one rule where wiring every door would be six.
    private func refreshCoverSpin() {
        let playing = postIsPlaying
        // The sound bubble's record turns while the post PLAYS — muted too
        // (#1148, reversing #683's audible-only turn; the mute is the badge)
        // — and so does the panel's slot, where a TEXT page's sound lives
        // (#692), the footer's (#1999), and the sound sheet's record.
        host.drawSoundSpinning(playing)
        // Two tracks, never together (the owner, 2026-10-31): the post
        // playing again — the viewer's tap on it — stops the sheet's own.
        if playing, let soundSheet, soundSheet.isTrackEngaged {
            soundSheet.releaseTrack()
        }
    }

    func setCoverSpinWatch(_ on: Bool) {
        coverSpinTimer?.invalidate()
        coverSpinTimer = nil
        if on {
            coverSpinTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCoverSpin() }
            }
        }
        refreshCoverSpin()
    }

    /// Silences this screen's sound while something else is heard over it —
    /// the sound sheet covering the page — and gives it back after.
    func yieldAudio(_ yielded: Bool) {
        isAudioYielded = yielded
        refreshAudibleSurface()
    }

    // MARK: - Background Play and Picture in Picture (#483)

    func setForeground(_ foreground: Bool) {
        if !foreground {
            let keepsPlaying = continueInBackground()
            isPlayingInBackground = keepsPlaying
            let floats = awaitPictureInPicture()
            // Nothing is paused or silenced: the page keeps its player, for the
            // Lock Screen's controls, the floating window, or both.
            if keepsPlaying || floats { return }
        }
        if foreground {
            isAwaitingPictureInPicture = false
            videoPlayback?.stopPictureInPicture()
            if isPlayingInBackground {
                isPlayingInBackground = false
                videoPlayback?.endBackgroundPlayback()
            }
        }
        isForeground = foreground
        host.refreshVisibility()
    }

    /// Picture in Picture (#483): when this screen readied its clip, leaves it
    /// playing for the window the system opens as the app resigns. A window
    /// that does not come — or that the viewer closes while the app is away —
    /// hands the page back to the usual pause.
    private func awaitPictureInPicture() -> Bool {
        guard let videoPlayback, ownPictureInPictureSurface != nil,
              videoPlayback.isPictureInPictureArmed, MediaPlaybackPolicy.floatsInPictureInPicture
        else { return false }
        isAwaitingPictureInPicture = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, isAwaitingPictureInPicture, !(self.videoPlayback?.isPictureInPictureActive ?? false) else { return }
            pictureInPictureEnded()
        }
        return true
    }

    /// The window closed (or never opened) while the app is away: unless
    /// Background Play keeps the clip going, the page pauses as it would have.
    private func pictureInPictureEnded() {
        guard isAwaitingPictureInPicture else { return }
        isAwaitingPictureInPicture = false
        // ⚠️ CLOSED INTO THE APP, NOT AWAY FROM IT. The window's "back to the
        // app" closes it a moment before the app is in the foreground: read
        // as "closed while away", the page paused, its picture went black and
        // the clip came back from elsewhere (the owner's device, 2026-11-06).
        // The page keeps playing; the foreground takes over.
        if videoPlayback?.pictureInPictureClosedIntoApp == true { return }
        guard !isPlayingInBackground, UIApplication.shared.applicationState == .background else { return }
        isForeground = false
        host.refreshVisibility()
    }

    /// Readies the page that owns the screen for the floating window — or lets
    /// go of this screen's, when the setting is off or the screen is covered.
    private func refreshPictureInPicture(ownerCell: SnapFeedCell? = nil) {
        guard let videoPlayback, !isAwaitingPictureInPicture else { return }
        var surface: VideoRenderView?
        // A single clip floats, never a carousel's muted one (#1849); and only
        // while the viewer hears the feed (#1931, #483): a readied window
        // makes the session `.playback`, which a phone on silent would hear
        // before any volume key. A ringing phone hears it already.
        if MediaPlaybackPolicy.floatsInPictureInPicture, videoPlayback.feedSound.isHeard,
           host.isOnScreen, isForeground, let owner = host.playbackOwner,
           ownerModel.map(SnapSoundState.clipIsHeard(in:)) ?? true,
           let cell = ownerCell ?? host.lifecycleCell(at: owner) as? SnapFeedCell {
            surface = cell.audibleSurface
        }
        if surface == nil {
            // Only lets go of what this screen readied: a feed pushed on top
            // owns the window now.
            guard ownPictureInPictureSurface != nil else { return }
            ownPictureInPictureSurface = nil
            videoPlayback.armPictureInPicture(for: nil)
            return
        }
        guard videoPlayback.armPictureInPicture(for: surface) else { return }
        ownPictureInPictureSurface = surface
        videoPlayback.onPictureInPictureChange = { [weak self] active in
            guard let self else { return }
            if active {
                isAwaitingPictureInPicture = true
            } else {
                pictureInPictureEnded()
            }
        }
    }

    /// Background Play (#483): keeps the clip this screen is being heard
    /// through playing off screen — only when the viewer turned it on, the
    /// feed is heard (the sound turned on, or a ringing phone: #1931, a phone
    /// on silent never hears it through the background), and this screen (not
    /// one under it) owns the sound.
    private func continueInBackground() -> Bool {
        guard MediaPlaybackPolicy.playsInBackground, host.isOnScreen, !isAudioYielded,
              let videoPlayback, videoPlayback.feedSound.isHeard, let surface = ownAudibleSurface,
              surface === videoPlayback.currentAudibleSurface
        else { return false }
        let model = host.playbackOwner.flatMap {
            $0 < host.orderedIDs.count ? host.displayModel(for: host.orderedIDs[$0]) : nil
        }
        guard videoPlayback.continueInBackground(surface, nowPlaying: Self.nowPlaying(for: model)) else { return false }
        if let url = model?.thumbnailURL {
            let pipeline = imagePipeline
            Task { [weak videoPlayback] in
                guard let image = try? await pipeline.image(for: url) else { return }
                videoPlayback?.setNowPlayingArtwork(image)
            }
        }
        return true
    }

    /// The Lock Screen's two lines: the caption's first line (or what the
    /// clip is), and its author.
    static func nowPlaying(for model: FeedItemDisplayModel?) -> NowPlayingInfo {
        let caption = model?.caption?
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = caption.isEmpty ? "Video" : String(caption.prefix(80))
        return NowPlayingInfo(title: title, artist: model?.authorName ?? "")
    }
}
