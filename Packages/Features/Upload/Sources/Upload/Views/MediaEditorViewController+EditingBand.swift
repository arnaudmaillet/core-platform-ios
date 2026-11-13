import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// The editing band (#2388, out of the editor's file).

// MARK: - The editing band

extension MediaEditorViewController {
    /// Puts a control in the strip between the toolbar and the page indicator,
    /// or takes it away with `nil`.
    ///
    /// The band reserves room and owns placement; what goes in it — a horizontal
    /// row of filter thumbnails first — is built separately and handed over here,
    /// so the screen never learns what a filter is.
    ///
    /// ⚠️ **THIS IS PRODUCTION CODE AND MUST STAY OUT OF `#if DEBUG`. IT DID NOT,
    /// AND IT COST A RED CI CYCLE.** It was first written just below
    /// `debugTapFit()` — inside the DEBUG-only extension that starts a few lines
    /// down — while its only callers, `showAccessory(for:)`, are ordinary code.
    /// Debug compiled, the 120-test suite passed, and the flow was verified end to
    /// end on a device; **every one of those instruments builds Debug**, where the
    /// symbol exists. CI compiles Debug *and* Release, and Release failed with
    /// `cannot find 'setEditingAccessory' in scope`. The old comment here already
    /// said "NOT A DEBUG HOOK" — the intent was right, only the placement was
    /// wrong, which is why a comment is no substitute for the right side of a
    /// `#if`. Before pushing anything added near those accessors, build Release.
    func setEditingAccessory(_ accessory: UIView?, animated: Bool = false) {
        // ⚠️ **EVERY MODE HEARS IT FIRST, WHOEVER IS ASKING.** A row, a sheet or
        // a lock a mode opened belongs to the band it opened in; this is the one
        // funnel every band change goes through, so it is the one place a mode
        // can be sure to hear it. A mode must not change the band from here.
        for mode in modes { mode.bandWillChange(to: accessory) }
        // ⚠️ **DEACTIVATE BEFORE ACTIVATING.** Both anchors pin the same edge, so
        // leaving the old one alive for even one pass gives Auto Layout a conflict
        // to arbitrate — and it may keep the one being replaced.
        // ⚠️ **THE DEPARTING TENANT IS TAKEN OUT OF THE BAND BEFORE ANYTHING
        // ELSE HAPPENS, WHATEVER IT IS ABOUT TO DO.** `band.content` is how this
        // screen answers "what is up" in ten places; a tenant left in it for the
        // length of a fade would have all ten answer for a view that is already
        // leaving. `release()` hands it back detached, which is what lets it be
        // animated without lying about the band.
        let departing = animated && band.content !== accessory ? band.release() : nil
        if let accessory {
            // ⚠️ **A TENANT TAKEN BACK MID-DEPARTURE STOPS LEAVING.** Its
            // departure already wrote alpha 0 and the collapsed transform to
            // the model, so shown again it went on fading and shrinking — and,
            // at alpha 0, took no tap — until that curve ran out. The camera's
            // option rows cut it short the same way.
            accessory.layer.removeAllAnimations()
            accessory.alpha = 1
            accessory.transform = .identity
            band.show(accessory)
            backdropFromChrome.isActive = false
            backdropFromBand.isActive = true
        } else {
            band.clear()
            backdropFromBand.isActive = false
            backdropFromChrome.isActive = true
        }
        // ⚠️ **THE CHIPS BELONG TO THE TIMELINE AND LEAVE WITH IT.** They are
        // laid out inside the tenant, so a band holding something else cannot
        // show them — but the bar's lit speedometer and the tenant's own flag
        // would come back on next time still saying "open", over a row nobody
        // asked for.
        if accessory !== timelineTools {
            closeTransitions(animated: false)
            timelineTools.isOfferingSpeeds = false
            actionBar.setActive(nil)
        }
        // The leading half of the toolbar is the mode's — see
        // `refreshToolbarItems`.
        refreshToolbarItems(animated: true)
        refreshTrackActions()
        // ⚠️ **THE ONE FUNNEL EVERY BAND CHANGE GOES THROUGH, WHICH IS WHY THE
        // FOLLOWER IS STARTED AND STOPPED HERE.** Six routes install a tenant —
        // three settle hooks, the category bar, the too-short notice and crop's
        // own exit — and a link started next to only some of them would keep
        // polling a player nobody is watching for as long as the editor is open.
        follower.isPaused = accessory !== timelineTools
        // The undo arrow's meaning changes with the band, so its enabled state
        // has to be re-decided here too.
        refreshHistoryItems()
        // ⚠️ THE BAND JUST MOVED THE INDICATOR, AND THE INDICATOR IS THE FOOT OF A
        // FITTED PICTURE'S WINDOW. Laying out first is what makes `fitWindow` true
        // rather than one band-height out of date.
        followTheBand(animated: animated)
        if let departing { popTheTenantOut(departing) }
        if animated, let accessory { popTheTenantIn(accessory) }
    }

    /// The band's arrival curve: every element the tenant names, one after
    /// another — see `BandPop`.
    ///
    /// ⚠️ **AFTER THE LAYOUT PASS, NOT BEFORE.** A scale transform is applied
    /// about a view's centre, and a view that has not been laid out yet has no
    /// centre worth scaling about: the whole row would pop from the band's
    /// top-left corner. `setEditingAccessory` lays out just above, which is what
    /// makes this the right side of the call.
    private func popTheTenantIn(_ accessory: UIView) {
        guard !MotionPreference.reducesMotion else { return }
        // ⚠️ **A TENANT THAT NAMES NOTHING STILL ARRIVES.** The soundtrack tools
        // are a waveform and two sliders, not a row of items, and a screen where
        // six bands ripple and the seventh blinks on reads as the seventh being
        // broken. Named elements give a ripple; anything else pops as one piece.
        // ⚠️ **THE RULERS START WITH THE FIRST ELEMENT, NOT AFTER THE LAST.**
        // A ruler is the readout of whatever the row chooses; arriving after the
        // row has settled it reads as a second thing happening. Its own sweep
        // runs out from the needle, so the two motions are travelling the same
        // way at the same time.
        let surfaces = (accessory as? PoppingTenant)?.revealingSurfaces ?? []
        for surface in surfaces { surface.reveal(after: 0) }
        #if DEBUG
        debugReveals.append(surfaces.count)
        #endif
        let named = (accessory as? PoppingTenant)?.poppableElements ?? []
        let elements = named.isEmpty ? [accessory] : named
        guard !elements.isEmpty else { return }
        #if DEBUG
        debugPopIns.append(elements.count)
        #endif
        for (index, element) in elements.enumerated() {
            // ⚠️ **ONE POP PER ELEMENT, UP TO THE POINT THE EAR STOPS COUNTING.**
            // The stagger is capped, so past `audibleElements` every remaining
            // element arrives at the same moment — and nine sounds fired at one
            // moment are not nine sounds, they are a click. What the ear hears
            // is the ripple, and the ripple is the part that is staggered.
            if index < BandPop.audibleElements { UISound.pop.play(after: BandPop.stagger(for: index)) }
            element.alpha = 0
            element.transform = BandPop.collapsedTransform
            UIView.animate(
                withDuration: BandPop.duration,
                delay: BandPop.stagger(for: index),
                usingSpringWithDamping: BandPop.dampingRatio,
                initialSpringVelocity: 0,
                // ⚠️ **THE ROW STAYS TAPPABLE WHILE IT ARRIVES.** Without this,
                // a finger that follows its own tap onto the first card waits
                // out the whole ripple before anything answers.
                options: [.allowUserInteraction]
            ) {
                element.alpha = 1
                element.transform = .identity
            }
        }
    }

    /// The departure curve, on a tenant the band has already let go of.
    ///
    /// ⚠️ **QUICKER THAN THE ARRIVAL, AND NOT STAGGERED.** Leaving is not an
    /// event the author is reading — they have already asked for something else
    /// — so the whole tenant goes at once and gets out of the way.
    ///
    /// ⚠️ **AND IT PUTS THE VIEW BACK AS IT FOUND IT.** Every tenant is built
    /// once and shown again; a row left at 0 alpha and three-quarter scale
    /// would come back invisible the next time it was asked for.
    private func popTheTenantOut(_ departing: UIView) {
        guard !MotionPreference.reducesMotion else {
            departing.removeFromSuperview()
            return
        }
        #if DEBUG
        debugPopOuts += 1
        #endif
        UIView.animate(
            withDuration: BandPop.departure,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            departing.alpha = 0
            departing.transform = BandPop.collapsedTransform
        } completion: { [weak self] _ in
            departing.alpha = 1
            departing.transform = .identity
            // ⚠️ **NOT IF THE BAND HAS TAKEN IT BACK.** Tenants are built once
            // and shown again: reopened within the departure's 0.17s — Effects,
            // Filters, Effects — a tenant was back in the band when this ran,
            // and was pulled out of it, leaving an open band holding nothing
            // under a chosen icon. The camera's option rows had the same race
            // (found by review there first).
            guard departing !== self?.band.content else { return }
            departing.removeFromSuperview()
        }
    }
}
