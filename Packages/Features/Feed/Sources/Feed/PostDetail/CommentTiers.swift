import CoreGraphics

/// The tiers a full-screen post's comments read in (#2042, the owner
/// 2026-11-02): the stream shows its first tier — never taller than one
/// screen — and each "More" adds the next, about 1.5 to 2 screens tall. The
/// edge of what is shown is where the screen's own swipe takes over (the next
/// post, the close).
///
/// Tiers are made of whole THREADS (a top-level comment with its replies and
/// its fold), counted from the stream's start: Popular's top, Recent's
/// newest. Pure arithmetic on measured heights, for tests.
enum CommentTiers {
    /// The most a later tier adds, in viewports, and the least it aims for.
    static let laterTierCeiling: CGFloat = 2
    static let laterTierFloor: CGFloat = 1.5

    /// How many threads, from the stream's start, fit one viewport after
    /// `lead` (the caption, on Popular): every thread whose whole height
    /// still fits. Zero when the first one does not.
    static func firstTierCount(heights: [CGFloat], viewport: CGFloat, lead: CGFloat = 0) -> Int {
        var used = lead
        var count = 0
        for height in heights {
            guard used + height <= viewport + 0.5 else { break }
            used += height
            count += 1
        }
        return count
    }

    /// How many more threads the next tier takes from `heights` (the hidden
    /// threads, in order): until it is `laterTierFloor` viewports tall, never
    /// past `laterTierCeiling` — and always one, however tall.
    static func nextTierCount(heights: [CGFloat], viewport: CGFloat) -> Int {
        guard !heights.isEmpty else { return 0 }
        let floor = viewport * laterTierFloor
        let ceiling = viewport * laterTierCeiling
        var used: CGFloat = 0
        var count = 0
        for height in heights {
            if count > 0, used >= floor || used + height > ceiling { break }
            used += height
            count += 1
        }
        return count
    }

    /// `items` cut into threads, in order: a top-level comment starts one,
    /// and its replies and folds follow it. Items before any top-level
    /// comment (a page that starts mid-thread) make one leading thread.
    static func threads<Item>(
        of items: [Item], startsThread: (Item) -> Bool
    ) -> [[Item]] {
        var threads: [[Item]] = []
        for item in items {
            if startsThread(item) || threads.isEmpty {
                threads.append([item])
            } else {
                threads[threads.count - 1].append(item)
            }
        }
        return threads
    }
}
