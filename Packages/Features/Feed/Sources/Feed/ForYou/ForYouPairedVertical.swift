import Foundation

/// For You's Discover list draws VERTICAL media — posts taller than 4:5
/// (`VerticalMediaPairing.isEligible`) — as half-width cards two side by side,
/// in blocks of two to six, instead of one full-width card each. A paired card
/// is the Following row's card (`ForYouFollowingCardCell`: the picture, the
/// author and two lines over its foot) at half the list's width, 3:4.
/// Collections never pair. Where the pairs go is the planner's
/// (`MosaicChunkPlanner.pairBlock`).
///
/// Began as the `-foryou-paired-vertical` experiment (#367) and was validated
/// on 2 October 2026: it is unconditional now, and the launch argument is gone.
/// What is left here is QA.
enum ForYouPairedVertical {
    /// QA, DEBUG only: `-foryou-chunks-take-verticals` puts back the rule
    /// chunks had before pairing was the default — a chunk takes every medium
    /// in its reach, vertical or not — to compare the two lists. The default
    /// leaves vertical media to the pairs
    /// (`MosaicChunkPlanner.chunksLeavePairableMedia`, which says why); the
    /// old `-foryou-paired-demo` asked for what is now the default.
    static var chunksTakeVerticals: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-foryou-chunks-take-verticals")
        #else
        false
        #endif
    }
}
