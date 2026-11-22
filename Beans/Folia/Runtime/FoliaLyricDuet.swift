//
//  FoliaLyricDuet.swift
//  Beans
//
//  对唱歌词分行解析，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Core/Lyrics/LyricDuetParser.swift，呈现于
//          MeloX/Features/Player/Lyrics/AppleMusic/AppleMusicLyricsView.swift
//          与 Shared/SynchronizedLyricText.swift（flipped 角色右对齐）。
//  解析来源：网易云 LRC 文本里的角色标记，两种形态——
//   - 独立标记行：整行只有【男】/【女】或「男：」，作用于紧随其后的演唱行；
//   - 行内标记：【男】歌词… 或「男：歌词…」，标记与歌词同行。
//  只有识别出至少两位演唱者时才生效；作词/作曲等元数据标签被排除，
//  「合/合唱」等群体角色归为 group 且不翻转。
//  与 MeloX 的差异：MeloX 的展示行可能来自 YRC，需要拿原始 LRC 做文本
//  对齐回填角色；Beans 的展示行本身就由 LRC 解析而来（逐字时间轴是后挂的
//  words），行文本即 LRC 文本，因此直接在行内解析标记并按时间传播当前
//  角色，省去 LRC↔YRC 对齐层。呈现落点为 Folia 的 Classic / Still 渲染器：
//  flipped 角色换边对齐并使用强调色，两个角色都带歌手名小标签。
//

import Foundation

struct FoliaAnnotatedLyricLine {
    let line: LyricLine
    let agent: FoliaLyricAgent?
}

enum FoliaLyricDuet {
    private struct RoleLabel: Hashable {
        let identifier: String
        let displayName: String
        let kind: FoliaLyricAgent.Kind
    }

    private struct InlineRole {
        let role: RoleLabel
        let content: String
        let prefixCharacterCount: Int
    }

    private struct RoleEvent {
        let time: TimeInterval
        let order: Int
        let role: RoleLabel
    }

    /// 输入须已按时间升序排列（FoliaBeansLyricBridge 保证）。
    static func annotate(_ lines: [LyricLine]) -> [FoliaAnnotatedLyricLine] {
        let unchanged = lines.map { FoliaAnnotatedLyricLine(line: $0, agent: nil) }
        guard !lines.isEmpty else { return unchanged }

        var standaloneEvents: [RoleEvent] = []
        var inlineEvents: [RoleEvent] = []
        var candidateStandaloneMarkerIndices = Set<Int>()

        for (index, line) in lines.enumerated() {
            if let inline = parseInlineRole(line.text) {
                inlineEvents.append(RoleEvent(time: line.time, order: index, role: inline.role))
            }

            guard let role = parseStandaloneRole(line.text),
                  index + 1 < lines.count else { continue }
            let gap = lines[index + 1].time - line.time
            guard gap >= 0, gap <= standaloneMarkerMaximumGap else { continue }
            candidateStandaloneMarkerIndices.insert(index)
            standaloneEvents.append(RoleEvent(time: lines[index + 1].time, order: index, role: role))
        }

        standaloneEvents = sortedEvents(standaloneEvents)
        inlineEvents = sortedEvents(inlineEvents)
        let usesStandaloneMarkers = uniquePersonCount(in: standaloneEvents) >= 2
        let events = usesStandaloneMarkers ? standaloneEvents : inlineEvents
        let standaloneMarkerIndices = usesStandaloneMarkers ? candidateStandaloneMarkerIndices : []

        guard uniquePersonCount(in: events) >= 2 else { return unchanged }

        let alignments = makeAlignments(for: events)
        let recognizedIdentifiers = Set(events.map { $0.role.identifier })

        return lines.enumerated().compactMap { index, line in
            if standaloneMarkerIndices.contains(index) {
                return nil
            }
            if isStandaloneMarker(line, recognizedIdentifiers: recognizedIdentifiers) {
                return nil
            }

            let inline = parseInlineRole(line.text).flatMap {
                recognizedIdentifiers.contains($0.role.identifier) ? $0 : nil
            }
            let role = inline?.role ?? activeRole(at: line.time, in: events, tolerance: mappingTolerance)
            guard let role, let alignment = alignments[role.identifier] else {
                return FoliaAnnotatedLyricLine(line: line, agent: nil)
            }

            let agent = FoliaLyricAgent(
                identifier: role.identifier,
                displayName: role.displayName,
                kind: role.kind,
                alignment: alignment
            )

            guard let inline else {
                return FoliaAnnotatedLyricLine(line: line, agent: agent)
            }
            // 行内标记：剥掉「角色：」前缀，文本与逐字时间轴同步剥离。
            let words = line.words.map {
                droppingPrefix(characterCount: inline.prefixCharacterCount, from: $0)
            }
            let cleaned = LyricLine(
                time: line.time,
                text: inline.content,
                translation: line.translation,
                words: words
            )
            return FoliaAnnotatedLyricLine(line: cleaned, agent: agent)
        }
    }

    // MARK: - 标记解析

    private static func parseStandaloneRole(_ text: String) -> RoleLabel? {
        firstRoleMatch(in: text, expressions: [standaloneBracketExpression, standaloneColonExpression])?.role
    }

    private static func parseInlineRole(_ text: String) -> InlineRole? {
        firstRoleMatch(in: text, expressions: [inlineBracketExpression, inlineColonExpression])
    }

    private static func firstRoleMatch(
        in text: String,
        expressions: [NSRegularExpression]
    ) -> InlineRole? {
        let fullRange = NSRange(text.startIndex..., in: text)
        for expression in expressions {
            guard let match = expression.firstMatch(in: text, range: fullRange),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let role = makeRole(String(text[labelRange])) else {
                continue
            }

            guard match.numberOfRanges > 2,
                  match.range(at: 2).location != NSNotFound,
                  let contentRange = Range(match.range(at: 2), in: text) else {
                return InlineRole(role: role, content: "", prefixCharacterCount: text.count)
            }

            let content = String(text[contentRange]).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty,
                  let contentStart = text.range(of: content, range: contentRange)?.lowerBound else {
                continue
            }
            return InlineRole(
                role: role,
                content: content,
                prefixCharacterCount: text.distance(from: text.startIndex, to: contentStart)
            )
        }
        return nil
    }

    private static func makeRole(_ rawLabel: String) -> RoleLabel? {
        let displayName = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= maximumRoleLength else { return nil }

        let identifier = normalizedRoleIdentifier(displayName)
        guard !identifier.isEmpty, !metadataRoleIdentifiers.contains(identifier) else { return nil }
        return RoleLabel(
            identifier: identifier,
            displayName: displayName,
            kind: groupRoleIdentifiers.contains(identifier) ? .group : .person
        )
    }

    private static func isStandaloneMarker(
        _ line: LyricLine,
        recognizedIdentifiers: Set<String>
    ) -> Bool {
        guard let role = parseStandaloneRole(line.text) else { return false }
        return recognizedIdentifiers.contains(role.identifier)
    }

    // MARK: - 事件处理

    private static func removingRedundantEvents(_ events: [RoleEvent]) -> [RoleEvent] {
        var result: [RoleEvent] = []
        for event in events {
            if result.last?.role.identifier == event.role.identifier {
                continue
            }
            if let last = result.last, abs(last.time - event.time) < 0.000_5 {
                result[result.count - 1] = event
            } else {
                result.append(event)
            }
        }
        return result
    }

    private static func sortedEvents(_ events: [RoleEvent]) -> [RoleEvent] {
        removingRedundantEvents(
            events.sorted {
                $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time
            }
        )
    }

    private static func uniquePersonCount(in events: [RoleEvent]) -> Int {
        Set(events.filter { $0.role.kind == .person }.map { $0.role.identifier }).count
    }

    private static func makeAlignments(
        for events: [RoleEvent]
    ) -> [String: FoliaLyricAgent.Alignment] {
        var result: [String: FoliaLyricAgent.Alignment] = [:]
        var personIndex = 0
        for event in events where result[event.role.identifier] == nil {
            if event.role.kind == .group {
                result[event.role.identifier] = .normal
            } else {
                result[event.role.identifier] = personIndex.isMultiple(of: 2) ? .normal : .flipped
                personIndex += 1
            }
        }
        return result
    }

    private static func activeRole(
        at time: TimeInterval,
        in events: [RoleEvent],
        tolerance: TimeInterval = 0
    ) -> RoleLabel? {
        var role: RoleLabel?
        for event in events {
            guard event.time <= time + tolerance else { break }
            role = event.role
        }
        return role
    }

    // MARK: - 逐字前缀剥离

    private static func droppingPrefix(
        characterCount: Int,
        from syllables: [LyricWord]
    ) -> [LyricWord] {
        guard characterCount > 0, !syllables.isEmpty else { return syllables }

        var remaining = characterCount
        var result: [LyricWord] = []
        for word in syllables {
            let characters = Array(word.text)
            guard !characters.isEmpty else { continue }
            if remaining >= characters.count {
                remaining -= characters.count
                continue
            }

            if remaining > 0 {
                let removedFraction = Double(remaining) / Double(characters.count)
                let adjustedStart = word.start + word.duration * removedFraction
                result.append(
                    LyricWord(
                        text: String(characters.dropFirst(remaining)),
                        start: adjustedStart,
                        duration: word.duration * (1 - removedFraction)
                    )
                )
                remaining = 0
            } else {
                result.append(word)
            }
        }
        return result
    }

    private static func normalizedRoleIdentifier(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static let maximumRoleLength = 24
    private static let standaloneMarkerMaximumGap: TimeInterval = 1
    private static let mappingTolerance: TimeInterval = 0.35

    private static let metadataRoleIdentifiers: Set<String> = [
        "词", "曲", "作词", "作曲", "编曲", "制作", "制作人", "监制", "出品",
        "演唱", "歌手", "和声编写", "混音", "录音", "母带", "吉他", "贝斯", "鼓",
        "键盘", "lyricist", "lyrics", "composer", "arranger", "producer",
        "mixing", "recording", "mastering", "vocal", "vocals", "artist",
    ]

    private static let groupRoleIdentifiers: Set<String> = [
        "合", "合唱", "合声", "和声", "众", "全员", "二人", "俩", "all", "both",
        "together", "chorus", "ensemble", "group",
    ]

    private static let standaloneBracketExpression = try! NSRegularExpression(
        pattern: #"^\s*【([^】]{1,24})】\s*$"#
    )
    private static let standaloneColonExpression = try! NSRegularExpression(
        pattern: #"^\s*([^:：]{1,24})\s*[:：]\s*$"#
    )
    private static let inlineBracketExpression = try! NSRegularExpression(
        pattern: #"^\s*【([^】]{1,24})】\s*(\S.*)$"#
    )
    private static let inlineColonExpression = try! NSRegularExpression(
        pattern: #"^\s*([^:：]{1,24})\s*[:：]\s*(\S.*)$"#
    )
}
