import Foundation
import FoundationModels
import NaturalLanguage

/// Constrained-decoding answer: the 3B on-device model can only fill this schema,
/// which turns it from a paraphrasing chatbot into a grounded extractor (TN3193 pattern).
@Generable
struct GroundedAnswer {
    @Guide(description: "Concise factual answer based ONLY on the provided excerpts. Empty when not found.")
    var answer: String
    @Guide(description: "1-based numbers of the excerpts actually used to answer.")
    var sources: [Int]
    @Guide(description: "true when the answer is not present in the excerpts.")
    var notFound: Bool
}

@Generable
struct EvalQuestion {
    @Guide(description: "Short natural question a user would ask to find this on-screen content. Do not copy the text verbatim.")
    var question: String
}

/// Answer generation over retrieved screen memories, using Apple's on-device
/// foundation model via the public FoundationModels SDK (free, offline).
enum RAG {
    /// Synthetic eval-question generation from a stored chunk (eval harness).
    static func makeQuestion(from text: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions:
            "Generate a test question for a screen-memory search engine. Use the same language as the provided text.")
        let r = try? await session.respond(to: "On-screen text:\n\(String(text.prefix(700)))",
                                           generating: EvalQuestion.self)
        return r?.content.question
    }
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

    static func answerGrounded(question: String, context: [Hit], language: AppLanguage? = nil) async -> Answer {
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
            Answer questions about what the user saw on screen using ONLY the numbered excerpts \
            provided as raw OCR text with timestamps and source application metadata. If the answer \
            is not present in the excerpts, set notFound=true and leave answer empty. Never fill gaps \
            with outside knowledge. \(language?.modelInstruction ?? languageDirective(for: question))
            """)
        let prompt = "Excerpts:\n\(ctxText)\n\nQuestion: \(question)"
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
        if a.notFound { return "I did not see that on screen in the retrieved excerpts." }
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
        case .french:
            return "Reply ONLY in French."
        case .spanish:
            return "Reply ONLY in Spanish."
        case .german:
            return "Reply ONLY in German."
        case .italian:
            return "Reply ONLY in Italian."
        case .portuguese:
            return "Reply ONLY in Portuguese."
        default:
            return "Reply ONLY in English."
        }
    }

    static func stamp(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
