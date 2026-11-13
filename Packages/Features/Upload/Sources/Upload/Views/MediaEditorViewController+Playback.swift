import AVFoundation
import DesignSystem
import MediaPlayback
import UIKit

// Playing the settled page (#2388, out of the editor's file).

// MARK: - Playing the settled page

extension MediaEditorViewController {
    /// ⚠️ **ONE PAGE PLAYS, AND IT IS THE ONE THAT HAS COME TO REST.** The canvas
    /// holds every chosen medium and recycles their cells, so "play the videos"
    /// would mean a player per page, a pool the screen does not own, and
    /// surfaces outliving the cells they were bound to — which is precisely the
    /// shape of this repo's one recorded player leak. One player, one page, and
    /// the binding torn down before the next one is made.
    ///
    /// ⚠️ **NOT DURING CROP.** Crop mode lifts the picture onto its own surface
    /// and takes the gestures with it; a clip still running underneath would be
    /// moving pixels nobody is looking at, behind a still the author IS looking
    /// at.
    func playSettledPage(from carried: Double? = nil) {
        // The crop surface holds the clip while its box is being aimed — see
        // `playInsideTheCropBox`.
        guard !isCropping else { return }
        guard let id = currentItemID, itemsByID[id]?.isVideo == true else {
            return stopPreview()
        }
        // A settle that lands where it already was must not restart the clip —
        // the fill/fit toggle and the band both settle the canvas.
        guard playingID != id else { return }
        stopPreview()

        guard let page = canvas.cellForItem(at: IndexPath(item: currentIndex, section: 0))
                as? MediaEditorPageCell
        else { return }

        playingID = id
        page.beginShowingVideo()
        boundSurface = page.videoSurface
        // ⚠️ THE CELL TELLS US WHEN IT IS TAKEN AWAY. A canvas recycles pages
        // without asking, and a surface handed to a player and then re-used for
        // another item would keep the previous clip's frames.
        page.onReuse = { [weak self] surface in
            guard let self else { return }
            if playingID == id { closeTransitions(animated: false) }
            preview.stop(surface)
            if playingID == id { playingID = nil }
        }

        // ⚠️ **THE EDIT, NOT THE FILE — IN EVERY MODE.** The canvas plays the
        // arrangement the author has made, from its start, whichever band is
        // open; the funnel re-asks everything after its awaits, since a read can
        // take a moment and the author may have swiped on while it did.
        previewSubject = nil
        loadPreview { timeline, fileSeconds in
            VideoLoadLanding(seconds: Self.continuing(carried, in: timeline, fileSeconds: fileSeconds))
        }
    }

    /// Unbinds whatever is playing and puts the page back to its poster.
    func stopPreview() {
        guard let id = playingID else { return }
        // Nothing may go on looping a stretch of a clip that is no longer playing.
        closeTransitions(animated: false)
        playingID = nil
        // Whatever is on its way belongs to a page that is no longer playing.
        previewSubject = nil
        previewLoads += 1
        previewPending = false
        // ⚠️ **WHATEVER IT WAS BOUND TO, WHICH IS NOT ALWAYS A PAGE.** The crop
        // surface holds the clip while a box is being aimed at it, and it
        // belongs to no cell.
        if let surface = boundSurface { preview.stop(surface) }
        boundSurface = nil
        cropSurface.showsVideo(false)
        guard let index = items.firstIndex(where: { $0.id == id }),
              let page = canvas.cellForItem(at: IndexPath(item: index, section: 0))
                as? MediaEditorPageCell
        else { return }
        page.onReuse = nil
        page.stopShowingVideo()
    }

    /// Plays the clip ON the crop surface, uncut, while its box is being aimed.
    ///
    /// ⚠️ **UNCUT, AND THAT IS THE WHOLE POINT.** The plan the canvas plays
    /// carries the crop, so the compositor hands back film that is already cut;
    /// aiming a box at that would crop a crop, and every rectangle the author
    /// drew would bite twice. `includingCrop: false` is why this is a load of
    /// its own rather than the canvas's.
    func playInsideTheCropBox(for id: String) {
        guard itemsByID[id]?.isVideo == true else { return }
        // ⚠️ **READ BEFORE THE STOP, BECAUSE THE STOP IS WHAT FORGETS IT.**
        let carried = playingID == id ? playheadOfTheFilmPlayingNow() : nil
        stopPreview()
        playingID = id
        boundSurface = cropSurface.videoSurface
        cropSurface.showsVideo(true)
        previewSubject = nil
        loadPreview { timeline, fileSeconds in
            VideoLoadLanding(seconds: Self.continuing(carried, in: timeline, fileSeconds: fileSeconds))
        }
    }

    /// Where the film playing now has got to, in played seconds.
    func playheadOfTheFilmPlayingNow() -> Double? {
        guard let surface = boundSurface else { return nil }
        return preview.playheadSeconds(in: surface)
    }

}
