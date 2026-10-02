import Testing
import UIKit
@testable import Feed

/// The composer's FIELD, asked 2026-10-02: the send arrow one blue on every
/// host, the trailing glyphs never shaved by their containers at any text
/// size, 44pt targets around them, and a field that grows and shrinks with
/// its lines in an animation rather than a jump.
@MainActor
struct CommentsInputBarFieldTests {
    /// A bar on a real window's root view — the field's growth animates only
    /// in a window, and runs its layout in the nearest controller's view.
    private func hostedBar(
        category: UIContentSizeCategory = .large,
        hostTint: UIColor? = nil
    ) -> (CommentsInputBar, UIViewController, UIWindow) {
        let screen = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.traitOverrides.preferredContentSizeCategory = category
        window.rootViewController = screen
        window.isHidden = false
        if let hostTint { screen.view.tintColor = hostTint }
        let bar = CommentsInputBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: screen.view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: screen.view.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: screen.view.bottomAnchor, constant: -40),
        ])
        screen.view.layoutIfNeeded()
        return (bar, screen, window)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func removeAllAnimations(in view: UIView) {
        view.layer.removeAllAnimations()
        for subview in view.subviews { removeAllAnimations(in: subview) }
    }

    private static func isAnimated(_ view: UIView) -> Bool {
        !(view.layer.animationKeys() ?? []).isEmpty
    }

    private static func resolved(_ color: UIColor?, _ style: UIUserInterfaceStyle) -> UIColor? {
        color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    // MARK: - Send tint

    /// ⚠️ NAMED, NOT INHERITED. The arrow was `.tintColor`, which resolves
    /// against the button's ancestors — grey in a conversation, blue on the
    /// post. A host tinting its view grey leaves it blue now.
    @Test func theSendArrowIsSystemBlueWhateverTheHostsTint() throws {
        for tint in [nil, UIColor.systemGray, UIColor.label] as [UIColor?] {
            let (bar, _, window) = hostedBar(hostTint: tint)
            defer { window.isHidden = true }
            bar.draftText = "Hello"
            #expect(bar.debugFieldActionSymbol == CommentsInputBar.sendSymbol)
            let action = bar.debugFieldActionButton
            let color = action.configuration?.baseForegroundColor
            for style in [UIUserInterfaceStyle.light, .dark] {
                #expect(Self.resolved(color, style) == Self.resolved(.systemBlue, style),
                        "send is \(String(describing: color)) under a \(String(describing: tint)) host")
            }
            // What the glyph is DRAWN in — `.tintColor` as a configuration
            // colour resolves to blue on its own and only turns grey here,
            // against the button's ancestors.
            action.layoutIfNeeded()
            let drawn = try #require(
                Self.descendants(of: action).compactMap { $0 as? UIImageView }.first { $0.image != nil }
            )
            #expect(drawn.tintColor.resolvedColor(with: action.traitCollection)
                == UIColor.systemBlue.resolvedColor(with: action.traitCollection),
                    "drawn in \(String(describing: drawn.tintColor)) under a \(String(describing: tint)) host")
            // The waveform stays the field's quiet ink.
            bar.draftText = ""
            #expect(bar.debugFieldActionButton.configuration?.baseForegroundColor == .secondaryLabel)
        }
        #expect(CommentsInputBar.sendTint == .systemBlue)
    }

    // MARK: - Trailing glyphs

    /// Every face of the field's two trailing buttons — the emote face and
    /// its keyboard face, the waveform, the send disc, the send's spinner —
    /// drawn WHOLE inside its button, and each button inside the field, at
    /// every text size from the smallest to the largest accessibility size.
    /// The send disc stands concentric with the field's trailing cap.
    @Test(arguments: [
        UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityExtraExtraExtraLarge,
    ])
    func everyTrailingGlyphFitsItsContainer(category: UIContentSizeCategory) throws {
        let (bar, screen, window) = hostedBar(category: category)
        defer { window.isHidden = true }
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        let action = bar.debugFieldActionButton
        let toggle = try #require(
            field.contentView.subviews.compactMap { $0 as? UIButton }.first { $0 !== action }
        )

        func expectWhole(_ button: UIButton, _ face: String) throws {
            screen.view.layoutIfNeeded()
            button.layoutIfNeeded()
            let inField = button.convert(button.bounds, to: field.contentView)
            #expect(field.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inField),
                    "\(face) @\(category.rawValue): the button \(inField) leaves the field \(field.bounds)")
            let glyphs = Self.descendants(of: button).filter {
                !$0.isHidden && $0.alpha > 0.01 && ($0 is UIImageView || $0 is UIActivityIndicatorView)
            }
            try #require(!glyphs.isEmpty, "\(face) @\(category.rawValue): nothing drawn")
            for glyph in glyphs {
                let frame = glyph.convert(glyph.bounds, to: button)
                #expect(button.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                        "\(face) @\(category.rawValue): \(frame) clipped by its \(button.bounds.size) button")
                if let image = (glyph as? UIImageView)?.image {
                    #expect(frame.width >= image.size.width - 0.5 && frame.height >= image.size.height - 0.5,
                            "\(face) @\(category.rawValue): \(image.size) squeezed into \(frame.size)")
                }
            }
        }

        try expectWhole(toggle, "emote face")
        try expectWhole(action, "waveform")
        bar.draftText = "Hello"
        try expectWhole(action, "send")
        // Concentric with the cap: the cap's circle is the field's last
        // `controlSize` square, bottom-anchored like the button.
        let cap = CommentsInputBar.Metrics.controlSize
        let disc = action.convert(action.bounds, to: field)
        #expect(abs(disc.midX - (field.bounds.width - cap / 2)) < 0.5)
        #expect(abs(disc.midY - (field.bounds.height - cap / 2)) < 0.5)

        bar.isSending = true
        try expectWhole(action, "spinner")
        bar.isSending = false

        // The emote panel's face (EmoteKit swaps the toggle's image to the
        // keyboard glyph, its widest), with the toggle's own weight.
        toggle.setImage(
            UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(weight: .medium)),
            for: .normal
        )
        try expectWhole(toggle, "keyboard face")
    }

    /// The glyphs hold one size at every text size (a bar's rule), the large
    /// content viewer standing in for scaling.
    @Test func theTrailingGlyphsDoNotScaleWithTheText() throws {
        func widths(_ category: UIContentSizeCategory) throws -> [CGFloat] {
            let (bar, screen, window) = hostedBar(category: category)
            defer { window.isHidden = true }
            let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
            let action = bar.debugFieldActionButton
            let toggle = try #require(
                field.contentView.subviews.compactMap { $0 as? UIButton }.first { $0 !== action }
            )
            screen.view.layoutIfNeeded()
            #expect(toggle.showsLargeContentViewer && action.showsLargeContentViewer)
            // The spinner too: it sizes itself by the button's text size
            // (63pt at XXXL on iOS 26), so the buttons read the default one.
            for button in [toggle, action] {
                #expect(button.traitCollection.preferredContentSizeCategory <= .large,
                        "\(category.rawValue): the button reads \(button.traitCollection.preferredContentSizeCategory.rawValue)")
            }
            return [toggle, action].compactMap { button in
                button.layoutIfNeeded()
                return Self.descendants(of: button).compactMap { $0 as? UIImageView }
                    .first { $0.image != nil }?.image?.size.width
            }
        }
        let small = try widths(.large)
        let huge = try widths(.accessibilityExtraExtraExtraLarge)
        #expect(small.count == 2)
        #expect(small == huge, "the glyphs scaled with the text: \(small) → \(huge)")
    }

    /// The emote toggle and the field button answer to a 44pt target around
    /// what they draw — the 38pt line cannot hold one.
    @Test func theFieldButtonsAnswerToA44ptTarget() throws {
        let (bar, _, window) = hostedBar()
        defer { window.isHidden = true }
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        let action = bar.debugFieldActionButton
        let toggle = try #require(
            field.contentView.subviews.compactMap { $0 as? UIButton }.first { $0 !== action }
        )
        let reach = CommentsInputBar.Metrics.minimumHitSide / 2 - 0.5
        for (button, outward) in [(action, CGFloat(1)), (toggle, -1)] {
            let frame = button.convert(button.bounds, to: bar)
            #expect(frame.height < CommentsInputBar.Metrics.minimumHitSide, "guard: the line is shorter than 44")
            let points = [
                CGPoint(x: frame.midX, y: frame.midY - reach),
                CGPoint(x: frame.midX, y: frame.midY + reach),
                CGPoint(x: frame.midX + outward * max(frame.width / 2, reach), y: frame.midY),
            ]
            for point in points {
                #expect(bar.hitTest(point, with: nil) === button,
                        "\(button.accessibilityLabel ?? "-") missed at \(point) (frame \(frame))")
            }
        }
        // Well outside both, the field's own touches are untouched.
        let text = CGPoint(x: field.frame.minX + 40, y: field.frame.midY)
        #expect(bar.hitTest(text, with: nil) !== action && bar.hitTest(text, with: nil) !== toggle)
    }

    // MARK: - Growth

    /// ⚠️ A LINE BREAK ANIMATES. The field's new height lands in a spring
    /// with its host's layout — the bar growing, the column standing still
    /// in the window — and so does the way back down. Model frames are final
    /// at once (the hosts and their tests read them), the motion is the
    /// layers'.
    @Test func aLineBreakGrowsTheFieldInASpringAndShrinksItBack() throws {
        let (bar, screen, window) = hostedBar()
        defer { window.isHidden = true }
        // The conversation's column (the slot alone), which three lines
        // outgrow — so the bar's own height moves too.
        bar.showsStake = false
        screen.view.layoutIfNeeded()
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        let rail = bar.debugRailButton
        bar.draftText = "One line"
        screen.view.layoutIfNeeded()
        Self.removeAllAnimations(in: window)
        let oneLine = field.bounds.height
        let railAtRest = rail.convert(rail.bounds, to: window)

        bar.draftText = "One line\nTwo\nThree"
        #expect(field.bounds.height > oneLine + 20, "guard: the draft grew the field")
        let grow = try #require(field.layer.animationKeys()?.compactMap { field.layer.animation(forKey: $0) }.first)
        #expect(grow is CASpringAnimation, "the growth is not a spring: \(grow)")
        #expect(Self.isAnimated(bar), "the bar's own height jumped")
        let railNow = rail.convert(rail.bounds, to: window)
        #expect(abs(railNow.minY - railAtRest.minY) < 0.5 && abs(railNow.minX - railAtRest.minX) < 0.5,
                "the column moved with the field: \(railNow) vs \(railAtRest)")

        Self.removeAllAnimations(in: window)
        bar.draftText = ""
        #expect(abs(field.bounds.height - oneLine) < 0.5)
        #expect(Self.isAnimated(field), "the field snapped back down")
    }

    /// ⚠️ A DRAFT SET BEFORE THE FIRST LAYOUT SIZES IN THAT LAYOUT — in no
    /// window at all. The height used to be measured off the text view, which
    /// has no width on the bar's first pass (it lays out inside the field's
    /// content view, after the bar), so it stayed one line until something
    /// else laid the bar out again — seen off a window on iOS 27 and in a
    /// window on the iOS 26.2 host (CI). Measured at the field's width now.
    @Test func aDraftSetBeforeTheFirstLayoutSizesInThatLayout() throws {
        let bar = CommentsInputBar()
        bar.draftText = "One\nTwo\nThree"
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        host.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        #expect(field.bounds.height > CommentsInputBar.Metrics.controlSize + 20,
                "three lines, one line tall: \(field.bounds.height)")
    }

    /// A draft set before the bar is on screen (a prefill, a restored draft)
    /// takes its height in the first layout on screen, at once: there is
    /// nothing to watch grow.
    @Test func aDraftSetOffscreenTakesItsHeightWithoutAnAnimation() throws {
        let bar = CommentsInputBar()
        bar.draftText = "One\nTwo\nThree"
        let screen = UIViewController()
        bar.translatesAutoresizingMaskIntoConstraints = false
        screen.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: screen.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: screen.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: screen.view.bottomAnchor),
        ])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        defer { window.isHidden = true }
        window.rootViewController = screen
        window.isHidden = false
        screen.view.layoutIfNeeded()
        let field = try #require(SnapActionColumnLayoutTests.fieldView(in: bar))
        #expect(field.bounds.height > CommentsInputBar.Metrics.controlSize + 20)
        #expect(!Self.isAnimated(field))
    }
}
