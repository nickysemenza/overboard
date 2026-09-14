import CoreGraphics
import Foundation
#if canImport(FoundationModels)
    import FoundationModels

    /// macOS 27's vision-capable on-device model can label a clipboard image
    /// straight from its pixels, instead of relying entirely on OCR text.
    @available(macOS 27, *)
    public extension ClipEnricher {
        /// Labels an image clip from its pixels, with any OCR text passed
        /// along as a hint. `recognizedText` may be nil (textless images are
        /// still worth an on-device title) or long (trimmed to fit).
        static func enrich(image data: Data, recognizedText: String?) async throws -> Enrichment {
            let instructions = """
            You label clipboard images. Generate a short descriptive title \
            (2-5 words), pick the single best category, and write a one-sentence \
            summary of the image's content.
            """
            let session = LanguageModelSession(instructions: instructions)
            let model = SystemLanguageModel.default
            let cgImage = try Self.downsampled(data)
            let hint = try await Self.boundedHint(recognizedText, instructions: instructions, model: model)

            let prompt = Prompt {
                "Label this clipboard image:"
                if let hint {
                    "Text visible in the image:\n\(hint)"
                }
                Attachment(cgImage)
            }
            let response = try await session.respond(to: prompt, generating: GeneratedLabel.self)
            let label = response.content
            return Enrichment(
                title: label.title.trimmingCharacters(in: .whitespacesAndNewlines),
                category: String(describing: label.category),
                summary: label.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        /// Downsamples image bytes for the model, bounding image tokens the
        /// same way `ImageTextRecognizer` bounds OCR input.
        private static func downsampled(_ data: Data) throws -> CGImage {
            guard let image = ImageDownsampler.downsampledImage(from: data, maxPixel: 1024) else {
                throw Failure.undecodableImage
            }
            return image
        }

        /// Trims the OCR hint to fit the context window alongside
        /// `instructions`, the `GeneratedLabel` output schema, and headroom
        /// for the image's own (otherwise uncounted) tokens. Nil in, nil out.
        private static func boundedHint(
            _ text: String?,
            instructions: String,
            model: SystemLanguageModel
        ) async throws -> String? {
            guard let text, !text.isEmpty else { return nil }
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let schemaTokens = try await model.tokenCount(for: GeneratedLabel.generationSchema)
            let budget = model.contextSize - instructionTokens - schemaTokens - 1536
            let trimmed = try await TokenBudget.fit(text, budget: budget) { try await model.tokenCount(for: $0) }
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Thrown when `data` can't be decoded into an image ImageIO
        /// recognizes.
        enum Failure: Error {
            case undecodableImage
        }
    }
#endif
