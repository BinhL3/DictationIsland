import Foundation

/// The user's word list: fixes for things the recognizer keeps mishearing, and names it should
/// know. Written one rule per line in Settings:
///
///     get hub -> GitHub      replaces "get hub" (any case, whole words) with "GitHub"
///     Parakeet               no replacement, just a hint for the Apple engines
///     um ->                  an empty replacement deletes the phrase
///
/// Matching is case-insensitive on whole words, and longer phrases win over shorter ones that
/// overlap them. It runs on the live transcript and the final text, so every engine benefits.
struct Corrections: Equatable {
    struct Rule: Equatable {
        let heard: String
        let written: String
    }

    let rules: [Rule]
    /// Words to pass to Apple Speech as contextual strings: every replacement and bare word.
    let hints: [String]
    private let pattern: NSRegularExpression?
    private let lookup: [String: String]

    init(_ text: String) {
        var rules: [Rule] = []
        var hints: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let arrow = ["->", "→", "=>"].compactMap { line.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            if let arrow {
                let heard = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !heard.isEmpty else { continue }
                rules.append(Rule(heard: heard, written: written))
                if !written.isEmpty { hints.append(written) }
            } else {
                hints.append(line)
            }
        }
        self.rules = rules
        var seen = Set<String>()
        self.hints = hints.filter { seen.insert($0.lowercased()).inserted }

        var lookup: [String: String] = [:]
        for rule in rules where lookup[rule.heard.lowercased()] == nil {
            lookup[rule.heard.lowercased()] = rule.written
        }
        self.lookup = lookup
        // Longest first, so "get hub desktop" beats "get hub" in the alternation.
        let alternatives = lookup.keys.sorted { $0.count > $1.count }.map { phrase in
            // Spaces in a phrase match any run of whitespace.
            phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        pattern = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        )
    }

    static func == (lhs: Corrections, rhs: Corrections) -> Bool { lhs.rules == rhs.rules && lhs.hints == rhs.hints }

    func apply(to text: String) -> String {
        guard let pattern, !text.isEmpty else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        var deleted = false
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let heard = source.substring(with: match.range)
            let key = heard.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            let written = lookup[key] ?? heard
            if written.isEmpty { deleted = true }
            result += written
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        guard deleted else { return result }
        // Tidy what a deletion leaves behind: doubled spaces, a space before punctuation.
        return result
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "^[ ,]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
