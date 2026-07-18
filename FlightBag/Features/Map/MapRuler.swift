import UIKit
import MapKit
import FBModels
import FBFlightPlan

/// Recognizes a two-finger touch-and-hold: both fingers down and roughly
/// still for a beat. Deliberately loses to pinch/rotate — if the fingers
/// move before the hold interval elapses, this fails and the map zooms as
/// usual. Once begun it tracks both touches until either lifts.
final class TwoFingerHoldGestureRecognizer: UIGestureRecognizer {
    private let holdInterval: TimeInterval = 0.35
    private let movementSlop: CGFloat = 14
    private var startPoints: [UITouch: CGPoint] = [:]
    /// Touches in the order they landed, so the readout's from→to direction
    /// is stable across updates.
    private var orderedTouches: [UITouch] = []
    private var holdTimer: Timer?

    /// The two touch locations in the recognizer's view, once began/changed.
    var touchPoints: [CGPoint] {
        orderedTouches.prefix(2).map { $0.location(in: view) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            startPoints[touch] = touch.location(in: view)
            orderedTouches.append(touch)
        }
        if startPoints.count > 2 {
            fail()
        } else if startPoints.count == 2, state == .possible {
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginIfStillHeld() }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            // Moving fingers = the user is pinching; get out of the way.
            for touch in touches {
                guard let start = startPoints[touch] else { continue }
                let now = touch.location(in: view)
                if hypot(now.x - start.x, now.y - start.y) > movementSlop {
                    fail()
                    return
                }
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            startPoints.removeValue(forKey: touch)
            orderedTouches.removeAll { $0 == touch }
        }
        if state == .began || state == .changed {
            state = .ended
        } else if startPoints.count < 2 {
            fail()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            startPoints.removeValue(forKey: touch)
            orderedTouches.removeAll { $0 == touch }
        }
        if state == .began || state == .changed {
            state = .cancelled
        } else {
            fail()
        }
    }

    override func reset() {
        super.reset()
        startPoints.removeAll()
        orderedTouches.removeAll()
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func beginIfStillHeld() {
        guard state == .possible, startPoints.count == 2 else { return }
        state = .began
    }

    private func fail() {
        holdTimer?.invalidate()
        holdTimer = nil
        if state == .possible { state = .failed }
    }
}

/// Screen-space ruler drawn over the map: a line between two fingers with a
/// distance/course readout. Not an MKOverlay — it's transient touch UI, and
/// a passthrough view never blocks map interaction.
final class RulerHUDView: UIView {
    private let lineLayer = CAShapeLayer()
    private let endpointLayer = CAShapeLayer()
    private let label = UILabel()
    private let labelBackground = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true

        lineLayer.strokeColor = UIColor.systemCyan.cgColor
        lineLayer.lineWidth = 3
        lineLayer.lineCap = .round
        lineLayer.lineDashPattern = [8, 6]
        lineLayer.fillColor = nil
        layer.addSublayer(lineLayer)

        endpointLayer.fillColor = UIColor.systemCyan.cgColor
        layer.addSublayer(endpointLayer)

        labelBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        labelBackground.layer.cornerRadius = 8
        labelBackground.layer.borderWidth = 1
        labelBackground.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.5).cgColor
        addSubview(labelBackground)

        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(from a: CGPoint, to b: CGPoint, on map: MKMapView) {
        isHidden = false
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        lineLayer.path = path.cgPath

        let dots = UIBezierPath()
        for point in [a, b] {
            dots.append(UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)))
        }
        endpointLayer.path = dots.cgPath

        let coordA = map.convert(a, toCoordinateFrom: self)
        let coordB = map.convert(b, toCoordinateFrom: self)
        let from = Coordinate(latitude: coordA.latitude, longitude: coordA.longitude)
        let to = Coordinate(latitude: coordB.latitude, longitude: coordB.longitude)
        let distance = NavMath.distanceNM(from: from, to: to)
        let course = NavMath.initialBearing(from: from, to: to)
        label.text = String(format: "%.1f NM   %03.0f°T", distance, course)
        label.sizeToFit()

        // Readout above the line's midpoint, nudged inside the view.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = CGSize(width: label.frame.width + 20, height: label.frame.height + 10)
        var origin = CGPoint(x: mid.x - size.width / 2, y: mid.y - size.height - 24)
        origin.x = max(8, min(bounds.width - size.width - 8, origin.x))
        origin.y = max(8, origin.y)
        labelBackground.frame = CGRect(origin: origin, size: size)
        label.center = CGPoint(x: labelBackground.frame.midX, y: labelBackground.frame.midY)
    }

    func hide() {
        isHidden = true
        lineLayer.path = nil
        endpointLayer.path = nil
    }
}
