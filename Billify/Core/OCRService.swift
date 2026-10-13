//
//  OCRService.swift
//  Billify
//
//  Reads the text out of a photographed invoice (spec §29 Method 1) using
//  Apple's on-device Vision framework — no network, no extra dependency.
//  The recognized text is handed back as plain text so it can be routed
//  through exactly the same BulkTextExtractor pipeline as a pasted sentence.
//
//  Uncertainty handling (spec §33): a photographed document is rarely
//  perfect, so lines Vision is unsure about are surfaced instead of being
//  silently trusted. Lines it can barely read at all are dropped entirely —
//  they are usually blur/noise and would only pollute the field extractor.
//

import Foundation
import UIKit
import Vision

struct OCRResult: Sendable {
    /// Recognized lines in reading order (top → bottom), joined with newlines.
    var text: String
    /// Lines Vision read with middling confidence — probably right, but worth
    /// a human double-check (spec §33).
    var lowConfidenceLines: [String]
}

enum OCRService {

    // MARK: - Entry point

    /// Recognizes the text in a JPEG/PNG/HEIC image payload.
    ///
    /// Runs off the main actor (the caller is MainActor by default in this
    /// app), so the synchronous Vision pass never blocks the chat UI.
    nonisolated static func recognizeText(in imageData: Data) async -> OCRResult {
        guard let image = UIImage(data: imageData) else {
            return OCRResult(text: "", lowConfidenceLines: [])
        }
        guard let cgImage = ocrReadyCGImage(from: image) else {
            return OCRResult(text: "", lowConfidenceLines: [])
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return OCRResult(text: "", lowConfidenceLines: [])
        }
        guard let observations = request.results else {
            return OCRResult(text: "", lowConfidenceLines: [])
        }

        // Reading order: Vision returns observations in arbitrary order, so
        // sort top → bottom (Vision's origin is bottom-left), then left → right
        // within the same line band. Lines at or below the garbage threshold
        // are dropped outright — usually blur/noise, and they would only
        // pollute the field extractor.
        let garbageConfidence: Float = 0.2
        let recognized = observations
            .filter { $0.confidence > garbageConfidence }
            .sorted { a, b in
                let rowDelta = a.boundingBox.midY - b.boundingBox.midY
                if abs(rowDelta) > 0.02 { return rowDelta > 0 }
                return a.boundingBox.minX < b.boundingBox.minX
            }

        // Lines below this confidence are kept but flagged for the user to check.
        let flagConfidence: Float = 0.45
        var lines: [String] = []
        var flagged: [String] = []
        for observation in recognized {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if observation.confidence < flagConfidence, !text.isEmpty {
                flagged.append(text)
            }
            lines.append(text)
        }

        return OCRResult(text: lines.joined(separator: "\n"), lowConfidenceLines: flagged)
    }

    // MARK: - Image preparation

    /// Applies the image's EXIF orientation flag (camera shots are rarely
    /// stored "up") and scales the largest edge down to the OCR budget, so
    /// Vision receives clean, upright, reasonably sized pixels.
    private static func ocrReadyCGImage(from image: UIImage) -> CGImage? {
        let rawWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let rawHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let isSideways = image.imageOrientation == .left
            || image.imageOrientation == .right
            || image.imageOrientation == .leftMirrored
            || image.imageOrientation == .rightMirrored
        // The oriented image's dimensions (UIKit's `size` already swaps these
        // for 90° rotations).
        let orientedWidth = isSideways ? rawHeight : rawWidth
        let orientedHeight = isSideways ? rawWidth : rawHeight

        let maxPixelDimension: CGFloat = 2200
        let longest = CGFloat(max(orientedWidth, orientedHeight))
        guard longest > 0 else { return image.cgImage }
        let scale = min(1, maxPixelDimension / longest)
        let targetWidth = max(1, Int(CGFloat(orientedWidth) * scale))
        let targetHeight = max(1, Int(CGFloat(orientedHeight) * scale))

        // Work in pixels (format scale 1) so the target size above is exact.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        // Drawing the UIImage (not its raw CGImage) lets UIKit apply the
        // orientation flag while filling the target rect.
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetWidth, height: targetHeight),
            format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }.cgImage
    }
}
