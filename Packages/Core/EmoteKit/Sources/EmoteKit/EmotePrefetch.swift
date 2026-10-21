import UIKit

/// Warms the emotes of text about to be shown (#1504): the captions of the
/// pages ahead of the one on screen, so their art is resident when they
/// arrive and a label installs it in its first layout pass — no skeleton.
///
/// A plain, non-urgent request per emote (`EmoteEngine.requestArt`): it waits
/// `EmoteEngine.bakeDelay` before baking, so a page flicked past costs
/// nothing, and a request no longer wanted is cancelled at the next `warm`.
/// The motion is the label's (`EmoteMotion.policy`): the still frame when
/// emotes may not move, the loop otherwise.
@MainActor
public final class EmotePrefetch {
    private weak var engine: EmoteEngine?
    private var requests: [String: EmoteRequest] = [:]

    public init(engine: EmoteEngine = .shared) {
        self.engine = engine
    }

    /// Asks for the emotes of `texts` at `pixelSide` (the bucket the label
    /// that will draw them uses, `EmoteLabel.emotePixelSide`), and lets go of
    /// what an earlier `warm` asked for that `texts` no longer hold.
    public func warm(_ texts: [String], pixelSide: Int) {
        guard let engine else { return }
        let motion: EmoteEngine.Motion = EmoteMotion.policy == .still ? .still : .loop
        var wanted = Set<String>()
        for text in texts {
            for match in EmoteParser.matches(in: text, catalog: engine.catalog) {
                let emote = match.emote
                let key = "\(emote.id)|\(pixelSide)|\(motion)"
                guard wanted.insert(key).inserted, requests[key] == nil,
                      engine.cachedArt(for: emote, pixelSide: pixelSide, motion: motion) == nil else { continue }
                var answered = false
                let request = engine.requestArt(for: emote, pixelSide: pixelSide, motion: motion) { [weak self] _ in
                    answered = true
                    self?.requests[key] = nil
                }
                if !answered { requests[key] = request }
            }
        }
        for (key, request) in requests where !wanted.contains(key) {
            request.cancel()
            requests[key] = nil
        }
    }

    /// Lets go of everything asked for.
    public func cancelAll() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }

    /// The requests still on their way. Tests.
    var pendingKeys: Set<String> { Set(requests.keys) }
}
