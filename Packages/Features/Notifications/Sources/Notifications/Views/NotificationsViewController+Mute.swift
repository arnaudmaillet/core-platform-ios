import DesignSystem
import UIKit

/// What the mute toolbar shows: rebuilt only when this changes.
struct MuteLook: Equatable {
    var paused: Bool
    /// The trailing item's text; nil for the timer glyph.
    var timeLeft: String?
}

// MARK: - The mute toolbar (#1575)

/// ```
/// not muted   [ ——— bell.slash  Mute ——— ][ timer ]
/// muted       [ ——— bell  Unmute ——— ][ 7 h 42 ]
/// ```
/// See `NotificationsMuteModel` for what each control does.
extension NotificationsViewController {
    /// One slot each across re-mints: the bar morphs the items in place.
    static let muteWideIdentifier = "notifications.mute"
    static let muteTimerIdentifier = "notifications.mute.timer"

    func installMuteToolbar() {
        guard let muteModel else { return }
        muteModel.onExpire = { [weak self] in
            // The pause ran out with the screen open: no toast, the bar
            // simply says "Mute" again.
            guard let self else { return }
            shownPause = .off
            applyMuteToolbar()
        }
        applyMuteToolbar()
    }

    /// Every visit: the toolbar up, and the preference read again — Settings
    /// may have changed it.
    func showMuteToolbar() {
        guard let muteModel else { return }
        navigationController?.setToolbarHidden(false, animated: false)
        Task { [weak self] in
            let read = await muteModel.load()
            guard let self, !muteModel.isSaving else { return }
            shownPause = read
            applyMuteToolbar()
        }
    }

    /// Lays the toolbar out for `shownPause`, re-minting an item whenever
    /// what it says changes — the timer's text (a bar measures a NEW item
    /// only), the wide item's word and glyph — under the same identifiers,
    /// so the bar animates the change itself (#1679), and arms the minute
    /// tick.
    func applyMuteToolbar() {
        guard let muteModel else { return }
        let now = muteModel.clock
        let look = MuteLook(paused: shownPause.isPaused, timeLeft: NotificationsMuteModel.timeLeft(shownPause, now: now))
        if look != shownMuteLook {
            let shown = toolbarItems?.first { $0.identifier == Self.muteWideIdentifier }
            let kept = look.paused == shownMuteLook?.paused ? shown : nil
            let animated = view.window != nil && shown != nil
            shownMuteLook = look
            let wide = kept ?? makeMuteWideItem(paused: look.paused)
            let timer = makeMuteTimerItem(look)
            muteTimerItem = timer
            setToolbarItems([wide, .fixedSpace(), timer], animated: animated)
        }
        if let timer = muteTimerItem {
            timer.accessibilityValue = NotificationsMuteModel.timeLeftForVoiceOver(shownPause, now: now)
        }
        scheduleMuteTick()
    }

    // MARK: Items

    /// The stretched item (`BarItems.stretched`): there is no flexible-width
    /// bar item and a `.prominent` title item's `width` is ignored on iOS 27.
    /// The bar draws its bubble (#1679). The glyph and the word say what a
    /// tap WILL do.
    private func makeMuteWideItem(paused: Bool) -> UIBarButtonItem {
        let made = BarItems.stretched(
            id: Self.muteWideIdentifier,
            title: paused ? "Unmute" : "Mute",
            image: UIImage(systemName: paused ? "bell" : "bell.slash")
        ) { [weak self] in self?.muteButtonTapped() }
        made.label.accessibilityIdentifier = "notifications.mute"
        made.label.accessibilityLabel = paused ? "Unmute notifications" : "Mute notifications for 8 hours"
        muteButton = made.label
        return made.item
    }

    /// The timer glyph, or the time left; it always opens the menu.
    private func makeMuteTimerItem(_ look: MuteLook) -> UIBarButtonItem {
        let menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.muteMenuElements() ?? [])
        }])
        let item: UIBarButtonItem
        if let text = look.timeLeft {
            item = UIBarButtonItem(title: text, menu: menu)
        } else {
            item = UIBarButtonItem(image: UIImage(systemName: "timer"), menu: menu)
        }
        item.identifier = Self.muteTimerIdentifier
        item.accessibilityLabel = "Mute duration"
        return item
    }

    /// Built as the menu opens: "adding" reads the deadline at that moment.
    func muteMenuElements() -> [UIMenuElement] {
        guard let muteModel else { return [] }
        let adding: Bool = if case .until = muteModel.pause { true } else { false }
        var rows: [UIMenuElement] = muteModel.choices.map { choice in
            let title = adding && choice.duration != nil ? "Add \(choice.title)" : choice.title
            return UIAction(title: title, image: UIImage(systemName: choice.duration == nil ? "infinity" : "clock")) {
                [weak self] _ in self?.muteChoiceTapped(choice)
            }
        }
        if rows.isEmpty {
            // Without backend #971 nothing can be added past 8 h: say so
            // rather than offer a row that fails.
            rows = [UIAction(title: "8 Hours Is the Longest Pause for Now", attributes: .disabled) { _ in }]
        }
        return [UIMenu(title: adding ? "Add Time" : "Mute For", options: .displayInline, children: rows)]
    }

    // MARK: Taps

    private func muteButtonTapped() {
        guard let muteModel else { return }
        write(muteModel.mainTarget())
    }

    func muteChoiceTapped(_ choice: NotificationsMuteModel.Choice) {
        guard let muteModel else { return }
        write(muteModel.target(for: choice))
    }

    /// #1447's order: the bar keeps its old look while the write is on its
    /// way; the toast's reveal hands it the new one. A refusal is a failure
    /// toast and the look stays (#802).
    private func write(_ target: PushPause) {
        guard let muteModel, !muteModel.isSaving else { return }
        Task { [weak self] in
            do {
                let held = try await muteModel.set(target)
                guard let self else { return }
                Feedback.success(
                    NotificationsMuteModel.confirmation(for: held, now: muteModel.clock),
                    symbol: held.isPaused ? "bell.slash.fill" : "bell.fill",
                    from: self,
                    revealing: { [weak self] in
                        self?.shownPause = held
                        self?.applyMuteToolbar()
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                Feedback.failure(NotificationsMuteModel.failure(muting: target.isPaused), from: self)
            }
        }
    }

    // MARK: The minute tick

    private func scheduleMuteTick() {
        muteTick?.invalidate()
        muteTick = nil
        guard viewIfLoaded?.window != nil, let delay = muteModel?.nextTick() else { return }
        muteTick = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.muteModel else { return }
                model.tick()
                self.applyMuteToolbar()
            }
        }
    }

    func stopMuteTick() {
        muteTick?.invalidate()
        muteTick = nil
    }

    #if DEBUG
    /// The timer item's text, nil for the glyph. Tests.
    var debugMuteTimerText: String? { muteTimerItem?.title }
    /// The wide button's word. Tests.
    var debugMuteButtonTitle: String? { muteButton?.title }
    #endif
}
