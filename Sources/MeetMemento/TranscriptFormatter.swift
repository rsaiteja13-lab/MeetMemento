import Foundation

enum TranscriptFormatter {
    private struct Block {
        let source: String
        let bucket: Int
        let words: [String]
    }

    static func format(_ segments: [TranscriptSegment]) -> String {
        let grouped = Dictionary(grouping: segments) { segment in
            "\(segment.source)|\(Int(segment.timestamp) / 30)"
        }
        let blocks = grouped.values.compactMap { values -> Block? in
            guard let first = values.first else { return nil }
            return Block(
                source: first.source,
                bucket: Int(first.timestamp) / 30,
                words: values.sorted { $0.timestamp < $1.timestamp }.map(\.text)
            )
        }.sorted {
            if $0.bucket == $1.bucket { return $0.source < $1.source }
            return $0.bucket < $1.bucket
        }

        return blocks.map { block in
            let seconds = max(0, block.bucket * 30)
            let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "[\(timestamp)] \(block.source): \(block.words.joined(separator: " "))"
        }.joined(separator: "\n\n")
    }
}
