import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Profile

/// A settings choice is a `tick` (#1884); the choice already made, nothing.
@MainActor
struct SettingsChoiceHapticTests {
    @Test func aNewAppearanceTicksAndTheSameOneDoesNot() throws {
        let picker = AppearancePickerView(selection: .light)
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        let columns = buttons(in: picker)
        try #require(columns.count == AppearancePreference.allCases.count)
        let light = try #require(AppearancePreference.allCases.firstIndex(of: .light))
        let other = (light + 1) % columns.count
        let same = HapticRecorder.recording { columns[light].sendActions(for: .primaryActionTriggered) }
        #expect(same.isEmpty, "the chosen one played \(same)")
        let chosen = HapticRecorder.recording { columns[other].sendActions(for: .primaryActionTriggered) }
        #expect(chosen == [.tick])
    }

    // MARK: - The lists that lacked it (#1886)

    private actor Location: LocationSharingManaging {
        func locationSharing() async throws -> LocationSharingSettings { LocationSharingSettings(ghost: false, cityLevel: false) }
        func setLocationSharing(_ settings: LocationSharingSettings) async throws {}
    }

    private actor Limits: InteractionLimitsManaging {
        func interactionLimit() async throws -> InteractionLimit? {
            InteractionLimit(audience: .nonFollowers, until: Date().addingTimeInterval(86_400))
        }
        func setInteractionLimit(_ limit: InteractionLimit) async throws {}
        func clearInteractionLimit() async throws {}
        func allowsSoundReuse() async throws -> Bool { true }
        func setAllowsSoundReuse(_ allowed: Bool) async throws {}
    }

    private actor Verifier: VerificationRequesting {
        func verificationStatus() async throws -> VerificationStatus { .notRequested }
        func requestVerification(_ category: VerificationCategory, links: [String]) async throws {}
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A tick per change, then nothing for the choice already made.
    private func ticks(_ body: (_ next: () -> Void) -> Void) -> [Haptic] {
        let recorder = HapticRecorder()
        var now: TimeInterval = 0
        recorder.clock = { now }
        Haptics.$recorder.withValue(recorder) { body { now += 1 } }
        return recorder.played
    }

    @Test func locationSharingTicksPerChange() async throws {
        let screen = LocationSharingViewController(manager: Location())
        screen.loadViewIfNeeded()
        try #require(await settle { screen.debugShownSettings != nil })
        let played = ticks { next in
            screen.debugChooseCityLevel(false) // already precise
            next()
            screen.debugChooseCityLevel(true)
        }
        #expect(played == [.tick], "\(played)")
    }

    @Test func limitInteractionsTicksPerChange() async throws {
        let screen = LimitInteractionsViewController(manager: Limits())
        screen.loadViewIfNeeded()
        try #require(await settle { screen.debugIsLoaded })
        let played = ticks { next in
            screen.debugChooseAudience(.nonFollowers) // already chosen
            next()
            screen.debugChooseAudience(.recentFollowers)
        }
        #expect(played == [.tick], "\(played)")
    }

    @Test func verificationTicksPerChange() {
        let screen = VerificationRequestViewController(manager: Verifier(), onSubmitted: {})
        screen.loadViewIfNeeded()
        let played = ticks { next in
            screen.debugChoose(.official)
            next()
            screen.debugChoose(.official)
            next()
            screen.debugChoose(.business)
        }
        #expect(played == [.tick, .tick], "\(played)")
    }
}
