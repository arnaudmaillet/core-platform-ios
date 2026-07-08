import UIKit

@MainActor
public final class ComposeViewModel {
    public nonisolated enum State: Equatable, Sendable {
        case editing
        case uploading
        case finished
        case failed(message: String)
    }

    public private(set) var state: State = .editing {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?

    public private(set) var pickedImage: UIImage?
    public private(set) var pickedVideoURL: URL?
    public var caption: String = ""

    private let composer: any PostComposing
    private var submission: Task<Void, Never>?

    public init(composer: any PostComposing) {
        self.composer = composer
    }

    public var hasMedia: Bool { pickedImage != nil || pickedVideoURL != nil }

    public var canPost: Bool {
        state != .uploading && (hasMedia || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func setImage(_ image: UIImage?) {
        pickedImage = image
        if image != nil { pickedVideoURL = nil } // media kinds are mutually exclusive
        // Nudge observers so the Post button re-evaluates `canPost`.
        if state == .editing { state = .editing }
    }

    public func setVideo(_ url: URL?) {
        pickedVideoURL = url
        if url != nil { pickedImage = nil }
        if state == .editing { state = .editing }
    }

    private var composeMedia: ComposeMedia? {
        if let pickedImage { return .image(PickedImage(pickedImage)) }
        if let pickedVideoURL { return .video(PickedVideo(sourceURL: pickedVideoURL)) }
        return nil
    }

    public func post() {
        guard canPost, state != .uploading else { return }
        state = .uploading

        let media = composeMedia
        let caption = caption
        submission = Task {
            do {
                try await composer.publish(media: media, caption: caption)
                state = .finished
            } catch let error as ComposeError {
                state = .failed(message: Self.message(for: error))
            } catch {
                state = .failed(message: "Couldn't share your post. Try again.")
            }
        }
    }

    private static func message(for error: ComposeError) -> String {
        switch error {
        case .emptyPost:
            "Add a photo or video, or write something first."
        case .notAuthenticated, .noViewerProfile:
            "Your session expired. Sign in again."
        case .media:
            "Your media couldn't be uploaded. Try again."
        case .transport:
            "Couldn't reach the server. Check your connection."
        }
    }
}
