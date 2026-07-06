import Testing
@testable import CoreNavigation

@MainActor
private final class StubCoordinator: Coordinator {
    var childCoordinators: [Coordinator] = []
    func start() {}
}

@MainActor
struct CoordinatorTests {
    @Test func addAndRemoveChildByIdentity() {
        let parent = StubCoordinator()
        let child = StubCoordinator()

        parent.addChild(child)
        #expect(parent.childCoordinators.count == 1)

        parent.removeChild(child)
        #expect(parent.childCoordinators.isEmpty)
    }
}
