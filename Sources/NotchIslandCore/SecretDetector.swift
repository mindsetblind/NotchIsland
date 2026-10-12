import Foundation

/// Heuristic check for text that is probably a password, token or key, so clipboard history can
/// skip it by default. It catches common formats only — it can't recognise every secret, and the
/// app says so in Settings. Things marked as concealed by password managers
/// (`org.nspasteboard.ConcealedType`) are skipped separately, before this runs.
public enum SecretDetector {
    public enum Reason: String, Sendable {
        case privateKey, knownTokenFormat, jwt, credentialAssignment, connectionStringPassword, highEntropy
    }

    /// Returns why `text` looks secret, or nil.
    public static func reason(_ text: String) -> Reason? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY") { return .privateKey }
        if matches(t, tokenPatterns) { return .knownTokenFormat }
        if matches(t, [#"^eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#]) { return .jwt }
        // "password=…", "api_key: …", "export SECRET_TOKEN=…" — short snippets only (a whole config
        // file that mentions a password field is a document, not a credential).
        if t.count < 400, matches(t, [#"(?i)\b(pass(word|wd)?|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|token|private[_-]?key)\b\s*[:=]\s*["']?[^\s"']{6,}"#]) {
            return .credentialAssignment
        }
        if matches(t, [#"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]{3,}@"#]) { return .connectionStringPassword }
        if looksRandom(t) { return .highEntropy }
        return nil
    }

    public static func isLikelySecret(_ text: String) -> Bool { reason(text) != nil }

    // Prefixes documented by the issuers (GitHub, Slack, Stripe, OpenAI/Anthropic, AWS, Google, npm…).
    private static let tokenPatterns = [
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
        #"\bglpat-[A-Za-z0-9_-]{20,}\b"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#,
        #"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}\b"#,
        #"\bsk-(ant-|proj-)?[A-Za-z0-9_-]{20,}\b"#,
        #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#,
        #"\bhf_[A-Za-z0-9]{30,}\b"#,
    ]

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// A single "word" of 16–128 characters mixing letters, digits (and often symbols) with no
    /// recognisable structure: typical of generated passwords and API keys.
    static func looksRandom(_ t: String) -> Bool {
        guard (16...128).contains(t.count), !t.contains(where: \.isWhitespace) else { return false }
        // Links, paths, e-mail addresses, UUIDs and hex hashes are common and harmless to keep.
        if t.contains("://") || t.hasPrefix("/") || t.hasPrefix("~/") || t.contains("@") && t.contains(".") { return false }
        if t.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^[\w.-]+\.(swift|txt|md|json|png|jpe?g|pdf|zip|html?|js|ts|py)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }

        let lower = t.contains(where: \.isLowercase)
        let upper = t.contains(where: \.isUppercase)
        let digit = t.contains(where: \.isNumber)
        let symbol = t.contains { !$0.isLetter && !$0.isNumber }
        let classes = [lower, upper, digit, symbol].filter { $0 }.count
        guard classes >= 3, digit else { return false }
        // camelCase identifiers and snake_case names have long runs of letters; random strings don't.
        return entropyPerChar(t) >= 3.5 && longestLetterRun(t) < 9
    }

    static func entropyPerChar(_ t: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in t { counts[c, default: 0] += 1 }
        let n = Double(t.count)
        return counts.values.reduce(0) { acc, k in
            let p = Double(k) / n
            return acc - p * log2(p)
        }
    }

    private static func longestLetterRun(_ t: String) -> Int {
        var best = 0, run = 0
        for c in t {
            run = c.isLetter ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }
}
