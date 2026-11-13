import Foundation
import Testing
@testable import LaunchArguments

/// The DEBUG switches of #2132: the launch argument wins, the persisted
/// switch stands in for it, reset clears every one.
struct DebugFlagsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "debug-flags-\(UUID().uuidString)")!
    }

    @Test func theLaunchArgumentWinsAndTheSwitchStandsIn() {
        let store = defaults()
        #expect(!DebugFlags.isOn("-viewport-share", arguments: [], defaults: store))
        #expect(DebugFlags.isOn("-viewport-share", arguments: ["app", "-viewport-share"], defaults: store))
        DebugFlags.set("-viewport-share", on: true, defaults: store)
        #expect(DebugFlags.isOn("-viewport-share", arguments: [], defaults: store))
        DebugFlags.set("-viewport-share", on: false, defaults: store)
        #expect(!DebugFlags.isOn("-viewport-share", arguments: [], defaults: store))
        // Off in the store, on from the argument: on.
        #expect(DebugFlags.isOn("-viewport-share", arguments: ["-viewport-share"], defaults: store))
    }

    @Test func resetTurnsEverySwitchOff() {
        let store = defaults()
        DebugFlags.all.forEach { DebugFlags.set($0.argument, on: true, defaults: store) }
        DebugFlags.reset(defaults: store)
        #expect(DebugFlags.all.allSatisfy { !DebugFlags.isOn($0.argument, arguments: [], defaults: store) })
    }

    /// Every listed flag is read through `isOn` somewhere: a flag read with
    /// `arguments.contains` directly could not be switched.
    @Test func everyListedFlagIsReadThroughIsOn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources = ""
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", !url.path.contains("/Tests/"), !url.path.contains("/.build/") else { continue }
                sources += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        for flag in DebugFlags.all {
            #expect(sources.contains("DebugFlags.isOn(\"\(flag.argument)\")"), "\(flag.argument) is not read through DebugFlags.isOn")
            #expect(!sources.contains("arguments.contains(\"\(flag.argument)\")"), "\(flag.argument) is still read from the arguments directly")
        }
    }
}
