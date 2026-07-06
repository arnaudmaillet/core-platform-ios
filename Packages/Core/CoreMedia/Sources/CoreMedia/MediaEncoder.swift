import CryptoKit
import Foundation
import UIKit

/// Encoded, upload-ready image bytes plus the metadata the media.v1 upload
/// ticket flow requires (declared mime/size and a content SHA-256 for
/// server-side dedupe and integrity).
public struct EncodedImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let sha256Hex: String

    public var byteSize: UInt64 { UInt64(data.count) }
}

/// Prepares a picked `UIImage` for upload: fixes orientation, downscales to a
/// max edge, JPEG-encodes, and hashes. Pure and `Sendable`; callers run it off
/// the main actor.
public struct MediaEncoder: Sendable {
    public static let defaultMaxDimension = 2048

    private let maxDimension: Int
    private let jpegQuality: CGFloat

    public init(maxDimension: Int = MediaEncoder.defaultMaxDimension, jpegQuality: CGFloat = 0.82) {
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    public enum EncodingError: Error, Equatable {
        case encodingFailed
    }

    public func encode(_ image: UIImage) throws -> EncodedImage {
        let normalized = downscaled(image)
        guard let data = normalized.jpegData(compressionQuality: jpegQuality) else {
            throw EncodingError.encodingFailed
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return EncodedImage(
            data: data,
            mimeType: "image/jpeg",
            pixelWidth: Int(normalized.size.width * normalized.scale),
            pixelHeight: Int(normalized.size.height * normalized.scale),
            sha256Hex: hex
        )
    }

    private func downscaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestEdge = max(pixelWidth, pixelHeight)
        guard longestEdge > CGFloat(maxDimension) else {
            // Still redraw to bake in orientation (jpegData ignores it otherwise).
            return redraw(image, pixelSize: CGSize(width: pixelWidth, height: pixelHeight))
        }
        let ratio = CGFloat(maxDimension) / longestEdge
        return redraw(image, pixelSize: CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded()))
    }

    private func redraw(_ image: UIImage, pixelSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // pixelSize is already in pixels
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }
}
