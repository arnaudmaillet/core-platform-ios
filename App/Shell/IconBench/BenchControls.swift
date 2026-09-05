#if DEBUG
import UIKit

/// The instrument's own chrome: the readout and the knobs.
///
/// Split out so the measuring logic stays readable — and because a
/// benchmark whose controls outweigh its measurements is a UI, not an
/// instrument.
extension AnimatedIconBenchViewController {

    // MARK: - Chrome

    func setUpHUD() {
        hudBackdrop.layer.cornerRadius = 12
        hudBackdrop.layer.cornerCurve = .continuous
        hudBackdrop.clipsToBounds = true
        hudBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudBackdrop)

        hud.numberOfLines = 0
        hud.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        hud.textColor = .white
        hud.translatesAutoresizingMaskIntoConstraints = false
        hudBackdrop.contentView.addSubview(hud)

        NSLayoutConstraint.activate([
            hudBackdrop.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hudBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            hudBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            hud.topAnchor.constraint(equalTo: hudBackdrop.contentView.topAnchor, constant: 8),
            hud.leadingAnchor.constraint(equalTo: hudBackdrop.contentView.leadingAnchor, constant: 10),
            hud.trailingAnchor.constraint(equalTo: hudBackdrop.contentView.trailingAnchor, constant: -10),
            hud.bottomAnchor.constraint(equalTo: hudBackdrop.contentView.bottomAnchor, constant: -8)
        ])
    }

    func setUpControls() {
        toggleControlsButton.setTitle("controls", for: .normal)
        toggleControlsButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        toggleControlsButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toggleControlsButton.tintColor = .white
        toggleControlsButton.layer.cornerRadius = 12
        toggleControlsButton.configuration = nil
        toggleControlsButton.addTarget(self, action: #selector(toggleControls), for: .touchUpInside)
        toggleControlsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleControlsButton)

        controlsScroll.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        controlsScroll.layer.cornerRadius = 12
        controlsScroll.layer.cornerCurve = .continuous
        controlsScroll.isHidden = true
        controlsScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsScroll)

        controls.axis = .vertical
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsScroll.addSubview(controls)

        // `.defaultLow`, deliberately — and the priority is the whole subtlety.
        //
        // Nothing else gives this scroll view a height, so without a constraint
        // here it resolves to ZERO and the panel is invisible rather than
        // broken-looking. But at `.defaultHigh` it beats the segments' own
        // compression resistance (750): once the stack is taller than the 300pt
        // cap, Auto Layout minimises the violation by SQUASHING the stack, and
        // the lower rows render on top of each other instead of scrolling.
        // Below 750 it loses that fight, so tall content scrolls and short
        // content still gets a height.
        let heightFromContent = controlsScroll.heightAnchor.constraint(
            equalTo: controls.heightAnchor, constant: 20
        )
        heightFromContent.priority = .defaultLow

        NSLayoutConstraint.activate([
            toggleControlsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            toggleControlsButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            toggleControlsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            toggleControlsButton.heightAnchor.constraint(equalToConstant: 30),
            controlsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            controlsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            controlsScroll.bottomAnchor.constraint(equalTo: toggleControlsButton.topAnchor, constant: -8),
            controlsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 300),
            // WITHOUT THIS the panel is invisible rather than broken-looking: a
            // scroll view anchored only at its bottom, with a `<=` height and a
            // content layout guide, resolves its own height to ZERO. The button
            // toggles `isHidden` correctly and nothing appears.
            heightFromContent,
            controls.topAnchor.constraint(equalTo: controlsScroll.contentLayoutGuide.topAnchor, constant: 10),
            controls.bottomAnchor.constraint(equalTo: controlsScroll.contentLayoutGuide.bottomAnchor, constant: -10),
            controls.leadingAnchor.constraint(equalTo: controlsScroll.frameLayoutGuide.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: controlsScroll.frameLayoutGuide.trailingAnchor, constant: -10)
        ])

        let varieties = [1, 4, 16, 64, -1]
        addSegment("variety (distinct icons)", ["1", "4", "16", "64", "all"],
                   selected: varieties.firstIndex(of: config.variety) ?? 2) { [weak self] index in
            self?.config.variety = varieties[index]
            self?.rebuildLattice()
        }
        addSegment("clock", ["quantised", "free-running"],
                   selected: config.mode == .quantised ? 0 : 1) { [weak self] index in
            self?.config.mode = index == 0 ? .quantised : .freeRunning
            self?.rebuildLattice()
        }
        let rates: [Double] = [12, 15, 20, 30]
        addSegment("fps (frames scale with it now)", ["12", "15", "20", "30"],
                   selected: rates.firstIndex(of: config.framesPerSecond) ?? 3) { [weak self] index in
            self?.config.framesPerSecond = rates[index]
            self?.rebuildLattice()
        }
        addSegment("shadow", ["shadowPath", "pathless (today)"],
                   selected: config.usesShadowPath ? 0 : 1) { [weak self] index in
            self?.config.usesShadowPath = index == 0
            self?.rebuildLattice()
        }
        addSegment("mask", ["baked circle", "clip on card (today)"],
                   selected: config.masksOnCard ? 1 : 0) { [weak self] index in
            self?.config.masksOnCard = index == 1
            self?.rebuildLattice()
        }
        addSegment("texture", ["shared", "distinct per instance"],
                   selected: config.sharesTexture ? 0 : 1) { [weak self] index in
            self?.config.sharesTexture = index == 0
            self?.rebuildLattice()
        }
        let wires = IconAtlasStore.WireFormat.allCases
        addSegment("wire format (still = 1 picture + a motion track)", wires.map(\.rawValue),
                   selected: wires.firstIndex(of: config.wireFormat) ?? 0) { [weak self] index in
            self?.config.wireFormat = wires[index]
            self?.rebuildLattice()
        }
        let samplings = IconPlayback.Sampling.allCases
        addSegment("sampling (still only — free in memory, paid in composites)",
                   samplings.map(\.rawValue),
                   selected: samplings.firstIndex(of: config.sampling) ?? 0) { [weak self] index in
            self?.config.sampling = samplings[index]
            self?.rebuildLattice()
        }
        let latencies: [TimeInterval] = [0, 0.35, 1.5]
        addSegment("load latency", ["0", "0.35s", "1.5s"],
                   selected: latencies.firstIndex(of: config.latency) ?? 1) { [weak self] index in
            self?.config.latency = latencies[index]
            self?.rebuildLattice()
        }
        addSegment("ground", ["MapKit", "plain"],
                   selected: config.showsMap ? 0 : 1) { [weak self] index in
            guard let self else { return }
            self.config.showsMap = index == 0
            self.mapView.alpha = self.config.showsMap ? 1 : 0
            self.plainBackdrop.isHidden = self.config.showsMap
            self.resetMeasurement()
            self.dressCompletedIn = 0     // already dressed; go straight to measuring
        }
        addSegment("surface (chat packs 5x the map's count)", ["map 44pt", "chat emotes 22pt"],
                   selected: config.emoteDensity ? 1 : 0) { [weak self] index in
            self?.config.emoteDensity = index == 1
            self?.rebuildLattice()
        }
        // The simulator cannot switch on Low Power, so the policy has to be
        // forceable or its two interesting states are untestable here.
        let policies = IconPlayback.MotionPolicy.allCases
        addSegment("motion policy (60fps / half / posed)", policies.map(\.rawValue),
                   selected: policies.firstIndex(of: IconPlayback.policy) ?? 0) { [weak self] index in
            IconPlayback.forcedPolicy = policies[index]
            self?.rebuildLattice()
        }
        addSegment("pan", ["still", "auto-pan"],
                   selected: config.autoPans ? 1 : 0) { [weak self] index in
            guard let self else { return }
            self.config.autoPans = index == 1
            self.resetMeasurement()
            self.dressCompletedIn = 0
        }
    }

    func addSegment(
        _ title: String,
        _ items: [String],
        selected: Int,
        onChange: @escaping (Int) -> Void
    ) {
        let label = UILabel()
        label.text = title
        label.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.65)

        let segment = UISegmentedControl(items: items)
        segment.selectedSegmentIndex = selected
        segment.selectedSegmentTintColor = .systemBlue
        segment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        segment.addAction(UIAction { [weak segment] _ in
            guard let segment else { return }
            onChange(segment.selectedSegmentIndex)
        }, for: .valueChanged)

        controls.addArrangedSubview(label)
        controls.addArrangedSubview(segment)
    }

    @objc func toggleControls() {
        controlsScroll.isHidden.toggle()
    }
}
#endif
