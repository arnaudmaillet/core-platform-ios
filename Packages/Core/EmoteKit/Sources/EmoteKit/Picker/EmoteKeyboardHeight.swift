import UIKit

/// The height of the system keyboard the emote panel stands in for — so the
/// composer riding the keyboard does not move when the smiley swaps one for
/// the other.
///
/// ## Where the number comes from
///
/// The keyboard's own frame notifications. Every time the SYSTEM keyboard
/// settles docked at the bottom of the screen, its height is kept, per screen
/// width (a portrait and a landscape keyboard differ, and a width names an
/// orientation on any one device), and persisted: the next launch opens the
/// panel at the right height before any keyboard has been shown.
///
/// Frames that are not the system keyboard's are ignored:
/// - **the panel's own**: while an `EmoteKeyboard` shows its panel, the frame
///   the system reports IS the panel (a panel sized from a default would
///   otherwise record its own guess);
/// - **undocked or leaving**: an end frame not reaching the screen's bottom,
///   or wholly below it;
/// - **a hardware keyboard's bar**: a docked frame shorter than
///   `minimumPlausibleHeight` is the shortcut bar a connected keyboard leaves,
///   not a keyboard; a panel that small would hold one row.
///
/// Until a width has been measured, `defaultHeight(screenSize:bottomInset:)`:
/// the stock iPhone keyboard with its suggestion bar.
@MainActor
final class EmoteKeyboardHeight {
    static let shared = EmoteKeyboardHeight(defaults: .standard)

    /// Shorter than this, a docked "keyboard" is a hardware keyboard's
    /// shortcut bar.
    static let minimumPlausibleHeight: CGFloat = 150

    private static let storageKey = "emote.keyboardHeight.v1"

    private let defaults: UserDefaults
    /// Measured heights, keyed by the screen width they were measured at.
    private var heights: [Int: CGFloat]
    private var observing = false
    /// Keyboards whose panel may be up: their frames are not the system's.
    private let keyboards = NSHashTable<EmoteKeyboard>.weakObjects()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: Double] ?? [:]
        heights = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Int(key).map { ($0, CGFloat(value)) }
        })
    }

    /// Starts listening (once), and learns `keyboard`, whose panel frames must
    /// not be taken for the system keyboard's.
    func track(_ keyboard: EmoteKeyboard) {
        keyboards.add(keyboard)
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidShowNotification] {
            center.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)), name: name, object: nil)
        }
    }

    /// The panel's height on a screen of `screenSize` whose bottom safe-area
    /// inset is `bottomInset`: the keyboard measured at that width, else the
    /// device default.
    func height(screenSize: CGSize, bottomInset: CGFloat) -> CGFloat {
        heights[Self.key(screenSize.width)] ?? Self.defaultHeight(screenSize: screenSize, bottomInset: bottomInset)
    }

    /// The measured height for a screen width, if any.
    func measuredHeight(screenWidth: CGFloat) -> CGFloat? {
        heights[Self.key(screenWidth)]
    }

    /// Keeps `frame` (screen coordinates) as the keyboard's height if it is a
    /// docked system keyboard on `screen`. Returns whether it was kept.
    @discardableResult
    func record(endFrame frame: CGRect, screen: CGRect) -> Bool {
        guard !keyboards.allObjects.contains(where: \.isShowingPanel) else { return false }
        guard frame.minY < screen.maxY - 1,
              abs(frame.maxY - screen.maxY) < 1,
              frame.height >= Self.minimumPlausibleHeight,
              frame.width >= screen.width - 1
        else { return false }
        let key = Self.key(screen.width)
        let height = (frame.height * 2).rounded() / 2
        guard heights[key] != height else { return true }
        heights[key] = height
        defaults.set(
            Dictionary(uniqueKeysWithValues: heights.map { (String($0.key), Double($0.value)) }),
            forKey: Self.storageKey
        )
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    /// Posted when a measured height changed — a panel on screen resizes.
    static let didChange = Notification.Name("EmoteKeyboardHeightDidChange")

    /// ⚠️ NONISOLATED: keyboard notifications arrive on the main thread, but
    /// a main-actor selector would still trap on the isolation check if one
    /// ever did not.
    @objc nonisolated private func keyboardFrameWillChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let screen = note.object as? UIScreen
        MainActor.assumeIsolated {
            guard let bounds = screen?.bounds ?? Self.anyScreenBounds() else { return }
            record(endFrame: frame, screen: bounds)
        }
    }

    private static func anyScreenBounds() -> CGRect? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
    }

    private static func key(_ width: CGFloat) -> Int { Int(width.rounded()) }

    /// The stock iPhone keyboard (letters and the suggestion bar) where none
    /// has been measured yet. MEASURED on the iOS 27 simulator (iPhone 18 Pro,
    /// 402 pt wide, 27 September 2026): 328 pt in portrait, of which 34 is the
    /// home-indicator inset. The other shapes are estimates the first real
    /// keyboard replaces: a Touch ID phone has no inset and a shorter keyboard
    /// (260), a Max-width phone a slightly taller one, landscape a shallower one.
    static func defaultHeight(screenSize: CGSize, bottomInset: CGFloat) -> CGFloat {
        let landscape = screenSize.width > screenSize.height
        if landscape {
            return (bottomInset > 0 ? 188 : 194) + bottomInset
        }
        let body: CGFloat = bottomInset > 0 ? 294 : 260
        let wide: CGFloat = screenSize.width >= 428 ? 10 : 0
        return body + wide + bottomInset
    }
}
