import AVFoundation
import SwiftUI
import UIKit

/// Hosts the controller-owned `AVCaptureVideoPreviewLayer`. Tap = focus/expose
/// at point (shows the focus square + EV slider), vertical drag = exposure
/// bias while the indicator is visible, pinch = zoom.
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView(previewLayer: controller.previewLayer)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        context.coordinator.controller = controller
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var controller: CameraController
        weak var host: PreviewHostView?

        private var exposureBias: Float = 0
        private static let biasLimit: Float = 2

        init(controller: CameraController) {
            self.controller = controller
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let host else { return }
            let point = gesture.location(in: host)
            exposureBias = 0
            controller.focus(atLayerPoint: point)
            host.showFocusIndicator(at: point)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let host, host.isFocusIndicatorVisible else { return }
            switch gesture.state {
            case .changed:
                let translation = gesture.translation(in: host)
                gesture.setTranslation(.zero, in: host)
                // Dragging down lowers exposure; ~130pt of travel covers the range.
                exposureBias -= Float(translation.y) / 65 * Self.biasLimit / 2
                exposureBias = max(-Self.biasLimit, min(Self.biasLimit, exposureBias))
                controller.setExposureBias(exposureBias)
                host.setFocusIndicatorBias(CGFloat(exposureBias / Self.biasLimit))
            default:
                break
            }
        }

        // Let the exposure pan begin only on mostly-vertical drags so it never
        // fights the pinch.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let host else { return true }
            guard host.isFocusIndicatorVisible else { return false }
            let velocity = pan.velocity(in: host)
            return abs(velocity.y) > abs(velocity.x)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                controller.pinchZoomBegan()
            case .changed:
                controller.pinchZoomChanged(scale: gesture.scale)
            default:
                break
            }
        }
    }
}

/// Plain UIView that keeps the preview layer sized to its bounds and hosts the
/// focus square + exposure slider indicator.
final class PreviewHostView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var focusIndicator: FocusExposureIndicatorView?
    private var fadeWorkItem: DispatchWorkItem?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    var isFocusIndicatorVisible: Bool {
        focusIndicator != nil
    }

    func showFocusIndicator(at point: CGPoint) {
        focusIndicator?.removeFromSuperview()

        let indicator = FocusExposureIndicatorView()
        // Keep the square plus its side slider on screen; flip the slider to
        // the left edge of the square near the right edge of the view.
        indicator.sliderOnRight = point.x < bounds.width - 90
        indicator.center = CGPoint(
            x: max(60, min(bounds.width - 60, point.x)),
            y: max(80, min(bounds.height - 80, point.y))
        )
        addSubview(indicator)
        focusIndicator = indicator

        indicator.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
        indicator.alpha = 0
        UIView.animate(withDuration: 0.18) {
            indicator.transform = .identity
            indicator.alpha = 1
        }
        scheduleFade()
    }

    func setFocusIndicatorBias(_ normalizedBias: CGFloat) {
        focusIndicator?.setBias(normalizedBias)
        scheduleFade()
    }

    private func scheduleFade() {
        fadeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let indicator = self.focusIndicator else { return }
            UIView.animate(withDuration: 0.4, animations: {
                indicator.alpha = 0
            }, completion: { _ in
                indicator.removeFromSuperview()
                if self.focusIndicator === indicator {
                    self.focusIndicator = nil
                }
            })
        }
        fadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }
}

/// Stock-camera style indicator: yellow focus square with a vertical exposure
/// slider (sun icon on a track) beside it.
final class FocusExposureIndicatorView: UIView {
    private let square = UIView()
    private let track = UIView()
    private let sun = UIImageView(image: UIImage(systemName: "sun.max.fill"))

    private static let squareSize: CGFloat = 80
    private static let trackHeight: CGFloat = 110
    private static let sliderGap: CGFloat = 18

    var sliderOnRight = true {
        didSet { setNeedsLayout() }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.squareSize + Self.sliderGap * 2 + 24, height: Self.trackHeight + 10))
        isUserInteractionEnabled = false

        square.layer.borderColor = UIColor.systemYellow.cgColor
        square.layer.borderWidth = 1.5
        square.layer.cornerRadius = 4
        addSubview(square)

        track.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.6)
        addSubview(track)

        sun.tintColor = .systemYellow
        sun.contentMode = .scaleAspectFit
        addSubview(sun)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let centerY = bounds.midY
        let squareX = sliderOnRight
            ? bounds.midX - (Self.squareSize + Self.sliderGap) / 2
            : bounds.midX + (Self.sliderGap - Self.squareSize) / 2 + Self.sliderGap
        square.frame = CGRect(
            x: squareX - Self.squareSize / 2 + Self.squareSize / 2,
            y: centerY - Self.squareSize / 2,
            width: Self.squareSize,
            height: Self.squareSize
        )
        let trackX = sliderOnRight
            ? square.frame.maxX + Self.sliderGap
            : square.frame.minX - Self.sliderGap
        track.frame = CGRect(x: trackX - 0.75, y: centerY - Self.trackHeight / 2, width: 1.5, height: Self.trackHeight)
        if sun.frame == .zero || sun.frame.size == .zero {
            sun.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        }
        sun.center = CGPoint(x: trackX, y: sunCenterY)
    }

    private var currentBias: CGFloat = 0

    private var sunCenterY: CGFloat {
        bounds.midY - currentBias * (Self.trackHeight / 2 - 14)
    }

    /// `normalizedBias` in -1...1; positive moves the sun up (brighter).
    func setBias(_ normalizedBias: CGFloat) {
        currentBias = max(-1, min(1, normalizedBias))
        sun.center = CGPoint(x: sun.center.x, y: sunCenterY)
    }
}
