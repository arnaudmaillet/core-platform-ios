import CoreGraphics
import Foundation

/// Where an overlay sits on the finished picture, how big it is and how it is
/// turned.
///
/// ⚠️ **FRACTIONS OF THE FINISHED — CROPPED — FRAME, ORIGIN TOP-LEFT.** The
/// editor places overlays on the picture the author sees, which is the picture
/// after its crop; storing them against the uncut source would move every
/// overlay the next time the crop changed. Core Image's origin is bottom-left,
/// so `OverlayRasterizer` flips `centre.y` on its way in — and its tests use a
/// top and a bottom placement, because a flip mistake still draws something.
public struct OverlayPlacement: Equatable, Sendable {
    /// The overlay's centre, `(0,0)` top-left and `(1,1)` bottom-right.
    public var centre: CGPoint
    /// 1 is the content's base size, which is itself a fraction of the frame's
    /// width (`OverlayRasterizer`), so an overlay keeps its proportion at any
    /// output size.
    public var scale: Double
    /// Radians, clockwise as the viewer sees it.
    public var rotation: Double

    public init(centre: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: Double = 1, rotation: Double = 0) {
        self.centre = centre
        self.scale = scale
        self.rotation = rotation
    }

    /// In the middle, at its base size, upright.
    public static let centred = OverlayPlacement()
}

/// An ink, in sRGB components from 0 to 1.
public struct OverlayColour: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = OverlayColour(r: 1, g: 1, b: 1)
    public static let black = OverlayColour(r: 0, g: 0, b: 0)
}

/// The typefaces text can be set in. `OverlayRasterizer` resolves each to a
/// real font, and a test checks that every case does.
public enum OverlayFont: String, CaseIterable, Sendable {
    case classic, rounded, serif, mono, condensed, marker, typewriter, script
}

/// What is drawn behind text: nothing, a band behind each line, or one box
/// behind the whole block.
public enum TextBackground: String, CaseIterable, Sendable {
    case none, highlight, box
}

/// How the lines of a text block line up.
public enum OverlayTextAlignment: String, CaseIterable, Sendable {
    case leading, centre, trailing
}

/// Words laid over a picture, and how they are dressed.
public struct TextOverlay: Equatable, Sendable {
    public var text: String
    public var font: OverlayFont
    public var colour: OverlayColour
    public var background: TextBackground
    public var alignment: OverlayTextAlignment

    public init(
        text: String, font: OverlayFont = .classic, colour: OverlayColour = .white,
        background: TextBackground = .none, alignment: OverlayTextAlignment = .centre
    ) {
        self.text = text
        self.font = font
        self.colour = colour
        self.background = background
        self.alignment = alignment
    }
}

/// One thing laid over a picture: text, an emoji or a sticker.
///
/// ⚠️ **THE ARRAY'S ORDER IS THE Z-ORDER.** The first overlay is drawn first,
/// so the last one is on top — "bring to front" is a move to the end, and no
/// field says it.
///
/// ⚠️ **VERSION 1 COVERS THE WHOLE FILM.** There is no time range: an overlay on
/// a video shows from the first frame to the last. The compositor already
/// receives the composition's time, so a window is a small addition when a
/// screen can set one — and an unset field would be dead code until then.
public struct FrameOverlay: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case text(TextOverlay)
        /// One emoji, as the string that draws it.
        case emoji(String)
        /// A sticker, by its catalogue identifier. The pictures come from an
        /// `OverlayArtwork`, never from this package.
        case sticker(id: String)
    }

    /// Made by the editor — a UUID string — and never reused.
    public let id: String
    public var content: Content
    public var placement: OverlayPlacement

    public init(id: String = UUID().uuidString, content: Content, placement: OverlayPlacement = .centred) {
        self.id = id
        self.content = content
        self.placement = placement
    }
}

/// Sticker pictures, handed in by whoever can draw them.
///
/// ⚠️ **THIS PACKAGE NEVER IMPORTS LOTTIE.** Lottie renders on the main actor
/// only, and a compositor asks for frames on its own queue at 30 or 60 a
/// second. Frames therefore arrive already baked, and this protocol is how a
/// renderer asks for one — from any thread, hence `Sendable`.
public protocol OverlayArtwork: Sendable {
    /// The sticker `id` as it looks `seconds` into its own loop, `side` pixels
    /// square. Nil when the sticker is unknown or not baked; the renderer then
    /// skips that sticker and draws everything else.
    func sticker(_ id: String, atSeconds seconds: Double, side: Int) -> CGImage?
}
