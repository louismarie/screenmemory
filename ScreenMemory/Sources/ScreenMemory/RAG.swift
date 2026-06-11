import Foundation
import FoundationModels
import NaturalLanguage

/// Answer generation over retrieved screen memories, using Apple's on-device
/// foundation model via the public FoundationModels SDK (free, offline).
enum RAG {
    /// Quick check of the on-device model state (available / not enabled / downloading).
    static func availabilityDescription() -> String {
        switch SystemLanguageModel.default.availability {
        case .available: return "READY"
        case .unavailable(let reason): return "NOT READY: \(reason)"
        @unknown default: return "NOT READY: unknown"
        }
    }

    static func answer(question: String, context: [Hit]) async -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            // Apple Intelligence not enabled — still show what retrieval found.
            return fallback(question: question, context: context, model: model)
        }

        // The on-device model has a small context window (~4k tokens) and one OCR'd
        // screen can be 3-4k chars — cap each snippet or generation fails outright.
        let perSnippet = max(400, 4800 / max(1, context.count))
        let ctxText = context.enumerated().map { i, h in
            "[\(i + 1)] (\(stamp(h.ts))) \(String(h.text.prefix(perSnippet)))"
        }.joined(separator: "\n\n")

        let session = LanguageModelSession(instructions: """
            You answer questions about what the user saw on their screen, using ONLY \
            the provided context snippets (each captured at a timestamp). If the answer \
            isn't in the context, say so. Be concise and cite snippet numbers like [1]. \
            \(languageDirective(for: question))
            """)
        let prompt = "Context:\n\(ctxText)\n\nQuestion: \(question)"
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            return "Generation error: \(error.localizedDescription)\n\n" +
                   fallback(question: question, context: context, model: model)
        }
    }

    private static func fallback(question: String, context: [Hit], model: SystemLanguageModel) -> String {
        var s = "(Apple Intelligence unavailable: \(model.availability) — showing top matches)\n"
        for (i, h) in context.enumerated() {
            s += "\n[\(i + 1)] score \(String(format: "%.3f", h.score)) @ \(stamp(h.ts))\n\(h.text)\n"
        }
        return s
    }

    /// Detect the question's language and return an explicit, in-language directive —
    /// far more reliable on a small model than a generic "same language" instruction.
    private static func languageDirective(for text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(text)
        switch r.dominantLanguage {
        case .french:  return "Réponds UNIQUEMENT en français."
        case .spanish: return "Responde ÚNICAMENTE en español."
        case .german:  return "Antworte AUSSCHLIESSLICH auf Deutsch."
        case .italian: return "Rispondi SOLO in italiano."
        case .portuguese: return "Responda APENAS em português."
        default:       return "Reply ONLY in English."
        }
    }

    private static func stamp(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
