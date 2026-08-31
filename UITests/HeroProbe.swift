import XCTest

/// The hero audit's probe, parsed — the app→test channel every Hero suite
/// reads (see `HeroTransitionAudit`, App/Shell).
///
/// The identifier is a census line:
/// `hero;seq=41;state=settled;animators=0;…;stranded=0;players=1;…`
/// `seq` is monotonic (one bump per audit sample, 4Hz), which is what turns
/// every wait in these suites into a STATE-GATED one: "the audit sampled
/// again after my gesture and read settled" rather than a sleep sized to an
/// animation — the exact discipline the repo's Slow-Animations and
/// settle-flakiness notes exist to enforce.
struct HeroProbe {
    let sequence: Int
    let state: String
    let animators: Int
    let interruptors: Int
    let drivers: Int
    let retries: Int
    let cards: Int
    let pins: Int
    let stranded: Int
    let players: Int
    let idle: Int
    let duplicates: Int
    let anchors: Int
    let stalls: Int
    let generations: Int

    var isSettled: Bool { state == "settled" }

    /// Everything that must be gone once a transition has settled. `players`
    /// and the pool ledgers are deliberately NOT here — a resting page
    /// legitimately holds a player, and a paused neighbour holds an anchor;
    /// those are asserted against context by the tests that know it.
    var transitionResidue: Int {
        animators + interruptors + retries + cards + pins + stranded
    }

    init?(_ identifier: String) {
        let fields = identifier.split(separator: ";")
        guard fields.first == "hero" else { return nil }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            values[String(pair[0])] = String(pair[1])
        }
        func int(_ key: String) -> Int? { values[key].flatMap { Int($0) } }
        guard let sequence = int("seq"), let state = values["state"],
              let animators = int("animators"), let interruptors = int("interruptors"),
              let drivers = int("drivers"), let retries = int("retries"),
              let cards = int("cards"), let pins = int("pins"),
              let stranded = int("stranded"), let players = int("players"),
              let idle = int("idle"), let duplicates = int("dupes"),
              let anchors = int("anchors"), let stalls = int("stalls"),
              let generations = int("gen")
        else { return nil }
        self.sequence = sequence
        self.state = state
        self.animators = animators
        self.interruptors = interruptors
        self.drivers = drivers
        self.retries = retries
        self.cards = cards
        self.pins = pins
        self.stranded = stranded
        self.players = players
        self.idle = idle
        self.duplicates = duplicates
        self.anchors = anchors
        self.stalls = stalls
        self.generations = generations
    }
}

/// Shared plumbing for the Hero suites: launch shapes, probe queries, and the
/// seq-gated settle wait.
extension XCTestCase {
    /// Launches the app in mock mode with the audit armed, plus `arguments`.
    /// `-rich-media` is deliberately NOT default — the synthetic clips are the
    /// offline guarantee; suites that want real assets opt in.
    func launchHeroApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-auto-login", "-hero-audit"] + arguments
        app.launch()
        return app
    }

    /// The probe element, wherever the audit attached it.
    func heroProbeElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'hero;'"))
            .firstMatch
    }

    /// The current census, or nil when the probe is missing/unparseable.
    func heroProbe(in app: XCUIApplication) -> HeroProbe? {
        let element = heroProbeElement(in: app)
        guard element.exists else { return nil }
        return HeroProbe(element.identifier)
    }

    /// Waits for the audit to publish a SETTLED sample taken strictly after
    /// `sequence` — the suite's only wait primitive. Returns the settled
    /// census, or fails with what it last saw (the "what would this look like
    /// broken" denominator: a missing probe and a stuck transition read
    /// differently here).
    @discardableResult
    func waitForHeroSettle(
        in app: XCUIApplication,
        after sequence: Int,
        timeout: TimeInterval = 20,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> HeroProbe? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: HeroProbe?
        var lastIdentifier = "no probe"
        while Date() < deadline {
            let element = heroProbeElement(in: app)
            if element.waitForExistence(timeout: 1) {
                lastIdentifier = element.identifier
                if let probe = HeroProbe(lastIdentifier) {
                    last = probe
                    if probe.sequence > sequence, probe.isSettled {
                        return probe
                    }
                }
            }
        }
        XCTFail(
            "no settled census after seq=\(sequence) within \(timeout)s"
            + " — last saw: \(lastIdentifier). \(message)",
            file: file, line: line
        )
        return last
    }

    /// The settled-state checklist every return owes, asserted from a probe:
    /// no transition object alive, nothing stranded in a window, no asset
    /// carrying two players.
    func assertHeroResidueClear(
        _ probe: HeroProbe?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let probe else {
            return XCTFail("no probe to assert on — \(message)", file: file, line: line)
        }
        XCTAssertEqual(probe.transitionResidue, 0,
                       "transition residue after settle (animators=\(probe.animators)"
                       + " interruptors=\(probe.interruptors) retries=\(probe.retries)"
                       + " cards=\(probe.cards) pins=\(probe.pins)"
                       + " stranded=\(probe.stranded)) — \(message)",
                       file: file, line: line)
        XCTAssertEqual(probe.duplicates, 0,
                       "an asset holds two players — \(message)", file: file, line: line)
    }

    /// Screenshot evidence, kept in the result bundle whatever the outcome —
    /// the "affiche pour la confirmation" channel. Named so a montage of a
    /// run reads as a storyboard.
    func attachHeroEvidence(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
