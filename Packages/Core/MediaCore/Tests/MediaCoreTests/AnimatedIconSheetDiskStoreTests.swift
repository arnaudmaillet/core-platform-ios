import Foundation
import Testing
import UIKit
@testable import MediaCore

/// The mock's baked avatar sheets survive a relaunch (#1841): read back with
/// their geometry, and a miss for anything else.
struct AnimatedIconSheetDiskStoreTests {
    private let store = AnimatedIconSheetDiskStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("sheet-store-\(UUID().uuidString)")
    )

    private func sheet(frames: Int = 48, cellPX: Int = 16) -> AnimatedIconSheet {
        let rows = Int(ceil(Double(frames) / 4))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4 * cellPX, height: rows * cellPX), format: format).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4 * cellPX, height: rows * cellPX))
        }
        return AnimatedIconSheet(sheet: image, frameCount: frames, columns: 4, frameDuration: 1.0 / 12, startTime: 1.5)
    }

    @Test func aStoredSheetComesBackWithItsGeometry() throws {
        let baked = sheet()
        store.store(baked, forKey: "clip-7-128")
        let read = try #require(store.sheet(forKey: "clip-7-128"))
        #expect(read.frameCount == 48)
        #expect(read.columns == 4)
        #expect(read.frameDuration == baked.frameDuration)
        #expect(read.startTime == 1.5)
        #expect(read.frameRects == baked.frameRects)
        #expect(read.sheet.cgImage?.width == 64)
        #expect(read.sheet.cgImage?.height == 192)
        try? FileManager.default.removeItem(at: store.directory)
    }

    @Test func anUnknownOrBrokenKeyIsAMiss() throws {
        #expect(store.sheet(forKey: "nothing-here") == nil)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not a sheet".utf8).write(to: store.directory.appendingPathComponent("broken.sheet"))
        #expect(store.sheet(forKey: "broken") == nil)
        try? FileManager.default.removeItem(at: store.directory)
    }

    @Test func aKeyIsAFileNameWhateverItHolds() throws {
        store.store(sheet(frames: 4), forKey: "a/b:c 128")
        #expect(store.sheet(forKey: "a/b:c 128")?.frameCount == 4)
        try? FileManager.default.removeItem(at: store.directory)
    }
}
