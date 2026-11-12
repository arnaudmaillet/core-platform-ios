import DesignSystem
import UIKit

/// What the mute toolbar shows: rebuilt only when this changes.
struct MuteLook: Equatable {
    var paused: Bool
    /// The trailing item's text; nil for the timer glyph.
    var timeLeft: String?
    /// A write on its way (#1775): the wide button's loader.
    var busy = false
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

    /// Lays the toolbar out for `shownPause` and arms the minute tick.
    ///
    /// ⚠️ ONLY THE ITEM THAT CHANGED MOVES (#2331): the items are kept by
    /// identifier (`BarItemStore`). The wide item takes its word, its glyph
    /// and its loader in place; the timer is re-minted under its identifier
    /// only when its text changes (a bar measures a NEW item only), which the
    /// bar animates (#1679). A save starting used to re-mint the timer too,
    /// and the bar blurred it out and back for nothing.
    func applyMuteToolbar() {
        guard let muteModel else { return }
        let now = muteModel.clock
        let look = MuteLook(
            paused: shownPause.isPaused, timeLeft: NotificationsMuteModel.timeLeft(shownPause, now: now), busy: isWritingMute
        )
        if look != shownMuteLook {
            let animated = view.window != nil && shownMuteLook != nil
            shownMuteLook = look
            let wide = muteBarStore.item(Self.muteWideIdentifier) {
                makeMuteWideItem()
            } update: { item in
                dressMuteWideItem(item, paused: look.paused, busy: look.busy)
            }
            let timer = muteBarStore.item(Self.muteTimerIdentifier, variant: look.timeLeft) {
                makeMuteTimerItem(look)
            }
            muteTimerItem = timer
            muteBarStore.apply(
                toolbar: [wide, muteBarStore.separator(before: Self.muteTimerIdentifier), timer], to: self,
                animated: animated
            )
        }
        if let timer = muteTimerItem {
            timer.accessibilityValue = NotificationsMuteModel.timeLeftForVoiceOver(shownPause, now: now)
        }
        scheduleMuteTick()
    }

    // MARK: Items

    /// The stretched item (`BarItems.stretched`): there is no flexible-width
    /// bar item and a `.prominent` title item's `width` is ignored on iOS 27.
    /// The bar draws its bubble (#1679). Made once; dressed by
    /// `dressMuteWideItem`.
    private func makeMuteWideItem() -> UIBarButtonItem {
        let made = BarItems.stretched(id: Self.muteWideIdentifier, title: "Mute") { [weak self] in
            self?.muteButtonTapped()
        }
        made.label.accessibilityIdentifier = "notifications.mute"
        muteButton = made.label
        return made.item
    }

    /// The glyph and the word say what a tap WILL do; the loader while a
    /// write is on its way (#1775). In place (#2331).
    private func dressMuteWideItem(_ item: UIBarButtonItem, paused: Bool, busy: Bool) {
        BarItems.update(
            stretched: item, title: paused ? "Unmute" : "Mute",
            image: UIImage(systemName: paused ? "bell" : "bell.slash"), busy: busy
        )
        item.customView?.accessibilityLabel = paused ? "Unmute notifications" : "Mute notifications for 8 hours"
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

    /// The bar keeps its old look while the write is on its way — its wide
    /// button wearing the loader (#1775) — and takes the new one the moment
    /// the server answers, with its toast (#2143). A refusal is a failure
    /// toast and the look stays (#802).
    private func write(_ target: PushPause) {
        guard let muteModel, !muteModel.isSaving, !isWritingMute else { return }
        setWritingMute(true)
        Task { [weak self] in
            do {
                let held = try await muteModel.set(target)
                guard let self else { return }
                shownPause = held
                setWritingMute(false)
                Feedback.success(
                    NotificationsMuteModel.confirmation(for: held, now: muteModel.clock),
                    symbol: held.isPaused ? "bell.slash.fill" : "bell.fill",
                    from: self
                )
            } catch is CancellationError {
                self?.setWritingMute(false)
            } catch {
                guard let self else { return }
                setWritingMute(false)
                Feedback.failure(NotificationsMuteModel.failure(muting: target.isPaused), from: self)
            }
        }
    }

    private func setWritingMute(_ writing: Bool) {
        isWritingMute = writing
        applyMuteToolbar()
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
    /// Whether the wide button wears the loader. Tests.
    var debugMuteButtonIsBusy: Bool { muteButton?.isBusy ?? false }
    #endif
}
