import CoreNavigation
import CoreStorage
import DesignSystem
import UIKit

/// The wallet sheet behind the balance badges (map and feed): the balance,
/// the claim streak, today's earning progress, and the Claim button — a
/// medium-detent page sheet (the map sub-filter organizer's presentation
/// grammar), because it is a glance-and-act surface, not a screen.
///
/// # Anatomy, top to bottom
///   • the balance header — coin, the FULL number (`formatted()`, not the
///     badges' compact spelling: this sheet is the wallet's ledger view),
///     and its unit;
///   • the STREAK CARD — the retention mechanic given a surface of its own
///     (an inline caption line kept reading as an afterthought): tinted
///     flame disc, count as a headline, and a subtitle that always says
///     what to DO next;
///   • today's earnings as a real progress bar against the daily cap;
///   • the CLAIM button — full-width and pinned to the sheet's bottom, the
///     one action anchored where a thumb already is. Enabled it names the
///     payout; locked it becomes the countdown.
///
/// Everything shown derives from one `WalletSnapshot` per refresh, so no two
/// labels can disagree; the only per-second work is rewriting the locked
/// button's countdown string from the snapshot's `nextClaimAt`, never
/// re-deriving claimability locally (the store owns that answer).
final class WalletClaimViewController: UIViewController {
    private let wallet: WalletStore

    private let coinView = UIImageView()
    private let balanceLabel = UILabel()
    private let balanceCaptionLabel = UILabel()

    private let streakCard = UIView()
    private let streakIconCircle = UIView()
    private let streakIconView = UIImageView()
    private let streakTitleLabel = UILabel()
    private let streakSubtitleLabel = UILabel()

    private let earnedTitleLabel = UILabel()
    private let earnedValueLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    /// Recreated on every refresh — a multiplier can't be edited in place.
    private var progressFillWidth: NSLayoutConstraint?

    private let claimButton = UIButton(configuration: .prominentGlass())

    /// Ticks the countdown once a second while a claim is locked. Weak-self
    /// scheduled, and torn down in `viewWillDisappear` — which every
    /// dismissal path visits before release, so no deinit teardown is
    /// needed (a nonisolated deinit couldn't touch it anyway).
    private var countdownTimer: Timer?
    /// Unregisters the store observer on release — a nonisolated deinit
    /// cannot touch main-actor state, so the token lives in a bag whose own
    /// deinit does the unregistering (the comments composer's pattern).
    private let walletObservers = WalletObserverTokenBag()

    private enum Metrics {
        static let sideMargin: CGFloat = Spacing.lg
        static let cardCorner: CGFloat = 16
        static let iconDisc: CGFloat = 44
        static let progressHeight: CGFloat = 8
        static let claimHeight: CGFloat = 52
        /// The sheet is content-sized, not `.medium()`: the medium detent
        /// left a band of dead space between the progress bar and the
        /// bottom-pinned button on tall devices. `detentBase` is the
        /// measured anatomy above the button margin (header → card →
        /// progress → button); the final height adds the device-derived
        /// button margin — revisit the base if a section is added.
        static let detentBase: CGFloat = 340
        /// The pre-attach fallback for the sheet corner (and thus the
        /// button margin): capsule + lg. One layout pass later the REAL
        /// device radius replaces it (`applyDeviceCornerRadius`).
        static var fallbackSheetCorner: CGFloat { claimHeight / 2 + sideMargin }
    }

    /// The button's edge constraints, retuned once the device radius is
    /// known (constants can move; the constraints stay).
    private var buttonLeading: NSLayoutConstraint?
    private var buttonTrailing: NSLayoutConstraint?
    private var buttonBottom: NSLayoutConstraint?
    /// The sheet radius currently applied, so the layout hook is idempotent.
    private var appliedSheetRadius: CGFloat = 0

    init(wallet: WalletStore) {
        self.wallet = wallet
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom { _ in Metrics.detentBase + Metrics.sideMargin }]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = Metrics.fallbackSheetCorner
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()

        // Another surface can spend while this sheet is up (it can't today —
        // the sheet covers them — but the observation costs nothing and the
        // invariant is worth stating: the sheet renders the store, always).
        walletObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: WalletStore.didChangeNotification, object: wallet, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()

        #if DEBUG
        // `-wallet-demo-claim`: fires the Claim button ~1.5s after the sheet
        // loads — the real claim path minus the finger. Pair with
        // `-open-wallet -wallet-claim-ready`.
        if ProcessInfo.processInfo.arguments.contains("-wallet-demo-claim") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.claimTapped()
            }
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCountdownTimer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyDeviceCornerRadius()
    }

    /// Gives the sheet THE DEVICE'S own corner radius, and re-derives the
    /// button's nest from it — margin = device radius − capsule radius, on
    /// all three edges, so the pill stays perfectly concentric with the
    /// sheet's corners whatever screen this runs on. Runs from layout
    /// because `ScreenGeometry` reads the radius off the WINDOW's screen
    /// (nil before attach); idempotent past the first real answer.
    private func applyDeviceCornerRadius() {
        guard view.window != nil, let sheet = sheetPresentationController else { return }
        let device = ScreenGeometry.cornerRadius(behind: view)
        guard device > 0, abs(device - appliedSheetRadius) > 0.5 else { return }
        appliedSheetRadius = device
        let margin = max(Metrics.sideMargin, device - Metrics.claimHeight / 2)
        sheet.preferredCornerRadius = device
        buttonLeading?.constant = margin
        buttonTrailing?.constant = -margin
        buttonBottom?.constant = -margin
        sheet.detents = [.custom { _ in Metrics.detentBase + margin }]
        sheet.invalidateDetents()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - Layout

    private func buildLayout() {
        // — Balance header —
        // The points token: a gold STAR, deliberately not a currency glyph —
        // the balance is app points, and a dollar sign promises money the
        // product doesn't hold (the badges wear the same star).
        let palette = UIImage.SymbolConfiguration(paletteColors: [.white, .systemYellow])
            .applying(UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold))
        coinView.image = UIImage(systemName: "star.circle.fill", withConfiguration: palette)?
            .withRenderingMode(.alwaysOriginal)
        coinView.tintColor = .systemYellow
        coinView.contentMode = .center

        balanceLabel.font = .monospacedDigitSystemFont(ofSize: 46, weight: .bold)
        balanceLabel.textColor = .label
        balanceLabel.adjustsFontSizeToFitWidth = true
        balanceLabel.minimumScaleFactor = 0.6

        balanceCaptionLabel.text = "points"
        balanceCaptionLabel.font = .systemFont(ofSize: 15, weight: .medium)
        balanceCaptionLabel.textColor = .secondaryLabel

        let header = UIStackView(arrangedSubviews: [coinView, balanceLabel, balanceCaptionLabel])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = Spacing.xs
        header.setCustomSpacing(Spacing.sm, after: coinView)

        // — Streak card —
        streakCard.backgroundColor = .secondarySystemBackground
        streakCard.layer.cornerRadius = Metrics.cardCorner
        streakCard.layer.cornerCurve = .continuous

        streakIconCircle.layer.cornerRadius = Metrics.iconDisc / 2
        streakIconView.contentMode = .center

        streakTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        streakTitleLabel.textColor = .label
        streakSubtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        streakSubtitleLabel.textColor = .secondaryLabel
        streakSubtitleLabel.numberOfLines = 2

        let streakText = UIStackView(arrangedSubviews: [streakTitleLabel, streakSubtitleLabel])
        streakText.axis = .vertical
        streakText.alignment = .leading
        streakText.spacing = 2

        streakIconView.translatesAutoresizingMaskIntoConstraints = false
        streakIconCircle.addSubview(streakIconView)
        NSLayoutConstraint.activate([
            streakIconView.centerXAnchor.constraint(equalTo: streakIconCircle.centerXAnchor),
            streakIconView.centerYAnchor.constraint(equalTo: streakIconCircle.centerYAnchor),
            streakIconCircle.widthAnchor.constraint(equalToConstant: Metrics.iconDisc),
            streakIconCircle.heightAnchor.constraint(equalToConstant: Metrics.iconDisc),
        ])

        let streakRow = UIStackView(arrangedSubviews: [streakIconCircle, streakText])
        streakRow.axis = .horizontal
        streakRow.alignment = .center
        streakRow.spacing = Spacing.md
        streakRow.translatesAutoresizingMaskIntoConstraints = false
        streakCard.addSubview(streakRow)
        NSLayoutConstraint.activate([
            streakRow.leadingAnchor.constraint(equalTo: streakCard.leadingAnchor, constant: Spacing.lg),
            streakRow.trailingAnchor.constraint(lessThanOrEqualTo: streakCard.trailingAnchor, constant: -Spacing.lg),
            streakRow.topAnchor.constraint(equalTo: streakCard.topAnchor, constant: Spacing.md),
            streakRow.bottomAnchor.constraint(equalTo: streakCard.bottomAnchor, constant: -Spacing.md),
        ])

        // — Today's earnings —
        earnedTitleLabel.text = "Earned today"
        earnedTitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        earnedTitleLabel.textColor = .secondaryLabel
        earnedValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        earnedValueLabel.textColor = .label

        let earnedRow = UIStackView(arrangedSubviews: [earnedTitleLabel, UIView(), earnedValueLabel])
        earnedRow.axis = .horizontal
        earnedRow.alignment = .firstBaseline

        progressTrack.backgroundColor = .quaternarySystemFill
        progressTrack.layer.cornerRadius = Metrics.progressHeight / 2
        progressFill.backgroundColor = .systemYellow
        progressFill.layer.cornerRadius = Metrics.progressHeight / 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        NSLayoutConstraint.activate([
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: Metrics.progressHeight),
        ])

        // — Claim button, pinned to the sheet's bottom, full width —
        // A CAPSULE, sharing the sheet's side margins: the pill's fully
        // round ends read as concentric with the sheet's own rounded
        // corners, where a squarer radius visibly fought them.
        claimButton.configuration?.cornerStyle = .capsule
        claimButton.addAction(UIAction { [weak self] _ in self?.claimTapped() }, for: .primaryActionTriggered)

        for subview in [header, streakCard, earnedRow, progressTrack, claimButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // One rhythm: `lg` between sections, `lg` side margins everywhere —
        // the content-sized detent removes the dead band the `.medium()`
        // height used to leave above the button.
        let margins = Metrics.sideMargin
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.lg),
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: margins),

            streakCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Spacing.lg),
            streakCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margins),
            streakCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margins),

            earnedRow.topAnchor.constraint(equalTo: streakCard.bottomAnchor, constant: Spacing.lg),
            earnedRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margins),
            earnedRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margins),

            progressTrack.topAnchor.constraint(equalTo: earnedRow.bottomAnchor, constant: Spacing.sm),
            progressTrack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margins),
            progressTrack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margins),

            claimButton.topAnchor.constraint(
                greaterThanOrEqualTo: progressTrack.bottomAnchor, constant: Spacing.lg
            ),
            claimButton.heightAnchor.constraint(equalToConstant: Metrics.claimHeight),
        ])
        // The pill's nest: three equal edges against the sheet's REAL
        // borders (not the safe area — iOS 26 sheets float clear of the
        // home indicator and its inset varies per device). Constants are
        // retuned to `deviceRadius − capsuleRadius` once the window can
        // answer what the device's radius is (`applyDeviceCornerRadius`).
        let leading = claimButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margins)
        let trailing = claimButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margins)
        let bottom = claimButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margins)
        NSLayoutConstraint.activate([leading, trailing, bottom])
        buttonLeading = leading
        buttonTrailing = trailing
        buttonBottom = bottom
    }

    // MARK: - State

    private func refresh() {
        let snapshot = wallet.snapshot()

        // The FULL number, deliberately unlike every badge: the sheet is
        // the wallet's ledger view, and "100 000" is the honest reading
        // here while the toolbar's "100K" stays glanceable.
        balanceLabel.text = snapshot.balance.formatted()

        applyStreak(snapshot)

        earnedValueLabel.text = "\(snapshot.claimedToday) / \(snapshot.dailyClaimCap)"
        let fraction = snapshot.dailyClaimCap > 0
            ? min(1, CGFloat(snapshot.claimedToday) / CGFloat(snapshot.dailyClaimCap)) : 0
        progressFillWidth?.isActive = false
        // A zero fraction still shows a dot-width sliver of track only —
        // multiplier 0 is a valid constraint, the capsule just vanishes.
        progressFillWidth = progressFill.widthAnchor.constraint(
            equalTo: progressTrack.widthAnchor, multiplier: fraction
        )
        progressFillWidth?.isActive = true

        applyClaimButtonState(snapshot)
    }

    /// The streak card's three faces: no streak yet (invitation), an alive
    /// chain already fed today (kept), an alive chain not yet fed (urgent).
    /// Every face SAYS WHAT TO DO — a retention surface that only states a
    /// number is furniture.
    private func applyStreak(_ snapshot: WalletSnapshot) {
        let active = snapshot.streakDays > 0
        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        streakIconView.image = UIImage(systemName: active ? "flame.fill" : "flame", withConfiguration: symbol)?
            .withTintColor(active ? .systemOrange : .secondaryLabel, renderingMode: .alwaysOriginal)
        streakIconCircle.backgroundColor = active
            ? UIColor.systemOrange.withAlphaComponent(0.15)
            : UIColor.quaternarySystemFill

        if !active {
            streakTitleLabel.text = "Start a streak"
            streakSubtitleLabel.text = "Claim once a day to build a bonus — up to ×2 per claim."
        } else if snapshot.claimedToday > 0 {
            streakTitleLabel.text = "\(snapshot.streakDays)-day streak"
            streakSubtitleLabel.text = "Kept for today — come back tomorrow to make it \(snapshot.streakDays + 1)."
        } else {
            streakTitleLabel.text = "\(snapshot.streakDays)-day streak"
            streakSubtitleLabel.text = "Claim today to keep it going."
        }
    }

    private func applyClaimButtonState(_ snapshot: WalletSnapshot) {
        claimButton.isEnabled = snapshot.claimAvailable
        var title: AttributedString
        if snapshot.claimAvailable {
            title = AttributedString("Claim \(snapshot.claimAmount) points")
        } else if snapshot.claimedToday >= snapshot.dailyClaimCap, let next = snapshot.nextClaimAt {
            title = AttributedString("Daily cap reached — resets in \(Self.countdownString(to: next))")
        } else if let next = snapshot.nextClaimAt {
            title = AttributedString("Next claim in \(Self.countdownString(to: next))")
        } else {
            title = AttributedString("Claim")
        }
        title.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        claimButton.configuration?.attributedTitle = title
    }

    private func claimTapped() {
        switch wallet.claim() {
        case .claimed:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Explicit refresh, not the notification observer's: the
            // observer rides an OperationQueue hop whose timing is UIKit's
            // business, and the pop below must scale the NEW number.
            refresh()
            balanceLabel.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            UIView.animate(
                withDuration: 0.5, delay: 0,
                usingSpringWithDamping: 0.5, initialSpringVelocity: 2
            ) {
                self.balanceLabel.transform = .identity
            }
        case .tooEarly, .dailyCapReached:
            // The button should have been disabled; the store said no, so
            // render the state that refused (device clock moved, cap landed).
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            refresh()
        }
    }

    // MARK: - Countdown

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snapshot = self.wallet.snapshot()
                // Flip-to-available needs a full refresh (button enables);
                // otherwise only the countdown string moves.
                self.applyClaimButtonState(snapshot)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// "42:07" under an hour, "3h 12m" above it (the cap's reset spans
    /// hours; a five-digit second counter is noise at that range).
    private static func countdownString(to date: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        if remaining >= 3600 {
            return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
        }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

/// Holds notification tokens and unregisters them on its own deallocation
/// (when the owning sheet is released). `@unchecked Sendable` so its deinit
/// may run off the main actor; `removeObserver` is itself thread-safe, and
/// the tokens are only written on the main actor at setup time. The comments
/// composer carries the identical bag for the identical reason — App-shell
/// code can't reach that internal type, so the shape is replicated here.
/// `nonisolated`, because the App target's default-MainActor isolation would
/// otherwise pin `tokens` to the main actor and put it out of deinit's reach.
private nonisolated final class WalletObserverTokenBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
