import Foundation

// Adapts the existing Beans parser output; no second player or invented word timestamps.
enum FoliaBeansLyricBridge {
    static func document(trackIdentity: String, lyrics: [LyricLine], duration: Double) -> FoliaLyricDocument {
        let sorted = lyrics.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        // 对唱标注：识别出双人角色时剥离 LRC 角色标记并附带 agent；
        // 普通单人歌曲原样透传（见 FoliaLyricDuet）。
        let annotated = FoliaLyricDuet.annotate(sorted.map { $0.element })
        let lines = annotated.enumerated().map { index, entry -> FoliaLine in
            let line = entry.line
            let start = line.time.isFinite ? max(0, line.time) : 0
            let nextStart = annotated.dropFirst(index + 1).first { $0.line.time > start }?.line.time
            let validDuration = duration.isFinite ? max(0, duration) : 0
            let words = (line.words ?? []).enumerated().compactMap { wordIndex, word -> FoliaWord? in
                guard word.start.isFinite, word.duration.isFinite, word.duration >= 0 else { return nil }
                return FoliaWord(id: "\(index):\(wordIndex)", text: word.text,
                                 startTime: max(0, word.start), endTime: max(0, word.start + word.duration))
            }
            // LRC has no explicit end. Infer only the line endpoint, preserving genuine word endpoints.
            let inferredEnd = nextStart ?? (validDuration > start ? validDuration : start + 5)
            let end = max(start, words.map(\.endTime).max() ?? inferredEnd)
            return FoliaLine(id: "\(trackIdentity):\(index)", startTime: start, endTime: end,
                             fullText: line.text, translation: line.translation, romanization: nil, words: words,
                             agent: entry.agent)
        }
        return FoliaLyricDocument(trackIdentity: trackIdentity, lines: lines)
    }
}
