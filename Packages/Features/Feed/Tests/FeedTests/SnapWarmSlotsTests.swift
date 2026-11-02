import Testing
@testable import Feed

/// **Two panels built ahead (#2059).** The feed pages back (#2056), so the
/// previous text page's resting panel is built as well as the next one's,
/// and building one never throws the other away.
struct SnapWarmSlotsTests {
    private final class Panel {}

    @Test func twoPanelsAreHeldTogether() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        let next = Panel(), previous = Panel()
        slots.insert(next, for: "next")
        slots.insert(previous, for: "previous")
        #expect(slots.contains("next") && slots.contains("previous"), "building the previous page's panel dropped the next one's")
    }

    @Test func theOldestGoesPastTheCapacity() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        slots.insert(Panel(), for: "a")
        slots.insert(Panel(), for: "b")
        slots.insert(Panel(), for: "c")
        #expect(slots.keys == ["b", "c"])
    }

    @Test func takingHandsTheValueOverOnce() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        let panel = Panel()
        slots.insert(panel, for: "a")
        #expect(slots.take("a") === panel)
        #expect(slots.take("a") == nil)
        #expect(slots.isEmpty)
    }

    @Test func whatLeftTheWindowIsLetGo() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        slots.insert(Panel(), for: "old")
        slots.insert(Panel(), for: "next")
        slots.keep(only: ["next", "previous"])
        #expect(slots.keys == ["next"])
    }

    @Test func aValueIsForgottenWhereverItIsHeld() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        let panel = Panel()
        slots.insert(panel, for: "a")
        slots.insert(Panel(), for: "b")
        slots.remove(panel)
        #expect(slots.keys == ["b"])
    }

    @Test func insertingAKeyAgainReplacesIt() {
        let slots = SnapWarmSlots<String, Panel>(capacity: 2)
        let first = Panel(), second = Panel()
        slots.insert(first, for: "a")
        slots.insert(second, for: "a")
        #expect(slots.values.count == 1 && slots.values.first === second)
    }
}
