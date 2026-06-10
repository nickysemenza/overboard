import Foundation
import Vision

/// On-device OCR for copied images, so screenshots become searchable by what
/// they contain. No Apple Intelligence requirement — Vision ships everywhere.
public enum ImageTextRecognizer {
    /// Returns recognized text lines joined by newlines, or nil if the image
    /// contains no legible text. Synchronous Vision work — call from a
    /// background task.
    public static func recognizeText(in imageData: Data) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: imageData)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.4
            else { return nil }
            return candidate.string
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
