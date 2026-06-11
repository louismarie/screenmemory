import Foundation
import Vision
import CoreImage

/// On-screen text extraction via the Vision framework (runs on the ANE where possible).
enum OCR {
    /// Recognized text lines joined into a single string ("" if none).
    static func recognize(_ cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        guard let obs = request.results else { return "" }
        let lines = obs.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Decode an image file (png/jpg) to a CGImage.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let ci = CIImage(contentsOf: url) else { return nil }
        let ctx = CIContext()
        return ctx.createCGImage(ci, from: ci.extent)
    }
}
