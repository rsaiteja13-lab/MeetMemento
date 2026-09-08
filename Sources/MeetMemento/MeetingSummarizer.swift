import Foundation

enum MeetingSummarizer {
    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "been", "before", "being",
        "but", "can", "could", "did", "does", "for", "from", "had", "has", "have", "how", "into",
        "just", "more", "not", "now", "our", "out", "should", "some", "that", "the", "their", "then",
        "there", "these", "they", "this", "those", "through", "very", "was", "were", "what", "when",
        "where", "which", "who", "will", "with", "would", "you", "your"
    ]

    static func summarize(_ transcript: String, maximumPoints: Int = 5) -> String {
        let utterances = transcript
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap(stripTranscriptPrefix)

        let sentences = utterances.flatMap(sentences(in:)).filter { sentence in
            sentence.split(whereSeparator: \Character.isWhitespace).count >= 3
        }
        guard !sentences.isEmpty else { return "" }

        let tokenized = sentences.map(words(in:))
        var frequencies: [String: Int] = [:]
        tokenized.flatMap { $0 }.forEach { frequencies[$0, default: 0] += 1 }

        let count = min(maximumPoints, max(1, Int(ceil(Double(sentences.count) / 2))))
        var ranked: [(index: Int, score: Double)] = []
        for index in sentences.indices {
            let words = tokenized[index]
            let relevance = words.isEmpty
                ? 0
                : Double(words.reduce(0) { $0 + frequencies[$1, default: 0] }) / Double(words.count)
            let positionBonus: Double = index == 0 ? 0.35 : 0
            let detailBonus: Double = min(Double(words.count), 20) / 100
            let score: Double = relevance + positionBonus + detailBonus
            ranked.append((index: index, score: score))
        }
        ranked.sort { left, right in
            left.score == right.score ? left.index < right.index : left.score > right.score
        }
        let selected = ranked.prefix(count).sorted { $0.index < $1.index }

        return selected.map { "• \(sentences[$0.index])" }.joined(separator: "\n")
    }

    private static func stripTranscriptPrefix(_ line: String) -> String? {
        guard let timestampEnd = line.firstIndex(of: "]"),
              let separator = line[line.index(after: timestampEnd)...].firstIndex(of: ":") else { return line }
        let content = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : content
    }

    private static func sentences(in text: String) -> [String] {
        var results: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { results.append(sentence) }
        }
        return results.isEmpty ? [text] : results
    }

    private static func words(in sentence: String) -> [String] {
        sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
