// OpenFoodJournal — Scan → Assistant shared-element transition
// AGPL-3.0 License
//
// A scan photo "lifts" off the review screen, survives the scan sheet's
// dismissal and the tab switch, then arcs into the real attachment tile in the
// Assistant composer and lands with a macro-tinted ring. The layer lives in its
// own pass-through UIWindow above the app, because a SwiftUI overlay would sit
// underneath the sheet that is animating away.
//
// Visual state is never the source of truth: the attachments are already in
// the composer before the flight starts, so a cancelled, timed-out, or
// reduced-motion transition only skips decoration — it cannot lose a photo.

import SwiftUI
import UIKit
import QuartzCore
import Observation

// MARK: - Geometry plan

enum AssistantTransitionAnchorKey: Hashable {
    case scanSource
    case composerAttachment(UUID)
}

/// Pure geometry for one flight. Kept free of UIKit state so the fallback
/// rules (reduce motion, missing or degenerate frames, off-screen targets)
/// are unit-testable.
struct AssistantAttachmentFlightPlan: Equatable {
    enum Style: Equatable {
        /// Animate the layered snapshot from source to target.
        case flight
        /// Skip the flight; the real tile simply appears.
        case crossfade
    }

    let style: Style
    let source: CGRect
    let target: CGRect
    /// Quadratic Bézier control point. The path bows sideways off the
    /// straight line so the photo reads as being tossed into the composer
    /// tray rather than sliding.
    let arcControlPoint: CGPoint
    let duration: TimeInterval

    static let crossfadeOnly = AssistantAttachmentFlightPlan(
        style: .crossfade, source: .zero, target: .zero, arcControlPoint: .zero, duration: 0
    )

    static func make(
        source: CGRect?,
        target: CGRect?,
        container: CGRect,
        reduceMotion: Bool
    ) -> AssistantAttachmentFlightPlan {
        guard !reduceMotion,
              let source, let target,
              isUsable(source), isUsable(target), isUsable(container),
              container.intersects(source), container.intersects(target)
        else { return .crossfadeOnly }

        let start = CGPoint(x: source.midX, y: source.midY)
        let end = CGPoint(x: target.midX, y: target.midY)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 1 else {
            return AssistantAttachmentFlightPlan(
                style: .flight, source: source, target: target,
                arcControlPoint: start, duration: minimumDuration
            )
        }

        let bow = min(maximumBow, distance * bowRatio)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Unit perpendicular; pick whichever side keeps the apex further from
        // the container's edges so the arc never leaves the screen.
        let perpendicular = CGPoint(x: -dy / distance, y: dx / distance)
        let candidateA = CGPoint(x: mid.x + perpendicular.x * bow, y: mid.y + perpendicular.y * bow)
        let candidateB = CGPoint(x: mid.x - perpendicular.x * bow, y: mid.y - perpendicular.y * bow)
        let control = edgeClearance(candidateA, in: container) >= edgeClearance(candidateB, in: container)
            ? candidateA : candidateB

        let progress = min(1, distance / 700)
        let duration = minimumDuration + (maximumDuration - minimumDuration) * progress
        return AssistantAttachmentFlightPlan(
            style: .flight,
            source: source,
            target: target,
            arcControlPoint: clamp(control, to: container.insetBy(dx: 8, dy: 8)),
            duration: duration
        )
    }

    static let minimumDuration: TimeInterval = 0.46
    static let maximumDuration: TimeInterval = 0.64
    static let maximumBow: CGFloat = 110
    static let bowRatio: CGFloat = 0.2

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 4 && rect.height >= 4
    }

    /// Two consecutive reads within tolerance mean layout (tab switch,
    /// composer expansion, keyboard) has settled and the target is real.
    static func isStable(_ previous: CGRect?, _ current: CGRect?, tolerance: CGFloat = 0.5) -> Bool {
        guard let previous, let current, isUsable(previous), isUsable(current) else { return false }
        return abs(previous.minX - current.minX) <= tolerance
            && abs(previous.minY - current.minY) <= tolerance
            && abs(previous.width - current.width) <= tolerance
            && abs(previous.height - current.height) <= tolerance
    }

    private static func edgeClearance(_ point: CGPoint, in rect: CGRect) -> CGFloat {
        min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
}

// MARK: - Coordinator

/// Owns one in-flight shared-element transition at a time.
///
/// Lifecycle: `stage` (scan screen, before its sheet dismisses) → `land`
/// (composer, after attachments are already staged) → flight → reveal. Any
/// step may fall back to `.idle` without affecting the attachments.
@MainActor
@Observable
final class AssistantAttachmentTransitionCoordinator {
    enum Phase: Equatable {
        case idle
        case staged(handoffID: UUID)
        case landing(handoffID: UUID)
        case flying(handoffID: UUID)

        var handoffID: UUID? {
            switch self {
            case .idle: nil
            case .staged(let id), .landing(let id), .flying(let id): id
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// The composer tile hidden while the layered snapshot is in the air, so
    /// the user sees one photo, not two.
    private(set) var concealedAttachmentID: UUID?

    /// Upper bound between staging and the composer accepting the handoff.
    static let stagingTimeout: Duration = .seconds(2.5)
    /// Upper bound for the composer target to report a settled frame.
    static let landingTimeout: Duration = .milliseconds(1400)

    @ObservationIgnored var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    @ObservationIgnored private var anchors: [AssistantTransitionAnchorKey: WeakAnchor] = [:]
    @ObservationIgnored private var overlay: AssistantTransitionOverlay?
    @ObservationIgnored private var stagingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var landingTask: Task<Void, Never>?

    private struct WeakAnchor {
        weak var view: UIView?
    }

    // MARK: Anchors

    func register(_ view: UIView, for key: AssistantTransitionAnchorKey) {
        anchors[key] = WeakAnchor(view: view)
    }

    func unregister(_ view: UIView, for key: AssistantTransitionAnchorKey) {
        // A recycled tile may already have re-registered a new view.
        guard anchors[key]?.view === view || anchors[key]?.view == nil else { return }
        anchors[key] = nil
    }

    // MARK: Lifecycle

    /// Freezes the scan photo in a layer above the app at its exact on-screen
    /// frame. Call before dismissing the scan sheet. With Reduce Motion, no
    /// source anchor, or no snapshot this records the handoff without any
    /// overlay so `land` simply reveals the tile.
    func stage(handoffID: UUID, snapshot: UIImage?, cornerRadius: CGFloat) {
        finish()
        phase = .staged(handoffID: handoffID)

        stagingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stagingTimeout)
            guard !Task.isCancelled else { return }
            self?.abandon(handoffID)
        }

        guard !reduceMotion(),
              let snapshot,
              let view = anchors[.scanSource]?.view,
              let window = view.window,
              let scene = window.windowScene
        else { return }

        let overlay = AssistantTransitionOverlay(scene: scene)
        let frame = overlay.convert(view.convert(view.bounds, to: window), from: window)
        guard AssistantAttachmentFlightPlan.isUsable(frame) else {
            overlay.tearDown()
            return
        }
        overlay.present(snapshot: snapshot, frame: frame, cornerRadius: cornerRadius)
        overlay.lift()
        self.overlay = overlay
    }

    /// Called by the composer once the handoff's attachments are staged.
    /// Conceals the target tile and flies to it once its frame settles.
    func land(handoffID: UUID, on attachmentID: UUID?) {
        guard phase == .staged(handoffID: handoffID) else { return }
        stagingTimeoutTask?.cancel()
        guard let attachmentID, overlay != nil else {
            finish()
            return
        }
        concealedAttachmentID = attachmentID
        phase = .landing(handoffID: handoffID)
        landingTask = Task { [weak self] in
            await self?.awaitSettledTarget(handoffID: handoffID, attachmentID: attachmentID)
        }
    }

    /// Tab change, backgrounding, or a new handoff: drop the decoration and
    /// show the real tile immediately.
    func cancel() {
        guard phase != .idle else { return }
        finish()
    }

    // MARK: Internals

    private func awaitSettledTarget(handoffID: UUID, attachmentID: UUID) async {
        let deadline = ContinuousClock.now.advanced(by: Self.landingTimeout)
        var previous: CGRect?
        var stableReads = 0
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, phase == .landing(handoffID: handoffID) else { return }
            let current = overlayFrame(for: .composerAttachment(attachmentID))
            stableReads = AssistantAttachmentFlightPlan.isStable(previous, current) ? stableReads + 1 : 0
            previous = current
            if stableReads >= 2, let current {
                fly(to: current, handoffID: handoffID)
                return
            }
        }
        abandon(handoffID)
    }

    private func fly(to target: CGRect, handoffID: UUID) {
        guard let overlay else {
            finish()
            return
        }
        let plan = AssistantAttachmentFlightPlan.make(
            source: overlay.snapshotFrame,
            target: target,
            container: overlay.bounds,
            reduceMotion: reduceMotion()
        )
        guard plan.style == .flight else {
            finish()
            return
        }
        phase = .flying(handoffID: handoffID)
        overlay.fly(plan, targetCornerRadius: AssistantComposerAttachmentMetrics.cornerRadius) { [weak self] in
            guard let self, self.phase == .flying(handoffID: handoffID) else { return }
            // Reveal the real tile underneath the layer before the layer
            // fades, so there is never a frame without the photo.
            self.concealedAttachmentID = nil
            self.phase = .idle
            self.overlay = nil
            overlay.land()
        }
    }

    private func abandon(_ handoffID: UUID) {
        guard phase.handoffID == handoffID else { return }
        finish()
    }

    private func finish() {
        stagingTimeoutTask?.cancel()
        stagingTimeoutTask = nil
        landingTask?.cancel()
        landingTask = nil
        concealedAttachmentID = nil
        phase = .idle
        overlay?.fadeOut()
        overlay = nil
    }

    private func overlayFrame(for key: AssistantTransitionAnchorKey) -> CGRect? {
        guard let overlay,
              let view = anchors[key]?.view,
              let window = view.window,
              !view.isHidden
        else { return nil }
        return overlay.convert(view.convert(view.bounds, to: window), from: window)
    }
}

// MARK: - Overlay window

/// Never participates in hit testing, so the app stays fully interactive
/// while a photo is in flight.
private final class AssistantTransitionPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Core Animation layers for one flight, hosted in a transient window.
@MainActor
private final class AssistantTransitionOverlay {
    private let window: AssistantTransitionPassthroughWindow
    /// Carries the shadow; the image child clips to rounded corners.
    private let carrier = CALayer()
    private let imageLayer = CALayer()

    init(scene: UIWindowScene) {
        window = AssistantTransitionPassthroughWindow(windowScene: scene)
        // Above sheets in the app window, below system alerts.
        window.windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue + 10)
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.isHidden = false
    }

    var bounds: CGRect { window.bounds }
    var snapshotFrame: CGRect { carrier.frame }

    func convert(_ rect: CGRect, from other: UIWindow) -> CGRect {
        window.convert(rect, from: other)
    }

    func present(snapshot: UIImage, frame: CGRect, cornerRadius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        carrier.frame = frame
        carrier.shadowColor = UIColor.black.cgColor
        carrier.shadowOpacity = 0
        carrier.shadowRadius = 18
        carrier.shadowOffset = CGSize(width: 0, height: 10)

        imageLayer.frame = carrier.bounds
        imageLayer.contents = snapshot.cgImage
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.cornerRadius = cornerRadius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true

        carrier.addSublayer(imageLayer)
        window.layer.addSublayer(carrier)
        CATransaction.commit()
    }

    /// Brief "picked up" feedback while the sheet slides away underneath.
    func lift() {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.94
        scale.damping = 18
        scale.stiffness = 260
        scale.duration = scale.settlingDuration
        carrier.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        carrier.add(scale, forKey: "lift.scale")

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = 0.28
        shadow.duration = 0.2
        carrier.shadowOpacity = 0.28
        carrier.add(shadow, forKey: "lift.shadow")
    }

    func fly(
        _ plan: AssistantAttachmentFlightPlan,
        targetCornerRadius: CGFloat,
        completion: @escaping @MainActor () -> Void
    ) {
        let startPosition = carrier.presentation()?.position ?? carrier.position
        let startBounds = carrier.bounds
        let endPosition = CGPoint(x: plan.target.midX, y: plan.target.midY)
        let endBounds = CGRect(origin: .zero, size: plan.target.size)

        let path = UIBezierPath()
        path.move(to: startPosition)
        path.addQuadCurve(to: endPosition, controlPoint: plan.arcControlPoint)

        CATransaction.begin()
        CATransaction.setAnimationDuration(plan.duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.86, 0.26, 1))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion() }
        }

        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path.cgPath
        position.calculationMode = .paced
        carrier.position = endPosition
        carrier.add(position, forKey: "fly.position")

        let carrierBounds = CABasicAnimation(keyPath: "bounds")
        carrierBounds.fromValue = NSValue(cgRect: startBounds)
        carrierBounds.toValue = NSValue(cgRect: endBounds)
        carrier.bounds = endBounds
        carrier.add(carrierBounds, forKey: "fly.bounds")

        // A small tilt-and-recover gives the toss its OFJ character without
        // borrowing any platform transition.
        let tilt = CAKeyframeAnimation(keyPath: "transform")
        tilt.values = [
            CATransform3DMakeScale(0.94, 0.94, 1),
            CATransform3DRotate(CATransform3DMakeScale(0.9, 0.9, 1), -0.07, 0, 0, 1),
            CATransform3DRotate(CATransform3DIdentity, 0.015, 0, 0, 1),
            CATransform3DIdentity,
        ].map { NSValue(caTransform3D: $0) }
        tilt.keyTimes = [0, 0.35, 0.8, 1]
        carrier.transform = CATransform3DIdentity
        carrier.add(tilt, forKey: "fly.tilt")

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = carrier.shadowOpacity
        shadow.toValue = 0.08
        carrier.shadowOpacity = 0.08
        carrier.add(shadow, forKey: "fly.shadow")

        let imageBounds = CABasicAnimation(keyPath: "bounds")
        imageBounds.fromValue = NSValue(cgRect: startBounds)
        imageBounds.toValue = NSValue(cgRect: endBounds)
        let imagePosition = CABasicAnimation(keyPath: "position")
        imagePosition.fromValue = NSValue(cgPoint: CGPoint(x: startBounds.midX, y: startBounds.midY))
        imagePosition.toValue = NSValue(cgPoint: CGPoint(x: endBounds.midX, y: endBounds.midY))
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = imageLayer.cornerRadius
        radius.toValue = targetCornerRadius
        imageLayer.bounds = endBounds
        imageLayer.position = CGPoint(x: endBounds.midX, y: endBounds.midY)
        imageLayer.cornerRadius = targetCornerRadius
        imageLayer.add(imageBounds, forKey: "fly.imageBounds")
        imageLayer.add(imagePosition, forKey: "fly.imagePosition")
        imageLayer.add(radius, forKey: "fly.radius")

        CATransaction.commit()
    }

    /// Landing: a ring in the Journal macro palette ripples out from the tile
    /// while the layered copy dissolves into the real attachment.
    func land() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)

        let frame = carrier.frame
        let ringRect = frame.insetBy(dx: -5, dy: -5)
        let ring = CAGradientLayer()
        ring.type = .conic
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ring.colors = [
            UIColor(OFJColor.journalProtein),
            UIColor(OFJColor.journalCarbohydrates),
            UIColor(OFJColor.journalFat),
            UIColor(OFJColor.journalProtein),
        ].map(\.cgColor)
        ring.frame = ringRect

        let mask = CAShapeLayer()
        mask.frame = ring.bounds
        mask.path = UIBezierPath(
            roundedRect: ring.bounds.insetBy(dx: 1.5, dy: 1.5),
            cornerRadius: AssistantComposerAttachmentMetrics.cornerRadius + 5
        ).cgPath
        mask.fillColor = UIColor.clear.cgColor
        mask.strokeColor = UIColor.black.cgColor
        mask.lineWidth = 3
        ring.mask = mask
        window.layer.addSublayer(ring)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated { tearDown() }
        }

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.92
        grow.toValue = 1.22
        grow.duration = 0.42
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        fade.duration = 0.42
        ring.opacity = 0
        ring.transform = CATransform3DMakeScale(1.22, 1.22, 1)
        ring.add(grow, forKey: "land.grow")
        ring.add(fade, forKey: "land.fade")

        let dissolve = CABasicAnimation(keyPath: "opacity")
        dissolve.fromValue = 1
        dissolve.toValue = 0
        dissolve.duration = 0.16
        carrier.opacity = 0
        carrier.add(dissolve, forKey: "land.dissolve")

        CATransaction.commit()
    }

    func fadeOut() {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated { tearDown() }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = carrier.presentation()?.opacity ?? carrier.opacity
        fade.toValue = 0
        fade.duration = 0.18
        carrier.opacity = 0
        carrier.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    func tearDown() {
        window.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        window.isHidden = true
    }
}

// MARK: - Anchor

/// Invisible UIKit probe placed behind a SwiftUI view so the coordinator can
/// read its true on-screen frame (including sheet and tab container
/// transforms) on demand, rather than trusting a cached SwiftUI value.
struct AssistantTransitionAnchor: UIViewRepresentable {
    let key: AssistantTransitionAnchorKey
    let coordinator: AssistantAttachmentTransitionCoordinator

    func makeUIView(context: Context) -> AssistantTransitionAnchorView {
        let view = AssistantTransitionAnchorView()
        view.configure(key: key, coordinator: coordinator)
        return view
    }

    func updateUIView(_ uiView: AssistantTransitionAnchorView, context: Context) {
        uiView.configure(key: key, coordinator: coordinator)
    }
}

final class AssistantTransitionAnchorView: UIView {
    private var key: AssistantTransitionAnchorKey?
    private weak var coordinator: AssistantAttachmentTransitionCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(key: AssistantTransitionAnchorKey, coordinator: AssistantAttachmentTransitionCoordinator) {
        if self.key != key || self.coordinator !== coordinator, let oldKey = self.key {
            self.coordinator?.unregister(self, for: oldKey)
        }
        self.key = key
        self.coordinator = coordinator
        if window != nil {
            coordinator.register(self, for: key)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let key, let coordinator else { return }
        if window != nil {
            coordinator.register(self, for: key)
        } else {
            coordinator.unregister(self, for: key)
        }
    }
}
