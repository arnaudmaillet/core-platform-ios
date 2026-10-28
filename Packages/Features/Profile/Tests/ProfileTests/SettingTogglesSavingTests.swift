import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Profile

/// A settings switch while it saves (#1775, the owner 2026-10-28): where the
/// tap put it, waiting with the loader beside it, the other switches still
/// usable — then the server's answer, or back where it was.
@MainActor
struct SettingTogglesSavingTests {
    /// Holds each save until the test lets it answer; fails them when asked.
    private actor GatedDiscovery: ActivityDiscoveryManaging {
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var saved: [ActivityDiscoverySettings.Switch] = []
        private let fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        func activityDiscoverySettings() async throws -> ActivityDiscoverySettings { ActivityDiscoverySettings() }

        func setActivityDiscovery(_ key: ActivityDiscoverySettings.Switch, to isOn: Bool) async throws {
            await withCheckedContinuation { held.append($0) }
            if fails { throw ProfileError.transport(message: "down") }
            saved.append(key)
        }

        var waiting: Int { held.count }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    private struct Screen {
        let controller: ActivityDiscoveryViewController
        let window: UIWindow
    }

    private func open(_ manager: GatedDiscovery) async throws -> Screen {
        let controller = ActivityDiscoveryViewController(manager: manager)
        controller.skeletonClock = ManualLoadingClock().clock
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        for _ in 0..<500 where controller.debugToggle(.readReceipts) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.debugToggle(.readReceipts) != nil, "the switches never showed")
        return Screen(controller: controller, window: window)
    }

    private func flip(_ key: ActivityDiscoverySettings.Switch, on screen: Screen) throws {
        let toggle = try #require(screen.controller.debugToggle(key)?.toggle)
        toggle.isOn.toggle()
        toggle.sendActions(for: .valueChanged)
    }

    @Test func aSwitchWaitsWhereItWasPutWithTheLoaderAndTheOthersStayUsable() async throws {
        let manager = GatedDiscovery()
        let screen = try await open(manager)

        try flip(.readReceipts, on: screen)
        let saving = try #require(screen.controller.debugToggle(.readReceipts))
        #expect(!saving.toggle.isOn, "the switch went back while its change travels")
        #expect(!saving.toggle.isEnabled)
        #expect(saving.busy, "no loader beside the switch on its way")
        let other = try #require(screen.controller.debugToggle(.activityStatus))
        #expect(other.toggle.isEnabled, "another switch waits for this one")
        #expect(!other.busy)

        while await manager.waiting == 0 { await Task.yield() }
        await manager.release()
        for _ in 0..<500 where screen.controller.debugToggle(.readReceipts)?.busy == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try #require(screen.controller.debugToggle(.readReceipts))
        #expect(!saved.toggle.isOn)
        #expect(saved.toggle.isEnabled)
        #expect(!saved.busy)
        #expect(await manager.saved == [.readReceipts])
    }

    @Test func aFailedSaveGoesBackAndSaysWhy() async throws {
        let manager = GatedDiscovery(fails: true)
        let screen = try await open(manager)

        try flip(.readReceipts, on: screen)
        while await manager.waiting == 0 { await Task.yield() }
        await manager.release()
        for _ in 0..<500 where !(screen.controller.presentedViewController is UIAlertController) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(screen.controller.presentedViewController is UIAlertController, "the failure was not told")
        let back = try #require(screen.controller.debugToggle(.readReceipts))
        #expect(back.toggle.isOn, "the switch did not go back")
        #expect(!back.busy)
    }
}
