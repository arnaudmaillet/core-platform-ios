#if DEBUG
import UIKit

// MARK: - QA hooks
//
// The launch-argument hooks that drive the screen (`-upload-post`,
// `-upload-category`, `-upload-seed-cuts`) and the `debug*` accessors stay in
// `MediaEditorViewController.swift`: they reach this screen's private state,
// which a file of its own could only reach by widening it. What lives here
// needs none of it.

extension MediaEditorViewController {
    /// The value after a flag, `-upload-category 3` style.
    ///
    /// ⚠️ **THE PICKER'S `debugArgument` IS PRIVATE TO IT**, so this is stated
    /// here rather than reached for. Two small readers beat widening a seam for
    /// a DEBUG convenience.
    static func debugValue(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Where the canvas actually IS, behind `-upload-log-sheet`.
    ///
    /// ⚠️ **TWO CAUSES LOOK IDENTICAL IN A SCREENSHOT AND NEED OPPOSITE FIXES:**
    /// a canvas laid out BETWEEN the bars, or a canvas running the full sheet
    /// under bars that paint over it. Both show a picture that stops at the
    /// chrome. Two rounds were spent guessing between them — transparent bar
    /// appearances, then `extendedLayoutIncludesOpaqueBars` — and neither moved
    /// a pixel. These are the numbers that tell them apart: if the CELL spans
    /// the sheet, the bars are painting; if it stops short, the layout is.
    func logCanvas(_ moment: String) {
        guard ProcessInfo.processInfo.arguments.contains("-upload-log-sheet") else { return }
        let bar = navigationController?.navigationBar
        let foot = navigationController?.toolbar
        let cell = canvas.cellForItem(at: IndexPath(item: 0, section: 0))
        print("""
        [editor \(moment)] \
        window=\(view.window?.bounds.size.debugDescription ?? "nil") \
        view=\(view.frame) safeArea=\(view.safeAreaInsets) \
        canvas=\(canvas.frame) inset=\(canvas.contentInset) adjusted=\(canvas.adjustedContentInset) \
        cell=\(cell?.frame.debugDescription ?? "nil") \
        navBar=\(bar?.frame.debugDescription ?? "nil") barTranslucent=\(bar?.isTranslucent.description ?? "nil") \
        toolbar=\(foot?.frame.debugDescription ?? "nil") footTranslucent=\(foot?.isTranslucent.description ?? "nil") \
        extendedOpaque=\(extendedLayoutIncludesOpaqueBars) edges=\(edgesForExtendedLayout.rawValue)
        """)
    }
}
#endif
