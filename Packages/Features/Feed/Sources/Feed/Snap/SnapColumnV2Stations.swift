import DesignSystem
import ThreadKit
import UIKit

/// Where the action column's bubbles stand under `-snap-layout-v2` (#2408):
/// four stations stacked UPWARD from the sound's, one `SnapActionColumn.gap`
/// apart, bottom to top ◉ ↗ ☆ ♥.
///
/// ```
///   ╭♥╮   the like pill: the classic pill's height (`boostStation`'s)
///   │ │
///   ╰─╯
///   (☆)   save
///   (↗)   share
///   (◉)   the sound: `soundStation`, unchanged, on the caption's line (#2326)
/// ```
///
/// ⚠️ HANGING OFF THE SOUND'S STATION, NEVER OFF THE CAPTION. The column and
/// the left block (danmaku, ticker, caption) are two independent stacks
/// (#2407): a two-line caption or a missing band never moves a bubble. The
/// sound's station already stands on the margins line, risen by the column's
/// lift (`applyColumnSeat`), so these ride it — the lift and the comments'
/// glide included — with no constraint of their own against the page.
///
/// Invisible and touch-transparent, like the classic stations: the glass
/// column frames the buttons on them (`SnapChromeActionColumn.columnSlots`).
@MainActor
final class SnapColumnV2Stations {
    let share = UIView()
    let save = UIView()
    let like = UIView()

    /// Builds the three stations in `host`, over `sound`; the like pill keeps
    /// `pill`'s height, so it follows the text size as the classic pill does.
    init(in host: UIView, sound: UIView, pill: UIView) {
        for station in [share, save, like] {
            station.isUserInteractionEnabled = false
            station.isHidden = true
            station.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(station)
        }
        let gap = SnapActionColumn.gap
        var constraints: [NSLayoutConstraint] = []
        var below = sound
        for bubble in [share, save] {
            constraints += [
                bubble.trailingAnchor.constraint(equalTo: sound.trailingAnchor),
                bubble.widthAnchor.constraint(equalTo: sound.widthAnchor),
                bubble.heightAnchor.constraint(equalTo: sound.heightAnchor),
                bubble.bottomAnchor.constraint(equalTo: below.topAnchor, constant: -gap),
            ]
            below = bubble
        }
        constraints += [
            like.trailingAnchor.constraint(equalTo: sound.trailingAnchor),
            like.widthAnchor.constraint(equalTo: sound.widthAnchor),
            like.heightAnchor.constraint(equalTo: pill.heightAnchor),
            like.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -gap),
        ]
        NSLayoutConstraint.activate(constraints)
    }
}
