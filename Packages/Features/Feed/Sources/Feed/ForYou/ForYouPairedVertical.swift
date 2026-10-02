import Foundation

/// EXPERIMENT (2026-10-02): For You's Discover list draws VERTICAL media —
/// posts taller than 4:5 (`VerticalMediaPairing.isEligible`) — as half-width
/// cards two side by side, in blocks of two to six, instead of one full-width
/// card each. A paired card is the Following row's card
/// (`ForYouFollowingCardCell`: the picture, the author and two lines over its
/// foot, no actions) at half the list's width, 3:4 (product call, 2026-10-02,
/// after a first build drew the list's own card shrunk). Collections never
/// pair. Where the pairs go is the planner's (`MosaicChunkPlanner.pairBlock`).
///
/// Off by default: without the launch argument the list is exactly today's.
enum ForYouPairedVertical {
    /// The launch argument that turns the experiment on.
    static let launchArgument = "-foryou-paired-vertical"

    /// Whether `arguments` ask for the experiment. Release builds never do.
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        arguments.contains(launchArgument)
        #else
        false
        #endif
    }

    /// Whether this process asked for it — what For You builds its page with.
    static var isEnabled: Bool {
        isEnabled(arguments: ProcessInfo.processInfo.arguments)
    }

    /// QA, DEBUG only: `-foryou-paired-demo` (with the flag above) keeps the
    /// chunks off pairable posts so blocks are frequent enough to judge on
    /// the mock corpus — see `MosaicChunkPlanner.chunksLeavePairableMedia`.
    static var isDemo: Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains("-foryou-paired-demo")
        #else
        false
        #endif
    }
}
