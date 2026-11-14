#if DEBUG
import AVFoundation
import DesignSystem
import LaunchArguments
import UIKit
import VoiceKit

/// The voice component's catalogue (#2205), in the debug dashboard's labs
/// next to `-voice-lab`, `-voice-catalog` at launch.
///
/// The neutral panel (#2241) as every surface draws it:
/// - **Every size** — full, compact, a conversation's capped panel, the mark
///   — playing a mock voice. At full size the width says the length (#2329):
///   voice posts of 1, 5, 15, 30 and 60 s, voice messages of 1, 15 s and
///   2 min; compact keeps its host's width (1 s and 60 s side by side).
/// - **Every state**, still: idle, playing, paused mid-way, played, unplayed,
///   loading its levels, failed to play, not sent.
/// - **Every ground:** plain, a card, the dark page, glass — light and dark.
/// - **A flat-sounding voice** (the mock's synthesised takes): its waveform
///   still has a shape (`VoiceView.drawnShares`).
public final class VoiceCatalogViewController: UIViewController {
    /// `-voice-catalog` at launch.
    public static var isRequested: Bool { LaunchArgument.voiceCatalog.isPassed() }

    private let hub: VoicePlaybackHub
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private lazy var mockVoice: URL? = Self.writeMockVoice()

    /// The grounds a voice is drawn on.
    private enum Ground: CaseIterable {
        case plain, card, darkPage, glass

        var name: String {
            switch self {
            case .plain: "plain"
            case .card: "card"
            case .darkPage: "dark page"
            case .glass: "glass"
            }
        }
    }

    /// The states shown still, on the plain ground.
    private enum Still: CaseIterable {
        case idle, playing, paused, played, unplayed, loadingLevels, failed, notSent

        var name: String {
            switch self {
            case .idle: "Idle"
            case .playing: "Playing"
            case .paused: "Paused mid-way"
            case .played: "Played (message)"
            case .unplayed: "Unplayed (message)"
            case .loadingLevels: "Loading its levels"
            case .failed: "Failed to play"
            case .notSent: "Not sent (message)"
            }
        }

        var isMessage: Bool { self == .played || self == .unplayed || self == .notSent }

        func state(levels: [UInt8]) -> VoiceView.State {
            switch self {
            case .idle: VoiceView.State(levels: levels, duration: 2)
            case .playing: VoiceView.State(levels: levels, duration: 50, playback: .playing(progress: 0.35))
            case .paused: VoiceView.State(levels: levels, duration: 50, playback: .paused(progress: 0.6), speedLabel: "1.5×")
            case .played: VoiceView.State(levels: levels, duration: 12)
            case .unplayed: VoiceView.State(levels: levels, duration: 12, unplayed: true)
            case .loadingLevels: VoiceView.State(levels: nil, duration: 50)
            case .failed: VoiceView.State(levels: levels, duration: 50, playback: .failed)
            case .notSent: VoiceView.State(delivery: .failed, levels: levels, duration: 4)
            }
        }
    }

    public init(hub: VoicePlaybackHub = .shared) {
        self.hub = hub
        super.init(nibName: nil, bundle: nil)
        title = "Voice component"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.spacing = Spacing.lg
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.lg),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.lg),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg),
        ])
        for style in [UIUserInterfaceStyle.light, .dark] {
            column.addArrangedSubview(statesSection(style: style))
            for ground in Ground.allCases where ground != .darkPage {
                column.addArrangedSubview(section(style: style, ground: ground))
            }
        }
        // The dark page is dark whatever the appearance.
        column.addArrangedSubview(section(style: .dark, ground: .darkPage))
    }

    // MARK: - Sections

    /// One ground: every size, a short and a long voice, live.
    private func section(style: UIUserInterfaceStyle, ground: Ground) -> UIView {
        let title = ground == .darkPage ? "Dark page" : "\(style == .dark ? "Dark" : "Light") · \(ground.name)"
        let (block, stack) = groundBlock(title: title, style: style, ground: ground)
        let levels = VoiceView.genericLevels
        // The width says the length at full size (#2329): the narrowest up
        // to 2 s, the full width from 30 s, a post's limit "60″" (#2294).
        // Compact keeps its host's width whatever the length.
        let lengths: [(VoiceView.Size, [TimeInterval])] = [(.full, [1, 5, 15, 30, 60]), (.compact, [1, 60])]
        for (size, durations) in lengths {
            for duration in durations {
                let voice = VoiceView(size: size)
                voice.role = .post(author: "Ava Moreau")
                let id = "catalog-\(style.rawValue)-\(ground.name)-\(size)-\(Int(duration))"
                hub.bind(voice, id: id, url: mockVoice, duration: duration, levels: levels)
                stack.addArrangedSubview(caption("\(size == .full ? "Full" : "Compact") · \(Int(duration)) s"))
                stack.addArrangedSubview(voice)
            }
        }
        if ground == .plain || ground == .card {
            // A conversation's panel: from the text column, its width the
            // length's up to the cap (#2329).
            for duration: TimeInterval in [1, 15, 120] {
                let message = VoiceView(
                    size: .full, leadingInset: 44, maxPanelWidth: VoiceView.conversationMaxWidth
                )
                hub.bind(message, id: "catalog-\(style.rawValue)-\(ground.name)-message-\(Int(duration))",
                         url: mockVoice, duration: duration, levels: levels)
                stack.addArrangedSubview(caption(
                    "Message · \(Int(duration)) s · capped at \(Int(VoiceView.conversationMaxWidth)) pt"
                ))
                stack.addArrangedSubview(message)
            }

            let flat = VoiceView(size: .full)
            flat.role = .post(author: nil)
            hub.bind(flat, id: "catalog-\(style.rawValue)-\(ground.name)-flat", url: mockVoice,
                     duration: 51, levels: Self.flatLevels)
            stack.addArrangedSubview(caption("A flat-sounding voice (the mock's)"))
            stack.addArrangedSubview(flat)
        }
        let mark = VoiceMarkView()
        mark.configure(duration: 32, levels: levels)
        mark.ink = ground == .darkPage ? .white : VoiceView.ink
        stack.addArrangedSubview(caption("Mark"))
        stack.addArrangedSubview(mark)
        return block
    }

    /// Every state, still, at both sizes, on the plain ground.
    private func statesSection(style: UIUserInterfaceStyle) -> UIView {
        let (block, stack) = groundBlock(
            title: "\(style == .dark ? "Dark" : "Light") · states", style: style, ground: .plain
        )
        let levels = VoiceView.genericLevels
        for still in Still.allCases {
            stack.addArrangedSubview(caption(still.name))
            for size in [VoiceView.Size.full, .compact] {
                let voice = VoiceView(size: size)
                voice.role = still.isMessage ? .message : .post(author: "Ava Moreau")
                voice.configure(still.state(levels: levels), senderName: still.isMessage ? "Ava" : nil)
                stack.addArrangedSubview(voice)
            }
        }
        return block
    }

    /// A titled ground, and the stack its voices go in — each as wide as
    /// the ground, as a card or a page gives them.
    private func groundBlock(title: String, style: UIUserInterfaceStyle, ground: Ground) -> (UIView, UIStackView) {
        let label = UILabel()
        label.font = .appFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.text = title

        let back = UIView()
        back.overrideUserInterfaceStyle = ground == .darkPage ? .dark : style
        back.layer.cornerRadius = 20
        back.layer.cornerCurve = .continuous
        back.clipsToBounds = true
        let content: UIView
        switch ground {
        case .glass:
            back.backgroundColor = style == .dark ? .systemIndigo : .systemTeal
            let effect = UIVisualEffectView(effect: UIGlassEffect())
            effect.translatesAutoresizingMaskIntoConstraints = false
            back.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.topAnchor.constraint(equalTo: back.topAnchor, constant: Spacing.md),
                effect.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -Spacing.md),
                effect.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: Spacing.md),
                effect.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -Spacing.md),
            ])
            content = effect.contentView
        case .card:
            back.backgroundColor = Surface.page
            let card = UIView()
            Surface.dressCard(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            back.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: back.topAnchor, constant: Spacing.md),
                card.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -Spacing.md),
                card.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: Spacing.md),
                card.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -Spacing.md),
            ])
            content = card
        case .darkPage:
            back.backgroundColor = .black
            content = back
        case .plain:
            back.backgroundColor = .systemBackground
            content = back
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.md),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Spacing.md),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Spacing.md),
        ])

        let block = UIStackView(arrangedSubviews: [label, back])
        block.axis = .vertical
        block.spacing = Spacing.xs
        return (block, stack)
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .appFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.text = text
        return label
    }

    /// The mock's flattest voice (`voice-post-minute`, a synthesised take
    /// whose levels barely leave the top), as its post carries it.
    static let flatLevels: [UInt8] = {
        let digits = Array("0123456789abcdefghijklmnopqrstuv")
        let wire = "vvttsvqtvuupsrtpqrqsspssvurspssnsprnprvutsrtvprvtrvutquvprpssrsququrrlurqorrrrqrutsptuoprsoqotuuuptr"
        return wire.compactMap { character in digits.firstIndex(of: character).map(UInt8.init) }
    }()

    /// Eight seconds of a soft, wavering tone, written once.
    private static func writeMockVoice() -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "voice-catalog.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = 22_050.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8)),
              let samples = buffer.floatChannelData?[0],
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let t = Double(index) / rate
            let swell = 0.5 + 0.5 * sin(t * 2 * .pi * 0.7)
            samples[index] = Float(0.2 * swell * sin(t * 2 * .pi * (220 + 30 * sin(t * 3))))
        }
        return (try? file.write(from: buffer)) == nil ? nil : url
    }
}
#endif
