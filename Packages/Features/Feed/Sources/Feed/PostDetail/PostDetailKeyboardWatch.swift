import CoreModels
import ThreadKit
import UIKit

/// What the keyboard watch asks of its panel (#2523): the streams whose
/// empty page and bottom anchor follow the keyboard.
///
/// A view controller: its view hears only the keyboards aimed at its
/// window, and measures the cover against that window's screen.
@MainActor
protocol PostDetailKeyboardWatchHost: UIViewController {
    var streams: [CommentStream] { get }
}

/// The keyboard's height for the empty page, out of
/// `PostDetailViewController` (#2523): three observers, and the streams
/// re-fitted as the keyboard comes, moves and goes.
@MainActor
final class PostDetailKeyboardWatch {
    private unowned let host: any PostDetailKeyboardWatchHost

    init(host: any PostDetailKeyboardWatchHost) {
        self.host = host
    }

    /// How much of the screen's bottom the keyboard covers while it is up,
    /// nil when it is down.
    ///
    /// ⚠️ A HEIGHT, NEVER A CONVERTED POSITION. The sheet grows to its large
    /// height FOR the keyboard, so this view is moving while the keyboard is:
    /// converting the keyboard's frame into this view's coordinates answered
    /// 520 where the truth was 377 — measured — and the invitation then sat
    /// as though no keyboard were up. A height needs no coordinate space, and
    /// the composer's own ceiling is anchored to the screen the same way (see
    /// `setEngagedInsets`).
    ///
    /// Read from the notification's END frame rather than from
    /// `keyboardLayoutGuide`: the guide only reaches that value as the
    /// keyboard finishes animating, and the empty page is fitted once, to
    /// where things are going.
    private(set) var keyboardHeightFromBottom: CGFloat?
    private let keyboardObservers = NotificationTokens()

    func observeKeyboardForEmptyPage() {
        let center = NotificationCenter.default
        keyboardObservers.replace(with: [
            // The frame is read out here: a `Notification` cannot cross into
            // the main actor's isolation, and a `CGRect` can.
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let scope = KeyboardNotificationScope.window(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.host.view.hearsKeyboard(aimedAt: scope) else { return }
                    self.keyboardIsMoving(endingAt: frame)
                }
            },
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let scope = KeyboardNotificationScope.window(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.host.view.hearsKeyboard(aimedAt: scope) else { return }
                    self.keyboardIsMoving(endingAt: frame)
                }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
                let scope = KeyboardNotificationScope.window(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.host.view.hearsKeyboard(aimedAt: scope) else { return }
                    self.keyboardWentDown()
                }
            },
        ])
    }

    private func keyboardIsMoving(endingAt frame: CGRect?) {
        guard let window = host.view.window, let frame else { return }
        let covered = max(0, window.screen.bounds.maxY - frame.minY)
        guard keyboardHeightFromBottom != covered else { return }
        keyboardHeightFromBottom = covered
        // A short stream rises with the composer's input row (#1799).
        host.streams.forEach {
            $0.refitEmptyPage()
            $0.syncBottomAnchor(animated: true)
        }
    }

    private func keyboardWentDown() {
        guard keyboardHeightFromBottom != nil else { return }
        keyboardHeightFromBottom = nil
        host.streams.forEach {
            $0.refitEmptyPage()
            $0.syncBottomAnchor(animated: true)
        }
    }
}

extension PostDetailViewController: PostDetailKeyboardWatchHost {}
