// OpenFoodJournal — generated food icon subject lifting
// AGPL-3.0 License

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

protocol FoodIconForegroundMasking: Sendable {
    func transparentPNG(
        from imageData: Data,
        maximumPixelDimension: CGFloat
    ) async -> Data?
}

/// Uses Apple's semantic subject-lifting model instead of comparing individual
/// background pixels. This preserves light food edges, dark shadows, highlights,
/// and disconnected details that a white-threshold flood fill cannot understand.
actor VisionFoodIconForegroundMasker: FoodIconForegroundMasking {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func transparentPNG(
        from imageData: Data,
        maximumPixelDimension: CGFloat
    ) async -> Data? {
        guard maximumPixelDimension > 0,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            try handler.perform([request])

            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                return nil
            }

            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            if let coverage = foregroundCoverage(in: maskBuffer),
               !(0.02...0.85).contains(coverage) {
                return nil
            }

            let sourceImage = CIImage(cgImage: cgImage)
            let maskImage = alignedMaskImage(
                from: maskBuffer,
                sourceExtent: sourceImage.extent
            )
            let transparentBackground = CIImage(color: .clear)
                .cropped(to: sourceImage.extent)
            let isolatedFood = sourceImage.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparentBackground,
                    kCIInputMaskImageKey: maskImage,
                ]
            )
            let resized = resizedImage(
                isolatedFood,
                maximumPixelDimension: maximumPixelDimension
            )
            return context.pngRepresentation(
                of: resized,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            #if DEBUG
            print("⚠️ Food icon semantic mask unavailable: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func alignedMaskImage(
        from pixelBuffer: CVPixelBuffer,
        sourceExtent: CGRect
    ) -> CIImage {
        let mask = CIImage(cvPixelBuffer: pixelBuffer)
        guard mask.extent.width > 0,
              mask.extent.height > 0,
              mask.extent.size != sourceExtent.size else {
            return mask
        }

        return mask.transformed(
            by: CGAffineTransform(
                scaleX: sourceExtent.width / mask.extent.width,
                y: sourceExtent.height / mask.extent.height
            )
        )
    }

    private func resizedImage(
        _ image: CIImage,
        maximumPixelDimension: CGFloat
    ) -> CIImage {
        let longestDimension = max(image.extent.width, image.extent.height)
        guard longestDimension > maximumPixelDimension else { return image }

        let scale = maximumPixelDimension / longestDimension
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return scaled.transformed(
            by: CGAffineTransform(
                translationX: -scaled.extent.minX,
                y: -scaled.extent.minY
            )
        )
    }

    /// Rejects masks that are effectively empty or treat nearly the full frame
    /// as foreground. Unknown mask formats skip this quality gate and still use
    /// Vision's result rather than falling back to color-based assumptions.
    private func foregroundCoverage(in pixelBuffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        var foregroundPixelCount = 0

        for y in 0..<height {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in 0..<width where row[x] >= 128 {
                foregroundPixelCount += 1
            }
        }

        return Double(foregroundPixelCount) / Double(max(width * height, 1))
    }
}
