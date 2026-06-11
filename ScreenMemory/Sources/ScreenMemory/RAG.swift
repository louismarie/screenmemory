import Foundation
import FoundationModels
import NaturalLanguage

/// Constrained-decoding answer: the 3B on-device model can only fill this schema,
/// which turns it from a paraphrasing chatbot into a grounded extractor (TN3193 pattern).
@Generable
struct GroundedAnswer {
    @Guide(description: "Réponse concise et factuelle, basée UNIQUEMENT sur les extraits fournis. Vide si introuvable.")
    var answer: String
    @Guide(description: "Numéros (1-based) des extraits réellement utilisés pour répondre")
    var sources: [Int]
    @Guide(description: "true si la réponse ne figure pas dans les extraits")
    var notFound: Bool
}

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

    struct Answer {
        let text: String
        let sources: [Int]      // 1-based indices into the context hits
        let notFound: Bool
    }

    static func answerGrounded(question: String, context: [Hit]) async -> Answer {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return Answer(text: fallback(question: question, context: context, model: model),
                          sources: Array(1...max(1, context.count)), notFound: false)
        }

        // The on-device model has a small context window (~4k tokens) — cap snippets.
        let perSnippet = max(300, 3600 / max(1, context.count))
        let ctxText = context.enumerated().map { i, h in
            let meta = [h.app, h.title].filter { !$0.isEmpty }.joined(separator: " — ")
            return "[\(i + 1)] (\(stamp(h.ts))\(meta.isEmpty ? "" : " · " + meta)) \(String(h.text.prefix(perSnippet)))"
        }.joined(separator: "\n\n")

        let session = LanguageModelSession(instructions: """
            Tu réponds à des questions sur ce que l'utilisateur a vu sur son écran, \
            en utilisant UNIQUEMENT les extraits numérotés fournis (texte OCR brut, \
            avec horodatage et application source). Si la réponse n'est pas dans les \
            extraits, mets notFound=true et laisse answer vide. Ne complète jamais \
            avec des connaissances extérieures. \(languageDirective(for: question))
            """)
        let prompt = "Extraits:\n\(ctxText)\n\nQuestion: \(question)"
        do {
            let r = try await session.respond(to: prompt, generating: GroundedAnswer.self)
            let g = r.content
            let valid = g.sources.filter { $0 >= 1 && $0 <= context.count }
            return Answer(text: g.answer, sources: valid, notFound: g.notFound)
        } catch {
            return Answer(text: "Generation error: \(error.localizedDescription)\n\n" +
                          fallback(question: question, context: context, model: model),
                          sources: [], notFound: false)
        }
    }

    /// Legacy plain-text entry point (CLI `query`).
    static func answer(question: String, context: [Hit]) async -> String {
        let a = await answerGrounded(question: question, context: context)
        if a.notFound { return "Je n'ai pas vu ça à l'écran (rien dans les extraits récupérés)." }
        let cites = a.sources.isEmpty ? "" : "  " + a.sources.map { "[\($0)]" }.joined()
        return a.text + cites
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

    static func stamp(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
