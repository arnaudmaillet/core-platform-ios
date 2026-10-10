import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Profile

/// A copy has no evidence on screen, so it says so (#803): the backup codes'
/// Copy used to be a vibration alone.
@MainActor
struct CopyConfirmationTests {
    private static func toast(in view: UIView) -> ToastView? {
        if let toast = view as? ToastView { return toast }
        return view.subviews.lazy.compactMap { toast(in: $0) }.first
    }

    @Test func copyingTheBackupCodesShowsACopiedToast() {
        let codes = BackupCodes(codes: ["aaaaa-bbbbb", "ccccc-ddddd"], sessionsSignedOut: 0)
        let screen = BackupCodesViewController(codes: codes, onDone: {})
        // ⚠️ Never the general pasteboard here: in the test host it blocked
        // the main actor until the run's time limit.
        var copied: [String] = []
        screen.copyToPasteboard = { copied.append($0) }
        screen.loadViewIfNeeded()
        #expect(Self.toast(in: screen.view) == nil)

        // The Copy row: the first of the actions section.
        screen.collectionView(
            UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()),
            didSelectItemAt: IndexPath(item: 0, section: 1)
        )

        #expect(copied == [BackupCodesViewController.plainText(codes)])
        #expect(Self.toast(in: screen.view)?.style == .confirmation, "the copy said nothing")
    }
}
