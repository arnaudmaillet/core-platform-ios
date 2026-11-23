import UIKit

/// The microphone's Settings offer (#2102), one for every voice composer
/// (#2533): the conversation's, the comments' and the Text Post page's.
/// Once access is refused, a hold raises the same alert everywhere; only
/// its message says what the voice records.
extension VoiceComposer {
    /// Presents `microphoneSettingsAlert(message:)` from `presenter` each
    /// time a hold meets a refused microphone. Replaces `onPermissionDenied`.
    public func offersMicrophoneSettings(from presenter: UIViewController, message: String) {
        onPermissionDenied = { [weak presenter] in
            presenter?.present(VoiceComposer.microphoneSettingsAlert(message: message), animated: true)
        }
    }

    /// "Microphone Access" with `message`, "Not Now", and "Open Settings",
    /// which opens the app's page in Settings.
    public static func microphoneSettingsAlert(message: String) -> UIAlertController {
        let alert = UIAlertController(title: "Microphone Access", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        return alert
    }
}
