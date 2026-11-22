import Foundation

// Native timing contract: preserve real word timing and fullText independently.
struct FoliaWord: Identifiable, Codable, Hashable {
    let id: String
    let text: String
    let startTime: Double
    let endTime: Double
}

struct FoliaLine: Identifiable, Codable, Hashable {
    let id: String
    let startTime: Double
    let endTime: Double
    let fullText: String
    let translation: String?
    let romanization: String?
    let words: [FoliaWord]
    /// 对唱角色（由 FoliaLyricDuet 从 LRC 角色标记解析）；普通单人歌曲为 nil。
    let agent: FoliaLyricAgent?
}

/// 对唱演唱者角色，移植自 MeloX 的 LyricAgent（见 FoliaLyricDuet）。
struct FoliaLyricAgent: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case person
        case group
    }

    enum Alignment: String, Codable, Hashable {
        case normal
        case flipped
    }

    let identifier: String
    let displayName: String
    let kind: Kind
    let alignment: Alignment
}

struct FoliaLyricDocument: Codable, Hashable {
    let trackIdentity: String
    let lines: [FoliaLine]
}
