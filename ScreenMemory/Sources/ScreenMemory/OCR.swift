import Foundation
import Vision
import CoreImage

/// One recognized text line with its normalized bounding box (Vision coords, origin bottom-left).
struct TextLine {
    let text: String
    let box: CGRect
}

/// On-screen text extraction via the Vision framework (runs on the ANE where possible).
enum OCR {
    /// Recognized lines with bounding boxes — input for layout-aware chunking.
    static func recognizeLines(_ cgImage: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["fr-FR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let obs = request.results else { return [] }
        return obs.compactMap { o in
            guard let top = o.topCandidates(1).first else { return nil }
            return TextLine(text: top.string, box: o.boundingBox)
        }
    }

    /// Recognized text lines joined into a single string ("" if none).
    static func recognize(_ cgImage: CGImage) -> String {
        recognizeLines(cgImage).map(\.text).joined(separator: "\n")
    }

    /// Decode an image file (png/jpg) to a CGImage.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let ci = CIImage(contentsOf: url) else { return nil }
        let ctx = CIContext()
        return ctx.createCGImage(ci, from: ci.extent)
    }
}
