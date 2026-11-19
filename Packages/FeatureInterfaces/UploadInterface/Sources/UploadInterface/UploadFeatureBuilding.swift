import CoreModels
import MediaPlayback
import UIKit

/// Entry point contract for the Upload feature (#2375): the screens behind
/// the tab bar's "+" menu — Camera, Upload Media and Text Post — and a
/// channel's "Share as a Post". The shell depends on this interface; the
/// composition root builds Upload's `UploadFeatureBuilder` behind it.
@MainActor
public protocol UploadFeatureBuilding {
    /// "Upload Media": photos and videos from the library, full screen.
    func makeMediaUploadViewController() -> UIViewController

    /// "Camera": a photograph or a video captured here, full screen.
    /// `soundtrack` is a sound chosen before the camera opened ("Use this
    /// sound" on a post), laid under every clip the author takes.
    func makeCameraViewController(soundtrack: VideoSoundtrack?) -> UIViewController

    /// "Text Post": a post with no media, written on its own page.
    func makeTextPostViewController() -> UIViewController

    /// "Share as a Post" on a channel (#2216): the Text Post screen with
    /// `embed` attached.
    func makeShowcaseComposer(attaching embed: PostEmbed) -> UIViewController
}
