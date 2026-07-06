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
    public var caption: String = ""

    private let composer: any PostComposing
    private var submission: Task<Void, Never>?

    public init(composer: any PostComposing) {
        self.composer = composer
    }

    public var canPost: Bool {
        state != .uploading && (pickedImage != nil || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public func setImage(_ image: UIImage?) {
        pickedImage = image
        // Nudge observers so the Post button re-evaluates `canPost`.
        if state == .editing { state = .editing }
    }

    public func post() {
        guard canPost, state != .uploading else { return }
        state = .uploading

        let picked = pickedImage.map { PickedImage($0) }
        let caption = caption
        submission = Task {
            do {
                try await composer.publish(image: picked, caption: caption)
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
            "Add a photo or write something first."
        case .notAuthenticated, .noViewerProfile:
            "Your session expired. Sign in again."
        case .media:
            "Your photo couldn't be uploaded. Try again."
        case .transport:
            "Couldn't reach the server. Check your connection."
        }
    }
}
