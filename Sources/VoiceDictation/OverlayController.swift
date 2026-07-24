import AppKit
import DictationCore

/// A non-activating floating panel that never becomes key or main. This is the
/// linchpin of the overlay's correctness: the app is an `.accessory` that pastes
/// into whatever app is frontmost via synthetic Cmd+V, so the HUD must never
/// steal focus or the paste lands in the wrong place. We show it with
/// `orderFrontRegardless()`, never `makeKeyAndOrderFront`.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The on-screen recording HUD. Appears at bottom-centre of the screen under the
/// mouse whenever the app is recording / transcribing / inserting (or needs
/// attention), and fades out shortly after returning to idle. Driven off the
/// single `DictationController` status stream so it stays in lockstep with the
/// menu-bar icon.
@MainActor
final class OverlayController {

    private let panel: OverlayPanel
    private let container: NSVisualEffectView
    private let dot: PulsingDot
    private let label: NSTextField

    /// Pending fade-out after the app returns to idle (cancelled if a new active
    /// state arrives first).
    private var hideWorkItem: DispatchWorkItem?
    /// Pending auto-hide for a transient banner (the launch greeting).
    private var bannerWorkItem: DispatchWorkItem?

    private let horizontalPadding: CGFloat = 18
    private let verticalPadding: CGFloat = 12
    private let dotSize: CGFloat = 10
    private let dotGap: CGFloat = 10
    /// Margin above the Dock / bottom of the usable screen.
    private let bottomMargin: CGFloat = 84

    init() {
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0

        // Rounded, translucent HUD chrome that follows light/dark automatically.
        container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        dot = PulsingDot(diameter: dotSize)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(dot)
        container.addSubview(label)
        panel.contentView = container

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalPadding),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: dotGap),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalPadding),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalPadding),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalPadding),
        ])
    }

    // MARK: - Status driven

    /// Update the overlay for a new app status. Called on every status change.
    func apply(status: AppStatus) {
        bannerWorkItem?.cancel()
        bannerWorkItem = nil

        guard let presentation = OverlayViewModel.presentation(for: status) else {
            // Idle: linger briefly, then fade out.
            scheduleHide(after: OverlayViewModel.idleHideDelay)
            return
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        render(presentation)
        show()
    }

    /// Show a transient informational banner (e.g. the launch greeting) that is
    /// not tied to an app status, then auto-dismiss it.
    func showBanner(_ text: String, duration: TimeInterval) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        render(OverlayViewModel.Presentation(label: text, accent: .info, showsPulse: false))
        show()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        bannerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Rendering

    private func render(_ presentation: OverlayViewModel.Presentation) {
        label.stringValue = presentation.label
        if presentation.showsPulse {
            dot.isHidden = false
            dot.color = color(for: presentation.accent)
            dot.startPulsing()
        } else {
            dot.stopPulsing()
            dot.isHidden = true
        }
        layoutToFit()
    }

    private func color(for accent: OverlayViewModel.Accent) -> NSColor {
        switch accent {
        case .recording: return .systemRed
        case .working: return .systemBlue
        case .info: return .systemGreen
        case .warning: return .systemOrange
        }
    }

    /// Size the panel to its content and position it bottom-centre on the screen
    /// under the mouse, comfortably above the Dock.
    private func layoutToFit() {
        container.layoutSubtreeIfNeeded()
        let labelSize = label.intrinsicContentSize
        let dotWidth = dot.isHidden ? 0 : (dotSize + dotGap)
        let width = horizontalPadding + dotWidth + labelSize.width + horizontalPadding
        let height = verticalPadding + max(labelSize.height, dotSize) + verticalPadding

        let screen = screenUnderMouse()
        let visible = screen.visibleFrame
        let x = visible.midX - width / 2
        let y = visible.minY + bottomMargin
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    // MARK: - Show / hide (never activating)

    private func show() {
        // CRITICAL: order front WITHOUT taking key/main focus so the frontmost
        // app - the paste target - does not change.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = OverlayViewModel.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dot.stopPulsing()
            self?.panel.orderOut(nil)
        })
    }
}

/// A small filled circle that pulses its opacity while recording. Pure Core
/// Animation so it costs nothing when idle.
private final class PulsingDot: NSView {
    private let circle = CALayer()

    var color: NSColor = .systemRed {
        didSet { circle.backgroundColor = color.cgColor }
    }

    init(diameter: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        circle.frame = bounds
        circle.cornerRadius = diameter / 2
        circle.backgroundColor = color.cgColor
        layer?.addSublayer(circle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        circle.frame = bounds
        circle.cornerRadius = bounds.width / 2
    }

    func startPulsing() {
        guard circle.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        circle.add(pulse, forKey: "pulse")
    }

    func stopPulsing() {
        circle.removeAnimation(forKey: "pulse")
    }
}
