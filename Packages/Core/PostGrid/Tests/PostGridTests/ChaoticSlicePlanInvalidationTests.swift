import Testing
import UIKit
@testable import PostGrid

/// A host told "arrange later" is re-planned when the geometry arrives.
///
/// ⚠️ **It used to be re-planned only on a geometry CHANGE.** The first
/// geometry has no previous one to differ from, so a feed seeded before the
/// grid had a width was arranged in reading order and never revisited —
/// clips stayed in slots that crop them. `slotMetrics` returning `[]` is a
/// promise, and these pin that the first layout keeps it, and only then.
@MainActor
struct ChaoticSlicePlanInvalidationTests {
    /// Owns the collection view AND its data source (a weak reference) — see
    /// `ChaoticSliceGutterTests.Harness` for the crash that rule prevents.
    private final class Harness: NSObject, UICollectionViewDataSource {
        let layout = ChaoticSliceLayout()
        let collectionView: UICollectionView
        var invalidations = 0

        init(frame: CGRect) {
            collectionView = UICollectionView(frame: frame, collectionViewLayout: layout)
            super.init()
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            collectionView.dataSource = self
            layout.onPlanInvalidated = { [weak self] in self?.invalidations += 1 }
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { 12 }

        func collectionView(
            _ view: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            view.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
    }

    /// The callback is posted a turn later, out of the layout pass.
    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("A host told to arrange later is re-planned once the grid has a width")
    func theFirstGeometryKeepsTheLaterPromise() async {
        let harness = Harness(frame: .zero)
        #expect(harness.layout.slotMetrics(forItemCount: 12).isEmpty,
                "guard: no geometry, so the host is told to arrange later")

        harness.collectionView.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        harness.collectionView.layoutIfNeeded()
        await Self.drainMainQueue()

        #expect(harness.invalidations == 1, "the first geometry never re-planned the host it deferred")
        #expect(!harness.layout.slotMetrics(forItemCount: 12).isEmpty)
    }

    @Test("A first layout nobody deferred to re-plans nothing")
    func aFirstLayoutWithNothingOwedIsSilent() async {
        let harness = Harness(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        harness.collectionView.layoutIfNeeded()
        await Self.drainMainQueue()

        #expect(harness.invalidations == 0, "a frame-0 reload nobody needed")
    }

    @Test("A width change still re-plans")
    func aWidthChangeStillReplans() async {
        let harness = Harness(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        harness.collectionView.layoutIfNeeded()
        await Self.drainMainQueue()

        harness.collectionView.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        harness.collectionView.layoutIfNeeded()
        await Self.drainMainQueue()

        #expect(harness.invalidations == 1)
    }
}
