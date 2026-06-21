import Foundation

/// Privacy gate for the always-on pipeline. Three layers:
///  1. pause flag      — a file the user can drop to stop indexing entirely
///  2. app exclusion   — sensitive apps (password managers, banking) never captured
///  3. secret redaction — secrets scrubbed from OCR text BEFORE it is embedded/stored
///
/// This is the layer that sank Microsoft Recall when it was missing. Defaults are
/// conservative; users extend via ~/.screenmemory.exclude (one bundle id per line).
enum Privacy {
    static let pauseFlag = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.paused")
    static let excludeFile = (NSHomeDirectory() as NSString).appendingPathComponent(".screenmemory.exclude")

    static var isPaused: Bool { FileManager.default.fileExists(atPath: pauseFlag) }

    /// Bundle identifiers never captured (built-in + user additions).
    static func excludedBundleIDs() -> Set<String> {
        var ids: Set<String> = [
            "com.agilebits.onepassword7", "com.1password.1password",
            "com.bitwarden.desktop", "com.apple.keychainaccess",
            "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        ]
        if let txt = try? String(contentsOfFile: excludeFile, encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                let id = line.trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: - Secret redaction

    private struct Pattern { let label: String; let regex: NSRegularExpression }

    private static let patterns: [Pattern] = {
        func rx(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            Pattern(label: "CARD",   regex: rx(#"\b(?:\d[ -]?){13,16}\b"#)),
            Pattern(label: "IBAN",   regex: rx(#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#)),
            Pattern(label: "EMAIL",  regex: rx(#"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"#)),
            Pattern(label: "APIKEY", regex: rx(#"\b(?:sk|pk|ghp|gho|xox[baprs])[-_][A-Za-z0-9-_]{12,}\b"#)),
            Pattern(label: "AWSKEY", regex: rx(#"\bAKIA[0-9A-Z]{16}\b"#)),
            Pattern(label: "GCPKEY", regex: rx(#"\bAIza[0-9A-Za-z_-]{35}\b"#)),
            Pattern(label: "GHPAT",  regex: rx(#"\bgithub_pat_[0-9A-Za-z_]{20,}\b"#)),
            Pattern(label: "PEM",    regex: rx(#"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----"#)),
            Pattern(label: "BEARER", regex: rx(#"\bBearer\s+[A-Za-z0-9._-]{12,}\b"#)),
            Pattern(label: "TOKEN",  regex: rx(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#)), // JWT
            Pattern(label: "SECRET", regex: rx(#"(?:password|passwd|mot de passe|secret|api[_ ]?key|token)\s*[:=]\s*\S+"#)),
        ]
    }()

    /// Returns redacted text. Secrets are replaced by [REDACTED:LABEL].
    static func redact(_ text: String) -> String {
        var out = text
        for p in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = p.regex.stringByReplacingMatches(in: out, range: range,
                                                    withTemplate: "[REDACTED:\(p.label)]")
        }
        return out
    }
}
