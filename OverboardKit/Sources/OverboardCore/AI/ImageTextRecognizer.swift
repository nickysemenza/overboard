import Foundation
import Vision

/// On-device OCR for copied images, so screenshots become searchable by what
/// they contain. No Apple Intelligence requirement — Vision ships everywhere.
public enum ImageTextRecognizer {
    /// Oversized images are downsampled to this longest-side pixel budget before
    /// OCR. A 4K-ish cap keeps screenshot text legible while stopping a giant
    /// paste (a Retina full-screen grab, a scanned page) from ballooning the
    /// Vision pass in time and memory.
    static let maxOCRPixel = 4096

    /// Returns recognized text lines joined by newlines, or nil if the image
    /// contains no legible text. Runs on the Swift-native Vision API, which is
    /// non-blocking-friendly — call from a background task.
    public static func recognizeText(in imageData: Data) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // Cap input size so a huge image doesn't make OCR the slow part of the
        // enrich task. Falls back to the raw data if downsampling can't decode it.
        let observations: [RecognizedTextObservation]
        do {
            if let downsampled = ImageDownsampler.downsampledImage(from: imageData, maxPixel: Self.maxOCRPixel) {
                observations = try await request.perform(on: downsampled)
            } else {
                observations = try await request.perform(on: imageData)
            }
        } catch {
            return nil
        }

        let lines = observations.compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence > 0.4
            else { return nil }
            return candidate.string
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
