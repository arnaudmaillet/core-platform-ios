import AVFoundation
import UIKit
import VoiceKit

/// One voice at a time, app-wide, for every view that shows it (#2205):
/// the views a host binds to an id — a voice post's card and its page —
/// show the same progress, and a voice started on one goes on, at the same
/// place, on the other.
///
/// - **It plays through `VoicePlayer.shared`** (one player for the app) and
///   listens to its `didChange`: the conversation keeps the player's one
///   `onChange` for itself.
/// - **A voice left mid-way keeps its place** until it is played again or
///   played to its end.
/// - **The host says the id** — a post's or a message's — and where the
///   audio is.
@MainActor
public final class VoicePlaybackHub {
    public static let shared = VoicePlaybackHub(player: .shared)

    public let player: VoicePlayer
    /// Where each voice left mid-way stands, 0…1.
    private(set) var positions: [String: Double] = [:]
    /// The voice the player spoke for last.
    private var shownID: String?
    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var observer: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    private struct Binding {
        weak var view: VoiceView?
        let id: String
        let url: URL?
        let duration: TimeInterval
        let levels: [UInt8]?
    }

    public init(player: VoicePlayer, notifications: NotificationCenter = .default) {
        self.player = player
        observer = notifications.addObserver(forName: VoicePlayer.didChange, object: player, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerChanged() }
        }
        // Sent to the background, a voice post pauses where it is (#2207): it
        // is a deliberate tap's listening, not a Background Play track.
        backgroundObserver = notifications.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForBackground() }
        }
    }

    /// Shows voice `id` in `view` and wires its taps: play / pause, seek,
    /// speed. A view bound again (a reused cell) forgets its last id.
    public func bind(_ view: VoiceView, id: String, url: URL?, duration: TimeInterval, levels: [UInt8]?) {
        let binding = Binding(view: view, id: id, url: url, duration: duration, levels: levels)
        bindings[ObjectIdentifier(view)] = binding
        prune()
        view.configure(state(for: binding))
        view.onPlayTap = { [weak self] in self?.toggle(id) }
        view.onSeek = { [weak self] fraction, _ in self?.seek(id, to: fraction) }
        view.onSpeedTap = { [weak self] in
            guard let self else { return }
            player.setSpeed(player.speed.next)
        }
    }

    /// Lets `view` go — a cell reused for something that does not speak.
    public func unbind(_ view: VoiceView) {
        bindings[ObjectIdentifier(view)] = nil
    }

    /// Plays voice `id` or pauses it.
    public func toggle(_ id: String) {
        if player.messageID == id, player.state == .playing {
            player.pause()
            return
        }
        guard let url = bindings.values.first(where: { $0.id == id && $0.url != nil })?.url else { return }
        rememberShown()
        shownID = id
        let resume = player.messageID == id && player.state == .paused
        player.play(id, url: url, from: resume ? nil : positions[id])
        refresh()
    }

    /// A tap or a drag on the bars: there, playing or not.
    public func seek(_ id: String, to fraction: Double) {
        if player.messageID == id { player.seek(to: fraction) }
        positions[id] = fraction
        refresh()
    }

    /// Voice `id` stops where it is — its card left the screen, its page
    /// stopped owning it — and keeps its place.
    public func stop(_ id: String) {
        guard player.messageID == id else { return }
        rememberShown()
        player.stop()
        refresh()
    }

    /// `view` left the screen — scrolled off, its cell reused, its sheet or
    /// bubble closed (#2208): its voice stops where it is, keeping its place,
    /// UNLESS another view on screen shows the same voice. A tap on a card
    /// opens its post, whose page binds the same id before the card leaves
    /// the window: the voice goes on there, at the same place.
    public func viewLeftScreen(_ view: VoiceView) {
        let key = ObjectIdentifier(view)
        guard let id = bindings[key]?.id, player.messageID == id else { return }
        let shownElsewhere = bindings.contains { other, binding in
            other != key && binding.id == id && binding.view?.window != nil
        }
        if !shownElsewhere { stop(id) }
    }

    /// The id a post's voice plays under, wherever the post is drawn — a
    /// card, a tile, a pin's bubble, its page (#2208) — so a voice started on
    /// one goes on, at the same place, on the next. `rawID` is the post's id.
    public nonisolated static func postID(_ rawID: String) -> String { "post-\(rawID)" }

    /// Pauses what plays, keeping its place.
    func pauseForBackground() {
        guard player.state == .playing || player.state == .loading else { return }
        rememberShown()
        player.pause()
        refresh()
    }

    /// Whether voice `id` is the one playing.
    public func isPlaying(_ id: String) -> Bool {
        player.messageID == id && (player.state == .playing || player.state == .loading)
    }

    // MARK: - State

    /// What a view bound to `id` shows: the player's word when it speaks
    /// for it, where it was left otherwise.
    public func state(for id: String, duration: TimeInterval, levels: [UInt8]?) -> VoiceView.State {
        var state = VoiceView.State(levels: levels ?? VoiceView.genericLevels, duration: duration)
        state.speedLabel = player.speed.label
        if player.messageID == id {
            let progress = player.progress ?? positions[id] ?? 0
            state.playback = switch player.state {
            case .loading: .loading
            case .playing: .playing(progress: progress)
            case .paused: progress > 0 ? .paused(progress: progress) : .rest
            case .failed: .failed
            case .idle, .ended: .rest
            }
        } else if let position = positions[id], position > 0 {
            state.playback = .paused(progress: position)
        }
        return state
    }

    private func state(for binding: Binding) -> VoiceView.State {
        state(for: binding.id, duration: binding.duration, levels: binding.levels)
    }

    private func playerChanged() {
        if player.state == .ended, let id = player.messageID { positions[id] = nil }
        refresh()
    }

    private func rememberShown() {
        guard let shown = shownID, player.messageID == shown else { return }
        switch player.state {
        case .playing, .paused:
            if let progress = player.progress { positions[shown] = progress }
        case .ended:
            positions[shown] = nil
        default:
            break
        }
    }

    private func refresh() {
        prune()
        for binding in bindings.values {
            binding.view?.update(state(for: binding))
        }
    }

    private func prune() {
        bindings = bindings.filter { $0.value.view != nil }
    }

    #if DEBUG
    /// A hub on a player that makes no sound and touches no audio session,
    /// for the tests of the surfaces that draw a voice post (#2208).
    public static func silentForTests() -> VoicePlaybackHub {
        let name = "voice-silent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let center = NotificationCenter()
        let player = VoicePlayer(
            session: SilentSession(), makeEngine: { SilentEngine() }, defaults: defaults, notifications: center
        )
        return VoicePlaybackHub(player: player, notifications: center)
    }

    public var debugBoundCount: Int { bindings.values.filter { $0.view != nil }.count }
    #endif
}

#if DEBUG
/// `VoicePlaybackHub.silentForTests`' session: it takes nothing.
private final class SilentSession: VoiceAudioSessionControlling {
    var isInputAvailable = true
    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    func setAllowHapticsAndSystemSoundsDuringRecording(_ allow: Bool) throws {}
}

/// Its engine: it plays nothing, and says it is ten seconds long.
private final class SilentEngine: VoicePlaybackEngine {
    var onEnd: (() -> Void)?
    var onFailure: (() -> Void)?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval? = 10
    func load(_ url: URL) {}
    func play(rate: Float) {}
    func pause() {}
    func seek(to seconds: TimeInterval) { currentTime = seconds }
}
#endif
