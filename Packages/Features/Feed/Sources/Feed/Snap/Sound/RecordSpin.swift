import DesignSystem
import QuartzCore

extension CALayer {
    private static let recordSpinKey = "sound.recordSpin"

    /// Turns the layer like a record while its sound plays — one turn in
    /// eight seconds — and stops it WHERE IT IS: paused in place rather than
    /// removed, so the next play turns it on from there instead of snapping
    /// back upright. Shared by the sound sheet's artwork and the feed's cover.
    ///
    /// Still under Reduce Motion and Power Saving (#580): an endless turn
    /// keeps the screen redrawing every frame for as long as the sound plays.
    @MainActor
    func setRecordSpinning(_ spinning: Bool, reducesMotion: Bool = MotionPreference.reducesMotion) {
        let spinning = spinning && !reducesMotion
        if spinning {
            if animation(forKey: Self.recordSpinKey) == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = CGFloat.pi * 2
                spin.duration = 8
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                add(spin, forKey: Self.recordSpinKey)
            }
            guard speed == 0 else { return }
            let paused = timeOffset
            speed = 1
            timeOffset = 0
            beginTime = 0
            beginTime = convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if animation(forKey: Self.recordSpinKey) != nil, speed != 0 {
            let paused = convertTime(CACurrentMediaTime(), from: nil)
            speed = 0
            timeOffset = paused
        }
    }
}
