import Testing
@testable import LaunchArguments

/// A declared launch argument reads exactly what the raw reads did (#2374).
struct LaunchArgumentTests {
    let tab = LaunchArgument("-switch-tab")

    @Test func isPassedOnlyWhenTheWholeWordIsThere() {
        #expect(tab.isPassed(in: ["app", "-switch-tab", "3"]))
        #expect(!tab.isPassed(in: ["app", "-switch-tab-now"]))
        #expect(!tab.isPassed(in: []))
    }

    @Test func theValueIsTheWordAfterIt() {
        #expect(tab.value(in: ["app", "-switch-tab", "3"]) == "3")
        #expect(tab.intValue(in: ["app", "-switch-tab", "3"]) == 3)
        #expect(tab.doubleValue(in: ["-switch-tab", "0.5"]) == 0.5)
    }

    @Test func noValueWhenAbsentOrLast() {
        #expect(tab.value(in: ["app"]) == nil)
        #expect(tab.value(in: ["app", "-switch-tab"]) == nil)
        #expect(tab.intValue(in: ["-switch-tab", "maps"]) == nil)
    }

    @Test func itPrintsAsPassed() {
        #expect("\(tab)" == "-switch-tab")
    }
}
