import CoreModels
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Maps

/// THE SUB-FILTER PILLS KEEP NO FACES OF THEIR OWN (#894).
///
/// The pill row and the organize sheet each held a `[ProfileID: UIImage]` of
/// full-size avatars for their whole life, outside the image pipeline's
/// budget and trims. The faces now live in the pipeline, decoded at the
/// avatar bucket, and both read them back from there.
@MainActor
struct MapSubFilterAvatarsOnPipelineTests {
    private static func url(_ id: String) -> URL {
        URL(string: "mock://map-favorite/\(id)?w=1600&h=1600")!
    }

    private static func person(_ id: String) -> MapSubFilterOption {
        MapSubFilterOption.people([
            MapFavorite(profileID: ProfileID(id), title: id.uppercased(), avatarURL: url(id), handle: id)
        ])[0]
    }

    /// Generous: the full scheme runs its suites in parallel, and a decode
    /// can wait seconds for the pool there. Returns as soon as `done`.
    private static func settle(timeout: Duration = .seconds(120), until done: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !done(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func headerImage(_ bar: MapSubFilterBarView, _ option: MapSubFilterOption) -> UIImage? {
        let section = bar.pillMenu(for: option.subFilter)?.header as? UIMenu
        return (section?.children.first as? UIAction)?.image
    }

    /// The row fetches each face through the pipeline at the avatar bucket,
    /// and the menu header is drawn from the pipeline's copy once it lands.
    @Test func theRowsFacesAreDecodedInThePipelineAtTheAvatarBucket() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let option = Self.person("ada")
        let url = Self.url("ada")
        let bar = MapSubFilterBarView()
        bar.imagePipeline = pipeline

        bar.setOptions([option])
        #expect(Self.headerImage(bar, option)?.isSymbolImage == true, "guard: the glyph shows before the face lands")
        await Self.settle { pipeline.isDecoded(url, size: MapSubFilterBarView.avatarBucket) }

        #expect(pipeline.isDecoded(url, size: .avatar), "the face is not in the pipeline's memory")
        #expect(!pipeline.isDecoded(url, size: .full), "the face was decoded at full size")
        let header = Self.headerImage(bar, option)
        #expect(header != nil && header?.isSymbolImage == false, "the menu header did not draw the pipeline's face")
    }

    /// A face the pipeline already holds is drawn at once: the row reads the
    /// pipeline's memory, no copy of its own.
    @Test func aFaceThePipelineHoldsIsReadAtOnce() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let option = Self.person("grace")
        _ = try? await pipeline.image(for: Self.url("grace"), size: .avatar)
        let bar = MapSubFilterBarView()
        bar.imagePipeline = pipeline

        bar.setOptions([option])

        #expect(Self.headerImage(bar, option)?.isSymbolImage == false,
                "a face already decoded was not drawn on this turn")
    }

    /// The organize sheet fetches the faces it lacks through the same
    /// pipeline, at the same bucket as the row.
    @Test func theSheetsFacesComeFromThePipeline() async {
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        let options = ["a", "b"].map(Self.person)
        let sheet = MapSubFilterSheetViewController(
            title: "Following",
            all: options,
            activeSubFilters: [options[0].subFilter],
            maxActive: MapSubFilterSections.defaultMaxActive,
            imagePipeline: pipeline,
            rowActions: .none,
            onOptionsChanged: { _ in }
        )
        sheet.loadViewIfNeeded()
        await Self.settle {
            ["a", "b"].allSatisfy { pipeline.isDecoded(Self.url($0), size: .avatar) }
        }

        for id in ["a", "b"] {
            #expect(pipeline.isDecoded(Self.url(id), size: .avatar), "\(id)'s face is not in the pipeline")
            #expect(!pipeline.isDecoded(Self.url(id), size: .full), "\(id)'s face was decoded at full size")
        }
    }
}
