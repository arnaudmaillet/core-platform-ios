import Metal
import Testing
@testable import DesignSystem

/// The lens's shader, read back pixel by pixel: it magnifies about the
/// centre, pulls the rim outward, and splits the pull per channel. A source
/// of 200×100 px under a lens of the same box (no margin), so output pixel
/// and source pixel share coordinates.
@MainActor
struct LensRefractorTests {
    private let width = 200, height = 100

    private struct Pixel { let b, g, r, a: UInt8 }

    /// A transparent source with a white column over `column` (x range).
    private func source(column: Range<Int>) -> MTLTexture? {
        guard let texture = LensRefractor.shared.makeSourceTexture(width: width, height: height) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in column {
                let i = (y * width + x) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
            }
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private func uniforms(magnification: Float = 1, edge: Float = 30, bend: Float = 0,
                          aberration: Float = 0, blur: Float = 0) -> LensRefractor.Uniforms {
        LensRefractor.Uniforms(
            size: SIMD2(Float(width), Float(height)),
            centre: SIMD2(Float(width) / 2, Float(height) / 2),
            halfExtent: SIMD2(Float(width) / 2, Float(height) / 2),
            sourceOffset: .zero,
            sourceSize: SIMD2(Float(width), Float(height)),
            magnification: magnification, edge: edge, bend: bend, aberration: aberration, blur: blur
        )
    }

    /// Renders and reads the output back; nil when there is no Metal here.
    private func render(column: Range<Int>, _ uniforms: LensRefractor.Uniforms) async -> [[Pixel]]? {
        let refractor = LensRefractor.shared
        await refractor.ready()
        guard refractor.isReady, let source = source(column: column),
              let target = refractor.makeTargetTexture(width: width, height: height) else { return nil }
        guard refractor.render(source: source, into: target, uniforms: uniforms) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (0..<height).map { y in
            (0..<width).map { x in
                let i = (y * width + x) * 4
                return Pixel(b: bytes[i], g: bytes[i + 1], r: bytes[i + 2], a: bytes[i + 3])
            }
        }
    }

    @Test func theCopyIsMagnifiedAboutTheCentre() async throws {
        // A column 40 px left of the centre reads 50 px left of it at 1.25×.
        guard let out = try await requireRender(column: 56..<64, uniforms(magnification: 1.25)) else { return }
        let row = out[height / 2]
        #expect(row[50].a > 200, "the column's magnified image sits at x≈50, got alpha \(row[50].a)")
        #expect(row[60].a < 30, "nothing at the column's own x any more, got alpha \(row[60].a)")
        #expect(row[100].a < 30, "the centre stays clear")
    }

    @Test func theRimPullsTheSourceOutward() async throws {
        // A column on the very edge; a rim pixel 10 px in samples past it
        // once the bend pulls outward, and never without the bend.
        let plain = try await requireRender(column: 0..<6, uniforms(edge: 30, bend: 0))
        let bent = try await requireRender(column: 0..<6, uniforms(edge: 30, bend: 20))
        guard let plain, let bent else { return }
        #expect(plain[height / 2][10].a < 30, "no bend: x=10 shows what is at x=10, nothing")
        #expect(bent[height / 2][10].a > 150, "bent: x=10 samples out past the column's edge")
    }

    @Test func theBendSplitsRedFromBlueAtTheRim() async throws {
        let split = try await requireRender(column: 0..<8, uniforms(edge: 30, bend: 20, aberration: 0.6))
        let whole = try await requireRender(column: 0..<8, uniforms(edge: 30, bend: 20, aberration: 0))
        guard let split, let whole else { return }
        func fringe(_ out: [[Pixel]]) -> Int {
            out[height / 2].prefix(40).filter { abs(Int($0.r) - Int($0.b)) > 30 }.count
        }
        #expect(fringe(split) > 0, "some rim pixel reads red apart from blue")
        #expect(fringe(whole) == 0, "without aberration every channel samples the same spot")
    }

    /// Renders, or records once why it could not — a Mac without Metal in
    /// the simulator is not a failure of the shader.
    private func requireRender(column: Range<Int>, _ uniforms: LensRefractor.Uniforms) async throws -> [[Pixel]]? {
        if LensRefractor.shared.device == nil {
            Issue.record("no Metal device in this test host; the shader was not exercised")
            return nil
        }
        let out = await render(column: column, uniforms)
        try #require(out != nil, "the shader compiled and rendered")
        return out
    }
}
