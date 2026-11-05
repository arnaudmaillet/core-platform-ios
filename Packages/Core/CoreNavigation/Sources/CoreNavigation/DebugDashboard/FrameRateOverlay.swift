// ⚠️ THE WHOLE FILE: DEBUG only — the debug dashboard (#2133).
#if DEBUG
import DesignSystem
import Darwin
import UIKit

/// The process's footprint and CPU, read from the kernel (#2133).
public enum DebugSystemStats {
    /// The memory iOS counts against the app (`phys_footprint`), in MB:
    /// what Xcode's gauge shows.
    public static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// The live threads' CPU, in percent of one core (100 = one core busy).
    public static func cpuPercent() -> Double? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }
}

/// Frames, hitches and hangs, measured by the app itself (#2133): there is
/// no public API for such an overlay. A frame later than its expected
/// interval by more than half a frame adds its lateness to the hitch time
/// (Apple's hitch time ratio, WWDC20 10081, in ms of hitch per second); an
/// interval over 250 ms is a hang.
///
/// ⚠️ It runs only while shown: its display link, and the memory and CPU
/// reads once a second. The badge's text changes at most twice a second and
/// never animates. Its own cost per frame is measured and printed on it.
@MainActor
public final class FrameRateOverlay: NSObject {
    public static let shared = FrameRateOverlay()

    private var link: CADisplayLink?
    private var window: OverlayWindow?
    private var windowStart: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var hitchSeconds: CFTimeInterval = 0
    private var hangs = 0
    private var tickCost: CFTimeInterval = 0
    private var lastStats: CFTimeInterval = 0
    private var stats = ""

    public var isOn: Bool { link != nil }

    /// The last half second's line, for the tests and the badge.
    public private(set) var line = ""

    public func setOn(_ on: Bool) {
        if on, link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            reset(at: CACurrentMediaTime())
            showWindow()
        } else if !on, let link {
            link.invalidate()
            self.link = nil
            window?.isHidden = true
        }
    }

    private func reset(at time: CFTimeInterval) {
        windowStart = time
        lastTimestamp = 0
        frames = 0
        hitchSeconds = 0
        hangs = 0
        tickCost = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        let expected = link.targetTimestamp - link.timestamp
        if lastTimestamp > 0 {
            let interval = link.timestamp - lastTimestamp
            if interval > 0.25 { hangs += 1 }
            if expected > 0, interval > expected * 1.5 { hitchSeconds += interval - expected }
        }
        lastTimestamp = link.timestamp
        frames += 1
        let elapsed = link.timestamp - windowStart
        if elapsed >= 0.5 {
            if began - lastStats >= 1 {
                lastStats = began
                let memory = DebugSystemStats.footprintMB().map { "\(Int($0.rounded())) MB" } ?? "— MB"
                let cpu = DebugSystemStats.cpuPercent().map { "\(Int($0.rounded()))%" } ?? "—%"
                stats = "\(memory) · CPU \(cpu)"
            }
            let fps = Double(frames) / elapsed
            let hitchRatio = hitchSeconds * 1000 / elapsed
            let perFrame = tickCost / Double(max(1, frames)) * 1000
            line = "\(Int(fps.rounded())) fps · hitch \(Int(hitchRatio.rounded())) ms/s"
                + (hangs > 0 ? " · \(hangs) hang" : "")
                + "\n\(stats) · overlay \(String(format: "%.2f", perFrame)) ms/frame"
            window?.show(line)
            reset(at: link.timestamp)
        }
        tickCost += CACurrentMediaTime() - began
    }

    private func showWindow() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let overlay = window ?? OverlayWindow(windowScene: scene)
        window = overlay
        overlay.show("measuring…")
    }

    private final class OverlayWindow: AppWindow, DebugOverlayWindow {
        private let label = UILabel()

        override init(windowScene: UIWindowScene) {
            super.init(windowScene: windowScene)
            windowLevel = .alert + 8
            isUserInteractionEnabled = false
            backgroundColor = .clear
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .white
            label.numberOfLines = 2
            label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.textAlignment = .left
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func show(_ text: String) {
            label.text = text
            let size = label.sizeThatFits(CGSize(width: 300, height: 40))
            let bottom = bounds.height - safeAreaInsets.bottom - 90
            label.frame = CGRect(x: 10, y: bottom - size.height - 6, width: size.width + 12, height: size.height + 6)
            isHidden = false
        }
    }
}

/// A long text — a call's body, a dump — selectable, with a share button.
public final class DebugTextViewController: UIViewController {
    private let text: String

    public init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let textView = UITextView(frame: view.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.text = text
        textView.backgroundColor = .systemBackground
        view.addSubview(textView)
        let text = self.text
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action, primaryAction: UIAction { _ in DebugDashboard.share([text]) }
        )
    }
}
#endif
