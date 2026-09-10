import DesignSystem
import UIKit

/// Whether the For You selector rides the BOTTOM of the screen instead of the
/// navigation bar, and how it is dressed while it is still a spike.
///
/// ⚠️ A SPIKE, BEHIND A FLAG. In Release `isRequested` is a literal `false`, so
/// the optimiser drops every branch and the arrangement that ships is
/// unchanged. Stage 2 of the selector migration deletes this type and makes the
/// accessory the only path.
///
/// The MECHANISM moved to `DesignSystem.SelectorAccessory` — Chat and Profile
/// need it too and cannot import Feed. What is left here is only the spike's
/// own switches.
enum ForYouSelectorDock {
    /// `-foryou-dock-selector`: the strip moves to a `UITabAccessory`.
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-selector")
        #else
        false
        #endif
    }

    /// `-foryou-dock-empty`: an EMPTY content view, keeping the bubble UIKit
    /// draws around it.
    ///
    /// ⚠️ THIS IS THE ONLY THING THAT SEPARATED "UIKIT DOES NOT ANIMATE THE
    /// CONTAINER" FROM "OUR CONTENT IS WHAT LAGS", and the answer it gave is
    /// recorded on `SelectorAccessory.animatesCatchUp`: in the simulator NOT
    /// ONE view between the accessory and the window carries an animation, and
    /// on a device the accessory animates by itself.
    static var isEmpty: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-empty")
        #else
        false
        #endif
    }

    /// `-foryou-dock-glass`: the strip keeps its own capsule rather than
    /// rendering bare inside UIKit's.
    static var keepsOwnGlass: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-glass")
        #else
        false
        #endif
    }

    /// `-foryou-dock-catchup`: hand-animate the geometry change.
    ///
    /// ⚠️ OFF, AND IT MUST STAY OFF. On a device it fights a real animation; in
    /// the simulator it IS the instability it was written to cure. It is a
    /// comparison instrument, not a fix — the full measurement is on
    /// `SelectorAccessoryHost.playCatchUpIfMoved`.
    static var animatesCatchUp: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-catchup")
        #else
        false
        #endif
    }

    /// `-foryou-dock-trace`: one line per layout and per environment change,
    /// to the console AND to `dock-trace.log` in the app's Documents directory.
    static var isTracing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-dock-trace")
        #else
        false
        #endif
    }

    /// The dressing these flags ask for.
    static var options: SelectorAccessoryOptions {
        SelectorAccessoryOptions(
            keepsOwnGlass: keepsOwnGlass,
            animatesCatchUp: animatesCatchUp,
            isTracing: isTracing
        )
    }
}
