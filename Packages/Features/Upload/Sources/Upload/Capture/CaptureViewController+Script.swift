#if DEBUG
import Foundation
import UIKit

/// `-camera-script "<step>,<step>,…"` drives the camera through its own code
/// paths on launch, for a simulator that cannot be touched: pair it with
/// `-open-create camera` and `simctl io screenshot` / `recordVideo`.
///
/// ⚠️ **THE SAME ENTRY POINTS A FINGER REACHES, NOT A BACK DOOR.** Every step
/// calls what the gesture calls (`debugBeginHold` is what the shutter's hold
/// calls, `debugSelector.debugTap` is the selector's own tap), so a state seen
/// through a script is a state a person can reach.
///
/// Steps: `wait:<s>`, `tap`, `hold:<s>` (press, wait, lift), `press`,
/// `lock` (slide onto the padlock), `lift`, `undo`, `next`, `flip`,
/// `option:<flash|timer|ratio|filters|grid>`, `ratio:<tall|classic|square>`,
/// `filter:<name>`, `flash:<off|auto|on>`, `timer:<0|3|10>`, `lens:<index>`,
/// `library`, `frames` (logs the live view's frame time).
///
/// `-camera-log-frames` logs the live view's mean render time every two
/// seconds, which is how the frame time in `CaptureLiveView` was measured.
extension CaptureViewController {
    func runDebugScriptIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-camera-log-frames") { logFrames() }
        guard let flag = arguments.firstIndex(of: "-camera-script"), arguments.count > flag + 1 else { return }
        let steps = arguments[flag + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            for step in steps {
                guard let self else { return }
                await self.run(step)
            }
        }
    }

    private func run(_ step: String) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0]
        let value = parts.count > 1 ? parts[1] : ""
        NSLog("[camera-script] %@", step)
        switch name {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(value) ?? 1))
        case "tap":
            debugTapShutter()
        case "press":
            debugBeginHold()
        case "hold":
            debugBeginHold()
            try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            debugEndHold()
            try? await Task.sleep(for: .milliseconds(400))
        case "lock":
            for step in 1...6 {
                debugMoveHold(CGPoint(x: -CGFloat(step) * 14, y: 0))
                try? await Task.sleep(for: .milliseconds(40))
            }
        case "lift":
            debugEndHold()
        case "undo":
            debugTapUndo()
        case "next":
            debugTapNext()
        case "flip":
            debugFlip()
        case "library":
            debugTapLibrary()
        case "option":
            let options: [String: CaptureOption] = [
                "flash": .flash, "timer": .timer, "ratio": .ratio, "filters": .filters, "grid": .grid
            ]
            if let option = options[value] { debugSelector.debugTap(option.rawValue) }
        case "ratio":
            if let ratio = CaptureRatio(rawValue: value) { debugRatioRow.debugPick(ratio) }
        case "filter":
            if let filter = MediaFilter(rawValue: value) { debugFilterRow.debugTap(filter) }
        case "flash":
            if let flash = CaptureFlashMode(rawValue: value) { debugFlashRow.debugPick(flash) }
        case "timer":
            if let timer = CaptureTimer(rawValue: Int(value) ?? 0) { debugTimerRow.debugPick(timer) }
        case "lens":
            if let index = Int(value), index < debugLensChips.debugTitles.count { debugLensChips.debugTap(index) }
        case "frames":
            let stats = debugLiveView.debugFrameStats
            NSLog("%@", String(format: "[camera-frames] mean %.2f ms drawn %d dropped %d", stats.meanMilliseconds, stats.drawn, stats.dropped))
        default:
            print("[camera-script] unknown step \(step)")
        }
    }

    private func logFrames() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(2))
                let stats = self.debugLiveView.debugFrameStats
                NSLog("%@", String(format: "[camera-frames] mean %.2f ms drawn %d dropped %d", stats.meanMilliseconds, stats.drawn, stats.dropped))
            }
        }
    }
}
#endif
