import Foundation

enum MeetingNamer {
    private static let ignoredWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "been", "before", "being", "but",
        "can", "could", "did", "does", "for", "from", "going", "had", "has", "have", "hello", "hey",
        "how", "into", "just", "know", "like", "meeting", "more", "not", "now", "okay", "our", "out",
        "should", "some", "that", "the", "their", "then", "there", "these", "they", "think", "this",
        "those", "today", "very", "want", "was", "were", "what", "when", "where", "which", "who", "will",
        "with", "would", "yeah", "yes", "you", "your", "zoom"
    ]

    static func title(from transcript: String) -> String? {
        var counts: [String: Int] = [:]
        var firstPosition: [String: Int] = [:]
        var position = 0

        transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !ignoredWords.contains($0) }
            .forEach { word in
                counts[word, default: 0] += 1
                if firstPosition[word] == nil { firstPosition[word] = position }
                position += 1
            }

        let keywords = counts.keys.sorted { left, right in
            let leftCount = counts[left, default: 0]
            let rightCount = counts[right, default: 0]
            if leftCount != rightCount { return leftCount > rightCount }
            return firstPosition[left, default: .max] < firstPosition[right, default: .max]
        }.prefix(3)

        guard !keywords.isEmpty else { return nil }
        return keywords.map { $0.capitalized }.joined(separator: " · ")
    }
}
