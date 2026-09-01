// Macros — Food Journaling App
// AGPL-3.0 License

import SwiftUI
import AVFoundation

// MARK: - CameraPreviewView

/// UIViewRepresentable wrapping an AVCaptureSession live preview.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onVisibleCaptureRectChanged: (CGRect) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.onVisibleCaptureRectChanged = onVisibleCaptureRectChanged
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onVisibleCaptureRectChanged = onVisibleCaptureRectChanged
        uiView.publishVisibleCaptureRect()
    }
}

// MARK: - PreviewUIView

final class PreviewUIView: UIView {
    var onVisibleCaptureRectChanged: ((CGRect) -> Void)?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        publishVisibleCaptureRect()
    }

    /// Converts the aspect-filled viewfinder into normalized camera coordinates.
    /// The photo pipeline snapshots this rectangle when the shutter is pressed so
    /// the reviewed and analyzed image contains exactly what the user framed.
    func publishVisibleCaptureRect() {
        guard bounds.width > 0,
              bounds.height > 0,
              previewLayer.connection != nil
        else { return }

        let rect = previewLayer.metadataOutputRectConverted(
            fromLayerRect: previewLayer.bounds
        )
        onVisibleCaptureRectChanged?(rect)
    }
}

/// A normalized, bounded crop copied from `AVCaptureVideoPreviewLayer`.
///
/// Keeping pixel conversion independent of UIKit and AVFoundation makes the
/// WYSIWYG contract testable without launching camera hardware.
struct CameraPreviewCrop: Equatable, Sendable {
    static let fullFrame = CameraPreviewCrop(
        normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
    )

    let normalizedRect: CGRect

    init(normalizedRect: CGRect) {
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let boundedRect = normalizedRect.standardized.intersection(unitRect)
        if boundedRect.isNull || boundedRect.width <= 0 || boundedRect.height <= 0 {
            self.normalizedRect = unitRect
        } else {
            self.normalizedRect = boundedRect
        }
    }

    func pixelRect(forWidth width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0 else { return nil }

        let pixelBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let minimumX = floor(normalizedRect.minX * CGFloat(width))
        let minimumY = floor(normalizedRect.minY * CGFloat(height))
        let maximumX = ceil(normalizedRect.maxX * CGFloat(width))
        let maximumY = ceil(normalizedRect.maxY * CGFloat(height))
        let pixelRect = CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).intersection(pixelBounds)

        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else {
            return nil
        }
        return pixelRect
    }
}
