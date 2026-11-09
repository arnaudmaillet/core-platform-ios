#if DEBUG
import AVFoundation
import DesignSystem
import UIKit
import VoiceKit

/// The voice component's catalogue (#2205), in the debug dashboard's labs
/// next to `-voice-lab`: the three sizes, light and dark, over a text face
/// and over glass, playing a mock voice.
public final class VoiceCatalogViewController: UIViewController {
    /// `-voice-catalog` at launch.
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-voice-catalog") }

    private let hub: VoicePlaybackHub
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private lazy var mockVoice: URL? = Self.writeMockVoice()

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
            column.addArrangedSubview(section(style: style, glass: false))
            column.addArrangedSubview(section(style: style, glass: true))
        }
    }

    /// One ground: the three sizes on it.
    private func section(style: UIUserInterfaceStyle, glass: Bool) -> UIView {
        let title = UILabel()
        title.font = .appFont(forTextStyle: .footnote)
        title.textColor = .secondaryLabel
        title.text = "\(style == .dark ? "Dark" : "Light") · \(glass ? "glass" : "text face")"

        let ground = UIView()
        ground.overrideUserInterfaceStyle = style
        ground.layer.cornerRadius = 20
        ground.layer.cornerCurve = .continuous
        ground.clipsToBounds = true
        let content: UIView
        if glass {
            ground.backgroundColor = style == .dark ? .systemIndigo : .systemTeal
            let effect = UIVisualEffectView(effect: UIGlassEffect())
            effect.translatesAutoresizingMaskIntoConstraints = false
            ground.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.topAnchor.constraint(equalTo: ground.topAnchor, constant: Spacing.md),
                effect.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -Spacing.md),
                effect.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: Spacing.md),
                effect.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -Spacing.md),
            ])
            content = effect.contentView
        } else {
            ground.backgroundColor = .secondarySystemBackground
            content = ground
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.md),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Spacing.md),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Spacing.md),
        ])
        let levels = VoiceView.genericLevels
        for size in [VoiceView.Size.full, .compact] {
            let voice = VoiceView(size: size)
            voice.role = .post(author: "Ava Moreau")
            let id = "catalog-\(style.rawValue)-\(glass)-\(size)"
            hub.bind(voice, id: id, url: mockVoice, duration: size == .full ? 32 : 8, levels: levels)
            stack.addArrangedSubview(caption(size == .full ? "Full" : "Compact"))
            stack.addArrangedSubview(voice)
        }
        let mark = VoiceMarkView()
        mark.configure(duration: 32, levels: levels)
        stack.addArrangedSubview(caption("Mark"))
        stack.addArrangedSubview(mark)

        let block = UIStackView(arrangedSubviews: [title, ground])
        block.axis = .vertical
        block.spacing = Spacing.xs
        return block
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .appFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.text = text
        return label
    }

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
