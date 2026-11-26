import AppKit
import QuartzCore
import SwiftUI

/// Looping decorations (pulses travelling along a lane, the ring around a busy status dot) run
/// as Core Animation animations. The render server moves them, so the app does no work per
/// frame. A SwiftUI clock (`TimelineView`) re-evaluated and re-measured the whole window 30
/// times a second instead, which kept the main thread busy and made everything else stutter.
@MainActor
enum Motion {
    /// Off for offscreen snapshots, which can't capture Core Animation layers: they get a still frame.
    static var isLive = true
}

// MARK: - Dashes flowing along a path

/// A dash pattern that streams along its path.
struct DashFlowPattern: Equatable {
    var dash: CGFloat
    var period: CGFloat
    /// Points per second.
    var speed: CGFloat
    /// Toward the end of the path, or toward its start.
    var forward: Bool
    /// 0..<1 of a period, so neighbouring paths don't march in step.
    var offset: CGFloat = 0

    var startPhase: CGFloat { (forward ? -1 : 1) * offset * period }
}

/// Strokes `shape` with dashes that stream along it.
struct DashFlow<S: Shape>: View {
    var shape: S
    var color: Color
    var lineWidth: CGFloat
    var pattern: DashFlowPattern

    var body: some View {
        if Motion.isLive {
            DashFlowRepresentable(shape: shape, color: color, lineWidth: lineWidth, pattern: pattern)
        } else {
            shape.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                   dash: [pattern.dash, pattern.period - pattern.dash],
                                                   dashPhase: pattern.startPhase))
        }
    }
}

private struct DashFlowRepresentable<S: Shape>: NSViewRepresentable {
    var shape: S
    var color: Color
    var lineWidth: CGFloat
    var pattern: DashFlowPattern

    func makeNSView(context: Context) -> DashFlowView { DashFlowView() }

    func updateNSView(_ view: DashFlowView, context: Context) {
        let shape = shape
        view.update(path: { shape.path(in: $0).cgPath }, color: color, lineWidth: lineWidth, pattern: pattern)
    }
}

/// Sublayers of a view aren't managed by AppKit, so their implicit animations must be turned off.
private let noImplicitAnimations: [String: any CAAction] = [
    "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeColor": NSNull(),
    "lineWidth": NSNull(), "lineDashPattern": NSNull(), "lineDashPhase": NSNull(), "opacity": NSNull(), "transform": NSNull(),
]

/// Resolves a SwiftUI color for a view's current light/dark appearance.
@MainActor
private func resolvedColor(_ color: Color, opacity: CGFloat = 1, for view: NSView) -> CGColor? {
    var resolved: CGColor?
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(color).cgColor
    }
    guard let resolved else { return nil }
    return opacity < 1 ? resolved.copy(alpha: resolved.alpha * opacity) : resolved
}

/// Starts a looping animation part-way through its cycle, keyed to the clock, so copies that
/// appear at different times (or are rebuilt) stay in step instead of jumping back to the start.
private func keyedToClock(_ animation: CAAnimation) {
    animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: animation.duration)
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
}

final class DashFlowView: NSView {
    private let line = CAShapeLayer()
    private var makePath: ((CGRect) -> CGPath)?
    private var color: Color?
    private var pattern: DashFlowPattern?
    private static let key = "flow"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.fillColor = nil
        line.lineCap = .round
        line.actions = noImplicitAnimations
        layer?.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Same coordinates as SwiftUI shapes: origin top left.
    override var isFlipped: Bool { true }
    // Purely decorative: clicks and tooltips belong to the views around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(path: @escaping (CGRect) -> CGPath, color: Color, lineWidth: CGFloat, pattern: DashFlowPattern) {
        makePath = path
        line.path = path(bounds)
        line.lineWidth = lineWidth
        if color != self.color {
            self.color = color
            line.strokeColor = resolvedColor(color, for: self)
        }
        if pattern != self.pattern {
            self.pattern = pattern
            startAnimation()
        }
    }

    override func layout() {
        super.layout()
        line.frame = bounds
        line.path = makePath?(bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let color { line.strokeColor = resolvedColor(color, for: self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, line.animation(forKey: Self.key) == nil { startAnimation() }
    }

    private func startAnimation() {
        line.removeAnimation(forKey: Self.key)
        guard let pattern else { return }
        line.lineDashPattern = [NSNumber(value: Double(pattern.dash)), NSNumber(value: Double(pattern.period - pattern.dash))]
        line.lineDashPhase = pattern.startPhase
        guard pattern.speed > 0, pattern.period > 0 else { return }
        let flow = CABasicAnimation(keyPath: "lineDashPhase")
        flow.fromValue = pattern.startPhase
        flow.toValue = pattern.startPhase + (pattern.forward ? -pattern.period : pattern.period)
        flow.duration = Double(pattern.period / pattern.speed)
        keyedToClock(flow)
        line.add(flow, forKey: Self.key)
    }
}

// MARK: - Ripple ring

/// A ring that grows out of its frame's center and fades, over and over.
struct PulsingRing: View {
    var color: Color
    var opacity: CGFloat = 1
    var lineWidth: CGFloat = 1.5
    var period: Double = 1.4

    var body: some View {
        if Motion.isLive {
            PulsingRingRepresentable(color: color, opacity: opacity, lineWidth: lineWidth, period: period)
        } else {
            Circle()
                .stroke(color.opacity(opacity), lineWidth: lineWidth)
                .scaleEffect(0.75)
                .opacity(0.5)
        }
    }
}

private struct PulsingRingRepresentable: NSViewRepresentable {
    var color: Color
    var opacity: CGFloat
    var lineWidth: CGFloat
    var period: Double

    func makeNSView(context: Context) -> PulsingRingView { PulsingRingView() }

    func updateNSView(_ view: PulsingRingView, context: Context) {
        view.update(color: color, opacity: opacity, lineWidth: lineWidth, period: period)
    }
}

final class PulsingRingView: NSView {
    private let ring = CAShapeLayer()
    private var color: Color?
    private var opacity: CGFloat = 1
    private var period: Double = 0
    private static let key = "ripple"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.actions = noImplicitAnimations
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: Color, opacity: CGFloat, lineWidth: CGFloat, period: Double) {
        ring.lineWidth = lineWidth
        if color != self.color || opacity != self.opacity {
            self.color = color
            self.opacity = opacity
            ring.strokeColor = resolvedColor(color, opacity: opacity, for: self)
        }
        if period != self.period {
            self.period = period
            startAnimation()
        }
    }

    override func layout() {
        super.layout()
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let color { ring.strokeColor = resolvedColor(color, opacity: opacity, for: self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, ring.animation(forKey: Self.key) == nil { startAnimation() }
    }

    private func startAnimation() {
        ring.removeAnimation(forKey: Self.key)
        guard period > 0 else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        grow.duration = period
        fade.duration = period
        let ripple = CAAnimationGroup()
        ripple.animations = [grow, fade]
        ripple.duration = period
        keyedToClock(ripple)
        ring.add(ripple, forKey: Self.key)
    }
}
