import Foundation
import Combine

enum QishuiAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "汽水音乐接口地址无效"
        case .invalidResponse: return "汽水音乐返回了无法识别的数据"
        case .server(let message): return message
        }
    }
}

struct QishuiPlaylistDetails {
    let playlist: Playlist?
    let songs: [Song]
}

private final class QishuiCacheBox<Value>: NSObject {
    let value: Value
    let savedAt: Date

    init(value: Value, savedAt: Date = Date()) {
        self.value = value
        self.savedAt = savedAt
    }
}

enum QishuiResourceURL {
    static func first(in value: Any?) -> URL? {
        first(in: value, depth: 0)
    }

    static func playlistCover(in playlist: [String: Any]) -> URL? {
        let raw = playlist["raw"] as? [String: Any] ?? playlist
        let keys = ["url_cover", "cover_url", "coverURL", "urlCover", "cover_uri", "cover", "pic_url", "picUrl"]
        for key in keys {
            if let url = first(in: raw[key]) { return normalizedPlaylistCover(url) }
        }
        for key in keys {
            if let url = first(in: playlist[key]) { return normalizedPlaylistCover(url) }
        }
        return nil
    }

    private static func first(in value: Any?, depth: Int) -> URL? {
        guard depth < 8 else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = trimmed.hasPrefix("//") ? "https:\(trimmed)" : trimmed
            guard let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return url
        }
        if let values = value as? [Any] {
            return values.lazy.compactMap { first(in: $0, depth: depth + 1) }.first
        }
        guard let object = value as? [String: Any] else { return nil }

        if let direct = first(in: object["url"], depth: depth + 1) {
            return direct
        }

        if let uri = object["uri"] as? String,
           let base = first(in: object["urls"] ?? object["url_list"], depth: depth + 1),
           let completed = complete(uri: uri, using: base, templatePrefix: object["template_prefix"] as? String) {
            return completed
        }

        let preferredKeys = [
            "url", "urls", "url_list", "cover_url", "cover_urls", "url_cover",
            "origin_url", "origin_url_list", "uri", "cover", "artwork"
        ]
        for key in preferredKeys {
            if let url = first(in: object[key], depth: depth + 1) { return url }
        }
        for nested in object.values {
            if let url = first(in: nested, depth: depth + 1) { return url }
        }
        return nil
    }

    private static func complete(uri: String, using base: URL, templatePrefix: String?) -> URL? {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let direct = URL(string: value),
           ["http", "https"].contains(direct.scheme?.lowercased() ?? ""),
           direct.host != nil {
            return direct
        }
        if base.absoluteString.contains(value) { return base }
        guard value.contains("/") || base.path.hasSuffix("/") else { return nil }
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        guard let templatePrefix = templatePrefix?.trimmingCharacters(in: .whitespacesAndNewlines),
              !templatePrefix.isEmpty,
              !value.contains("~tplv-") else {
            return url
        }
        return URL(string: "\(url.absoluteString)~\(templatePrefix)-crop-center:720:720.jpg") ?? url
    }

    private static func normalizedPlaylistCover(_ url: URL) -> URL {
        guard url.host?.lowercased().hasSuffix("douyinpic.com") == true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.contains("/img/"),
              !components.percentEncodedPath.contains("~tplv-") else {
            return url
        }
        components.percentEncodedPath += "~tplv-b829550vbb-crop-center:720:720.jpg"
        return components.url ?? url
    }
}

struct QishuiSearchPageState {
    let hasMore: Bool
    let nextOffset: Int

    static func resolve(_ response: [String: Any], currentOffset: Int, receivedCount: Int) -> Self {
        let upstream = response["upstream"] as? [String: Any] ?? [:]
        let upstreamData = upstream["data"] as? [String: Any] ?? [:]
        let pagination = response["pagination"] as? [String: Any]
            ?? upstream["pagination"] as? [String: Any]
            ?? upstreamData["pagination"] as? [String: Any]
            ?? [:]
        let sources = [response, upstream, upstreamData, pagination]
        let moreValue = firstValue(in: sources, keys: ["has_more", "hasMore", "has_next", "hasNext"])
        let explicitMore = boolean(moreValue)
        let cursorValue = firstValue(in: sources, keys: ["next_offset", "nextOffset", "next_cursor", "nextCursor", "cursor"])
        let parsedCursor = integer(cursorValue)
        let nextOffset = parsedCursor.flatMap { $0 > currentOffset ? $0 : nil }
            ?? currentOffset + max(receivedCount, 1)
        return Self(
            hasMore: explicitMore ?? (parsedCursor.map { $0 > currentOffset } ?? false),
            nextOffset: nextOffset
        )
    }

    private static func firstValue(in sources: [[String: Any]], keys: [String]) -> Any? {
        for source in sources {
            for key in keys {
                if let value = source[key] { return value }
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// 汽水音乐统一网关客户端。
///
/// 汽水曲目和歌单 ID 使用字符串保存，避免把 19 位 ID 截断成 Int。客户端
/// 只把稳定的展示用 Int 写入现有模型，真正请求始终使用 qishuiID。
final class QishuiAPI: ObservableObject {
    static let shared = QishuiAPI()

    private static let baseURLKey = "beans.qishui.apiBaseURL"
    private static let defaultBaseURL = "http://189.24.78.193/qishui"
    private static let fastCatalogPaths: Set<String> = [
        "/search/mixed", "/search", "/search/playlist", "/recommend/playlist"
    ]

    private let session: URLSession
    // 汽水官方直连会话（api.qishui.com）：搜索、歌单、歌词、评论、每日推荐与
    // 扫码登录优先走直连，上面的网关只作兜底。独立会话开启 Cookie 存储，
    // 承接官网预热的 ttwid 与扫码登录换回的会话 Cookie。
    private let directSession: URLSession
    private let directDeviceID: String
    private let directInstallID: String
    private var directWarmedUp = false
    private let directStateLock = NSLock()
    /// 扫码登录轮询期间按 token 累积的 Cookie 罐（对齐 music-lib 的 pending
    /// state：每轮把响应新下的 Cookie 合并后带上下一轮，不能只靠共享存储）。
    private var qrCookieJars: [String: String] = [:]
    private let songSearchCache = NSCache<NSString, QishuiCacheBox<[Song]>>()
    private let playlistSearchCache = NSCache<NSString, QishuiCacheBox<[Playlist]>>()
    private let recommendationCache = NSCache<NSString, QishuiCacheBox<[Playlist]>>()
    private let playlistDetailsCache = NSCache<NSString, QishuiCacheBox<QishuiPlaylistDetails>>()

    private let songSearchTTL: TimeInterval = 5 * 60
    private let playlistSearchTTL: TimeInterval = 5 * 60
    private let recommendationTTL: TimeInterval = 30 * 60
    private let playlistDetailsTTL: TimeInterval = 30 * 60

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        let directConfiguration = URLSessionConfiguration.default
        directConfiguration.timeoutIntervalForRequest = 20
        directConfiguration.timeoutIntervalForResource = 30
        directConfiguration.httpCookieAcceptPolicy = .always
        directConfiguration.httpShouldSetCookies = true
        directSession = URLSession(configuration: directConfiguration)
        // PC 客户端参数里的 device_id / iid：按 music-lib 的做法用毫秒时间戳伪造，
        // 进程内保持不变即可。
        let deviceSeed = Int64(Date().timeIntervalSince1970 * 1000)
        directDeviceID = String(deviceSeed)
        directInstallID = String(deviceSeed + 1)
        songSearchCache.countLimit = 40
        playlistSearchCache.countLimit = 40
        recommendationCache.countLimit = 8
        playlistDetailsCache.countLimit = 24
    }

    // MARK: - Search

    func searchSongs(
        keyword: String,
        limit: Int = 30,
        onPartialResults: (@MainActor ([Song]) -> Void)? = nil
    ) async throws -> [Song] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let targetCount = min(max(limit, 1), 200)
        let cacheKey = catalogCacheKey("songs", query: trimmed, limit: targetCount)
        let (cached, stale) = cacheLookup(songSearchCache, key: cacheKey, ttl: songSearchTTL, staleTTL: 48 * 3600)
        if let cached { return cached }

        // 直连优先：汽水 PC 网页端搜索 /luna/pc/search/track（参考 music-lib
        // sodaPCWebSearchURL，无需签名）。网页端无结果时再走安卓端搜索
        // /luna/search/track（music-lib fetchTrackSearch 的第三顺位兜底；
        // 网页端在部分网络下会被风控回空，安卓端参数面不同）。两路直连都
        // 抛错或为空才落到下面的网关分页逻辑兜底。
        if let direct = try? await directSearchSongs(
            keyword: trimmed,
            targetCount: targetCount,
            onPartialResults: onPartialResults
        ), !direct.isEmpty {
            cache(direct, in: songSearchCache, key: cacheKey)
            return direct
        }
        if let android = try? await directAndroidSearchSongs(
            keyword: trimmed,
            targetCount: targetCount,
            onPartialResults: onPartialResults
        ), !android.isEmpty {
            cache(android, in: songSearchCache, key: cacheKey)
            return android
        }

        var songs: [Song] = []
        var seenSongs = Set<String>()
        var offset = 0
        var visitedOffsets = Set<Int>()

        do {
            for _ in 0..<10 where songs.count < targetCount {
                guard !Task.isCancelled else { throw CancellationError() }
                guard visitedOffsets.insert(offset).inserted else { break }
                let pageSize = min(100, targetCount - songs.count)
                let query = [
                    "keywords": trimmed,
                    "count": String(pageSize),
                    "cursor": String(offset),
                    "offset": String(offset),
                ]
                let mixed = try await requestObject("/search/mixed", query: query)
                var pageSongs = trackDictionaries(mixed["tracks"] ?? mixed["data"] ?? mixed).compactMap(makeSong)
                var pageResponse = mixed
                if pageSongs.isEmpty {
                    let direct = try await requestObject("/search", query: query)
                    pageSongs = trackDictionaries(direct["tracks"] ?? direct["data"] ?? direct).compactMap(makeSong)
                    pageResponse = direct
                }
                guard !pageSongs.isEmpty else { break }
                let receivedCount = pageSongs.count
                let previousCount = songs.count
                for song in pageSongs where seenSongs.insert(song.identityKey).inserted {
                    songs.append(song)
                    if songs.count >= targetCount { break }
                }
                let currentResults = Array(deduplicated(songs).prefix(targetCount))
                if currentResults.count > previousCount, let onPartialResults {
                    await onPartialResults(currentResults)
                }
                let pageState = QishuiSearchPageState.resolve(
                    pageResponse,
                    currentOffset: offset,
                    receivedCount: receivedCount
                )
                guard pageState.hasMore, pageState.nextOffset > offset else { break }
                offset = pageState.nextOffset
            }
        } catch {
            if Task.isCancelled { throw error }
            if !songs.isEmpty { return Array(deduplicated(songs).prefix(targetCount)) }
            if let stale { return stale }
            throw error
        }

        let result = Array(deduplicated(songs).prefix(targetCount))
        if !result.isEmpty {
            cache(result, in: songSearchCache, key: cacheKey)
            return result
        }
        return stale ?? []
    }

    func searchPlaylists(keyword: String, limit: Int = 30) async throws -> [Playlist] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let targetCount = min(max(limit, 1), 50)
        let cacheKey = catalogCacheKey("playlists", query: trimmed, limit: targetCount)
        let (cached, stale) = cacheLookup(playlistSearchCache, key: cacheKey, ttl: playlistSearchTTL, staleTTL: 7 * 24 * 3600)
        if let cached { return cached }
        do {
            // 直连优先：/luna/pc/search/playlist，失败或为空回退网关。
            if let direct = try? await directSearchPlaylists(keyword: trimmed, limit: targetCount),
               !direct.isEmpty {
                cache(direct, in: playlistSearchCache, key: cacheKey)
                return direct
            }
            let data = try await requestObject("/search/playlist", query: [
                "keywords": trimmed,
                "count": String(targetCount),
            ])
            let results = playlistDictionaries(data["playlists"] ?? data["data"] ?? data)
                .compactMap(makePlaylist)
                .prefix(targetCount)
                .map { $0 }
            if !results.isEmpty {
                cache(results, in: playlistSearchCache, key: cacheKey)
                return results
            }
            return stale ?? []
        } catch {
            if Task.isCancelled { throw error }
            if let stale { return stale }
            throw error
        }
    }

    func searchArtists(keyword: String, limit: Int = 40) async throws -> [Artist] {
        let songs = try await searchSongs(keyword: keyword, limit: min(max(limit * 2, 40), 200))
        var result: [Artist] = []
        var seen = Set<String>()
        for song in songs {
            let artistNames = splitArtists(song.artists)
            for name in artistNames {
                let key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(Artist(
                    id: "qishui-artist-\(Self.stableID(key))",
                    name: name,
                    coverURL: song.coverURL,
                    source: .qishui
                ))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    func searchAlbums(keyword: String, limit: Int = 40) async throws -> [Album] {
        // 专辑有独立 PC 搜索端点 /luna/pc/search/album，直连优先；直连失败或
        // 为空时回退到从搜歌结果聚合（数据源同样是直连优先的 searchSongs，
        // 网关完全不可用时歌手 / 专辑依然能出结果）。歌手没有独立 PC 端点，
        // searchArtists 一直走聚合，数据源即上面的 searchSongs。
        if let direct = try? await directSearchAlbums(keyword: keyword, limit: limit),
           !direct.isEmpty {
            return direct
        }
        let songs = try await searchSongs(keyword: keyword, limit: min(max(limit * 3, 80), 200))
        return albums(from: songs, limit: limit)
    }

    // MARK: - Discovery and collections

    func recommendedPlaylists(limit: Int = 18) async throws -> [Playlist] {
        let targetCount = min(max(limit, 1), 50)
        let cacheKey = catalogCacheKey("recommendations", query: "guest", limit: targetCount)
        let (cached, stale) = cacheLookup(recommendationCache, key: cacheKey, ttl: recommendationTTL, staleTTL: 7 * 24 * 3600)
        if let cached { return cached }
        do {
            // 直连优先：POST /luna/pc/discover/mix（discover_playlist_mix），
            // 失败或为空回退网关 /recommend/playlist。
            if let direct = try? await directRecommendedPlaylists(limit: targetCount),
               !direct.isEmpty {
                cache(direct, in: recommendationCache, key: cacheKey)
                return direct
            }
            let data = try await requestObject("/recommend/playlist", query: [
                "count": String(targetCount),
            ])
            let results = playlistDictionaries(data["playlists"] ?? data["data"] ?? data)
                .compactMap(makePlaylist)
                .prefix(targetCount)
                .map { $0 }
            if !results.isEmpty {
                cache(results, in: recommendationCache, key: cacheKey)
                return results
            }
            return stale ?? []
        } catch {
            if Task.isCancelled { throw error }
            if let stale { return stale }
            throw error
        }
    }

    /// 汽水官方榜单目录（固定四榜，不依赖网络；music-lib
    /// sodaTopListDefinitions 同源数据）。
    static let builtinCharts: [QishuiChartInfo] = [
        QishuiChartInfo(
            id: "7036274230471712007",
            name: "热歌榜",
            coverURL: URL(string: "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/d0d8d48461a62748e84689cdf049b19a.png~tplv-b829550vbb-resize:960:960.png"),
            updateFrequency: "每周四更新",
            trackCount: 50,
            chartDescription: "汽水音乐内每周热度最高的50首歌，每周四更新"
        ),
        QishuiChartInfo(
            id: "7060812597884869927",
            name: "新歌榜",
            coverURL: URL(string: "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/f12f7eb5b54d0899c7c724df009668a8.png~tplv-b829550vbb-resize:960:960.png"),
            updateFrequency: "每周四更新",
            trackCount: 50,
            chartDescription: "近期发行的热度最高的50首新歌，每周四更新"
        ),
        QishuiChartInfo(
            id: "7061475546400005410",
            name: "欧美榜",
            coverURL: URL(string: "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/33747550ed5499b58feda42a21748637.png~tplv-b829550vbb-resize:960:960.png"),
            updateFrequency: "每周四更新",
            trackCount: 50,
            chartDescription: "汽水音乐内每周热度最高的50首外文歌曲，每周四更新"
        ),
        QishuiChartInfo(
            id: "7415959718721494311",
            name: "音乐人歌曲榜",
            coverURL: URL(string: "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/o8FQKiQQBxHWa2hzsBNAgYOX6iEHEAibADAbfB~tplv-b829550vbb-resize:960:960.png"),
            updateFrequency: "每周四更新",
            trackCount: 25,
            chartDescription: "抖音音乐人开放平台上传歌曲，综合每周站内热度进行排序展示"
        ),
    ]

    /// 榜单歌曲：官方榜单走 /luna/pc/charts/<id>，失败或为空回退歌单详情
    /// （music-lib fetchTopListSongs 同款双链路）。
    func chartSongs(id: String) async throws -> [Song] {
        if let songs = try? await directChartSongs(id: id), !songs.isEmpty {
            return songs
        }
        let details = try await playlistDetails(id: id)
        return details.songs
    }

    private func directChartSongs(id: String) async throws -> [Song] {
        let root = try await directRequestObject(
            path: "luna/pc/charts/\(id)",
            queryItems: directAppItems(extra: []),
            lunaPCHeaders: true,
            includeAuthCookie: true
        )
        guard let chart = dictionary(root["chart"]) else {
            throw QishuiAPIError.invalidResponse
        }
        return dictionaryArray(chart["track_ranks"]).compactMap {
            makeSong(normalizedPCEntity($0))
        }
    }

    func playlistDetails(
        id: String,
        count: Int = 1000,
        forceRefresh: Bool = false,
        onPartialSongs: (@MainActor ([Song]) -> Void)? = nil
    ) async throws -> QishuiPlaylistDetails {
        let targetCount = min(max(count, 1), 1000)
        let baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        let cacheKey = "details|\(baseURL)|\(id)|\(targetCount)"
        let (cached, stale) = cacheLookup(playlistDetailsCache, key: cacheKey, ttl: playlistDetailsTTL, staleTTL: 7 * 24 * 3600)
        if let cached, !forceRefresh {
            if let onPartialSongs { await onPartialSongs(cached.songs) }
            return cached
        }
        let fallback = cached ?? stale
        // 直连优先：/luna/pc/playlist/detail（PC 客户端参数 + LunaPC 请求头，
        // 参考 music-lib sodaPCPlaylistDetailURL）。直连拿到歌曲就用直连结果，
        // 抛错或为空才走下面的网关分页兜底。
        if let direct = try? await directPlaylistDetails(
            id: id,
            targetCount: targetCount,
            onPartialSongs: onPartialSongs
        ), !direct.songs.isEmpty {
            cache(direct, in: playlistDetailsCache, key: cacheKey)
            return direct
        }
        let pageSize = min(targetCount, 100)
        var cursor = ""
        var sessionID = ""
        var visitedCursors = Set<String>()
        var playlist: Playlist?
        var songs: [Song] = []
        var seenSongs = Set<String>()

        do {
            for _ in 0..<20 where songs.count < targetCount {
                guard !Task.isCancelled else { throw CancellationError() }
                var query = ["playlist_id": id, "count": String(pageSize)]
                if !cursor.isEmpty { query["cursor"] = cursor }
                if !sessionID.isEmpty { query["session_id"] = sessionID }
                let data = try await requestObject("/playlist/detail", query: query)
                if sessionID.isEmpty {
                    sessionID = firstString(data, keys: ["session_id", "sessionId"]) ?? ""
                }
                if playlist == nil {
                    playlist = dictionary(data["playlist"]).flatMap(makePlaylist)
                }
                let resources = data["media_resources"] ?? data["tracks"] ?? data["songs"] ?? []
                let pageSongs = trackDictionaries(resources).compactMap(makeSong)
                guard !pageSongs.isEmpty else { break }
                for song in pageSongs where seenSongs.insert(song.identityKey).inserted {
                    songs.append(song)
                    if songs.count >= targetCount { break }
                }
                if !songs.isEmpty, let onPartialSongs {
                    await onPartialSongs(Array(songs.prefix(targetCount)))
                }
                let nextCursor = firstString(data, keys: ["next_cursor", "nextCursor", "cursor"]) ?? ""
                guard !nextCursor.isEmpty,
                      nextCursor != cursor,
                      visitedCursors.insert(nextCursor).inserted else { break }
                cursor = nextCursor
            }
        } catch {
            if Task.isCancelled { throw error }
            if let fallback { return fallback }
            throw error
        }
        let result = QishuiPlaylistDetails(playlist: playlist, songs: Array(songs.prefix(targetCount)))
        if !result.songs.isEmpty {
            cache(result, in: playlistDetailsCache, key: cacheKey)
            return result
        }
        return fallback ?? result
    }

    func playlistSongs(
        id: String,
        count: Int = 1000,
        forceRefresh: Bool = false,
        onPartialSongs: (@MainActor ([Song]) -> Void)? = nil
    ) async throws -> [Song] {
        try await playlistDetails(
            id: id,
            count: count,
            forceRefresh: forceRefresh,
            onPartialSongs: onPartialSongs
        ).songs
    }

    func artistSongs(name: String, limit: Int = 300) async throws -> [Song] {
        let songs = try await searchSongs(keyword: name, limit: max(limit, 100))
        let expected = normalizedArtist(name)
        let matching = songs.filter { song in
            splitArtists(song.artists).contains { normalizedArtist($0).contains(expected) || expected.contains(normalizedArtist($0)) }
        }
        return Array((matching.isEmpty ? songs : matching).prefix(limit))
    }

    func artistAlbums(name: String, limit: Int = 60) async throws -> [Album] {
        albums(from: try await artistSongs(name: name, limit: max(limit * 4, 160)), limit: limit)
    }

    func albumSongs(album: Album, limit: Int = 300) async throws -> [Song] {
        let query = [album.artistName, album.name]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let songs = try await searchSongs(keyword: query.isEmpty ? album.name : query, limit: limit)
        let expected = normalizedAlbum(album.name)
        let matching = songs.filter { normalizedAlbum($0.album) == expected }
        return Array((matching.isEmpty ? songs : matching).prefix(limit))
    }

    // MARK: - Playback, lyrics and comments

    func playbackURL(for song: Song) async throws -> URL? {
        guard let identifier = song.qishuiID, !identifier.isEmpty else { return nil }
        let detail = try await requestObject("/song/detail", query: ["track_id": identifier])
        if let url = firstURL(in: detail, keys: ["audio_url", "play_url", "main_url", "backup_url"]) {
            return url
        }
        let info = try await requestObject("/audio/info", query: ["track_id": identifier])
        return firstURL(in: info, keys: ["audio_url", "play_url", "main_url", "backup_url"])
    }

    func lyric(for song: Song) async throws -> String? {
        guard let identifier = song.qishuiID, !identifier.isEmpty else { return nil }
        // 直连优先：歌曲详情自带歌词（track_v2 / h5 seo_track 的 lyric.content，
        // 汽水逐字格式转标准 LRC），网关 /lyric 兜底。取链 playbackURL 不动。
        let directLyricText = (try? await directLyric(trackID: identifier)) ?? nil
        if let directLyricText, !directLyricText.isEmpty {
            return directLyricText
        }
        let data = try await requestObject("/lyric", query: ["track_id": identifier])
        if let lyric = firstString(data, keys: ["lyric", "lyrics", "content", "lrc"]), !lyric.isEmpty {
            return lyric
        }
        return nil
    }

    func comments(for song: Song, limit: Int = 30) async throws -> NetEaseAPI.SongCommentPage {
        guard let identifier = song.qishuiID, !identifier.isEmpty else {
            return NetEaseAPI.SongCommentPage(total: 0, hot: [], comments: [])
        }
        // 直连优先：GET /luna/comments（qishui-api 的评论端点，group_id = track_id），
        // 抛错或无评论时回退网关 /comment。
        if let direct = try? await directComments(trackID: identifier, limit: limit) {
            return direct
        }
        let data = try await requestObject("/comment", query: [
            "track_id": identifier,
            "count": String(min(max(limit, 1), 50)),
        ])
        let comments = dictionaryArray(data["comments"] ?? data["data"] ?? data).compactMap { raw -> SongComment? in
            let idText = firstString(raw, keys: ["id", "comment_id", "commentId"]) ?? UUID().uuidString
            let nickname = firstString(raw, keys: ["user_name", "nickname", "userName"]) ?? "汽水用户"
            let content = firstString(raw, keys: ["content", "text", "comment_text"]) ?? ""
            guard !content.isEmpty else { return nil }
            let avatar = firstString(raw, keys: ["user_avatar", "avatar_url", "avatarUrl"]).flatMap(URL.init(string:))
            let timestamp = number(raw["timestamp"] ?? raw["create_time"] ?? raw["time"])
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
            return SongComment(
                id: Self.stableID(idText),
                content: content,
                nickname: nickname,
                avatarURL: avatar,
                time: Date(timeIntervalSince1970: seconds > 0 ? seconds : Date().timeIntervalSince1970),
                likedCount: Int(number(raw["like_count"] ?? raw["likeCount"])),
                isHot: false
            )
        }
        return NetEaseAPI.SongCommentPage(total: comments.count, hot: [], comments: comments)
    }

    // MARK: - HTTP

    private func requestObject(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let value = try await requestValue(path, method: method, query: query, body: body)
        if let object = value as? [String: Any] { return object }
        throw QishuiAPIError.invalidResponse
    }

    private func requestValue(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> Any {
        guard let baseURL = URL(string: UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL),
              var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        else { throw QishuiAPIError.invalidURL }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw QishuiAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.fastCatalogPaths.contains(path) ? 15 : 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Beans-Music/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw QishuiAPIError.server("汽水音乐服务器请求失败")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QishuiAPIError.invalidResponse
        }
        let code = Int(number(root["code"]))
        if code != 0 {
            throw QishuiAPIError.server(firstString(root, keys: ["message", "msg"]) ?? "汽水音乐接口返回失败")
        }
        return root["data"] ?? [:]
    }

    private func catalogCacheKey(_ category: String, query: String, limit: Int) -> String {
        let normalized = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        return "\(category)|\(baseURL)|\(limit)|\(normalized)"
    }

    private func cacheLookup<Value>(
        _ cache: NSCache<NSString, QishuiCacheBox<Value>>,
        key: String,
        ttl: TimeInterval,
        staleTTL: TimeInterval
    ) -> (fresh: Value?, stale: Value?) {
        guard let entry = cache.object(forKey: key as NSString) else { return (nil, nil) }
        let age = Date().timeIntervalSince(entry.savedAt)
        if age < ttl { return (entry.value, nil) }
        return age < staleTTL ? (nil, entry.value) : (nil, nil)
    }

    private func cache<Value>(
        _ value: Value,
        in cache: NSCache<NSString, QishuiCacheBox<Value>>,
        key: String
    ) {
        cache.setObject(QishuiCacheBox(value: value), forKey: key as NSString)
    }

    // MARK: - Mapping helpers

    private func makeSong(_ raw: [String: Any]) -> Song? {
        let entity = dictionary(raw["entity"])
        let wrapper = dictionary(entity?["track_wrapper"] ?? raw["track_wrapper"])
        let track = dictionary(entity?["track"])
            ?? dictionary(raw["track"])
            ?? dictionary(wrapper?["track"])
            ?? raw
        guard let identifier = firstString(track, keys: ["id", "track_id"]), !identifier.isEmpty else { return nil }
        let album = dictionary(track["album"])
        let sourceTrack = dictionary(track["raw"]) ?? track
        let sourceAlbum = dictionary(sourceTrack["album"])
        let artistValues = dictionaryArray(track["artists"])
        let artistText = artistValues.compactMap { firstString($0, keys: ["name", "simple_display_name"]) }.joined(separator: " / ")
        let albumName = firstString(album, keys: ["name"]) ?? firstString(track, keys: ["album_name", "albumName"]) ?? ""
        let cover = QishuiResourceURL.first(in: sourceAlbum?["url_cover"])
            ?? QishuiResourceURL.first(in: sourceAlbum?["cover_url"])
            ?? QishuiResourceURL.first(in: album?["cover_url"])
            ?? QishuiResourceURL.first(in: album?["coverURL"])
            ?? QishuiResourceURL.first(in: album?["url_cover"])
            ?? QishuiResourceURL.first(in: track["cover_url"])
            ?? QishuiResourceURL.first(in: track["coverURL"])
            ?? QishuiResourceURL.first(in: track["url_cover"])
            ?? QishuiResourceURL.first(in: track["cover_uri"])
        let rawDuration = number(track["duration"] ?? track["duration_ms"] ?? track["interval"])
        let duration = rawDuration > 1000 ? rawDuration / 1000 : rawDuration
        let stats = dictionary(track["stats"]) ?? [:]
        let fee = bool(stats["is_vip"] ?? stats["is_paid"] ?? stats["need_pay"] ?? track["is_vip"])
            ? 1
            : Int(number(track["fee"] ?? track["pay_flag"]))
        return Song(
            id: Self.stableID(identifier),
            name: firstString(track, keys: ["name", "trackName", "title"]) ?? "",
            artists: artistText.isEmpty ? (firstString(track, keys: ["artists_text", "artist", "singer"]) ?? "") : artistText,
            album: albumName,
            coverURL: cover,
            duration: duration,
            source: .qishui,
            qishuiID: identifier,
            fee: fee
        )
    }

    private func makePlaylist(_ raw: [String: Any]) -> Playlist? {
        let playlist = dictionary(raw["playlist"]) ?? raw
        guard let identifier = firstString(playlist, keys: ["id", "playlist_id"]), !identifier.isEmpty else { return nil }
        let cover = QishuiResourceURL.playlistCover(in: playlist)
        return Playlist(
            id: Self.stableID(identifier),
            name: firstString(playlist, keys: ["title", "name"]) ?? "未命名歌单",
            coverURL: cover,
            trackCount: Int(number(playlist["count_tracks"] ?? playlist["track_count"] ?? playlist["song_count"])),
            creatorName: firstString(playlist, keys: ["creator_name", "creatorName", "nickname"]) ?? "",
            playlistDescription: firstString(playlist, keys: ["description", "intro"]) ?? "",
            source: .qishui,
            qishuiID: identifier
        )
    }

    private func albums(from songs: [Song], limit: Int) -> [Album] {
        var grouped: [String: [Song]] = [:]
        for song in songs {
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = "\(normalizedAlbum(name))|\(normalizedArtist(song.artists))"
            grouped[key, default: []].append(song)
        }
        return grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let key = "\(first.album)|\(first.artists)"
            return Album(
                id: "qishui-album-\(Self.stableID(key))",
                name: first.album,
                artistName: first.artists,
                coverURL: first.coverURL,
                source: .qishui,
                trackCount: group.count
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .prefix(limit)
        .map { $0 }
    }

    private func trackDictionaries(_ value: Any?) -> [[String: Any]] {
        if let direct = value as? [[String: Any]] { return direct }
        if let object = value as? [String: Any] {
            if let direct = object["tracks"] as? [[String: Any]] { return direct }
            if let direct = object["media_resources"] as? [[String: Any]] { return direct }
            if let direct = object["data"] as? [[String: Any]] { return direct }
            return object.values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private func playlistDictionaries(_ value: Any?) -> [[String: Any]] {
        if let direct = value as? [[String: Any]] { return direct }
        if let object = value as? [String: Any] {
            if let direct = object["playlists"] as? [[String: Any]] { return direct }
            if let direct = object["data"] as? [[String: Any]] { return direct }
        }
        return []
    }

    private func dictionaryArray(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return []
    }

    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private func deduplicated(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private func splitArtists(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "/／,，、&＆+＋|｜;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizedArtist(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func normalizedAlbum(_ value: String) -> String {
        normalizedArtist(value)
    }

    private func number(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["1", "true", "yes", "on"].contains(value.lowercased()) }
        return false
    }

    private func firstString(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        return firstString(object, keys: keys)
    }

    private func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func firstURL(in object: [String: Any], keys: [String]) -> URL? {
        for key in keys {
            if let value = object[key] as? String, let url = URL(string: value), url.scheme != nil { return url }
            if let nested = object[key] as? [String: Any], let url = firstURL(in: nested, keys: keys) { return url }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let url = firstURL(in: nested, keys: keys) { return url }
            if let list = value as? [[String: Any]] {
                for item in list where item[keys.first ?? ""] != nil {
                    if let url = firstURL(in: item, keys: keys) { return url }
                }
            }
        }
        return nil
    }

    static func stableID(_ value: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let positive = hash & 0x7fff_ffff_ffff_ffff
        return max(1, Int(positive))
    }
}

// MARK: - 汽水官方直连（api.qishui.com）
//
// 字段映射依据：guohuiyuan/music-lib 的 soda 实现（sodaPCWebSearchURL /
// sodaPCAppParams / sodaPCPlaylistDetailURL / seo_track 歌词与 parseSodaLyric /
// passport 扫码登录）与 guowenye/qishui-api（search/album、discover/mix、
// /luna/comments、dailyMix、me/playlist、passport 固定参数）。
// 直连在本机机房出口实测回空内容（疑似字节对机房 IP 风控），居民网络预期
// 正常；实现与两个参考仓库逐项对齐，真实结果以真机为准。

struct QishuiQRCodeSession {
    let token: String
    let qrContent: String
    /// 服务端直接下发的二维码 PNG（data.qrcode 为 data:image/png;base64 时解码），
    /// 有值时优先展示图片，不要把 base64 长串当文本再生成二维码（必超容量返回 nil）。
    let qrImageData: Data?
    let cookieHeader: String
}

enum QishuiQRCodeStatus {
    case waiting
    case scanned
    case success(cookie: String)
    case expired
    case verifyRequired
    case failed(String)
}

extension QishuiAPI {
    private static var pcWebUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
    }

    private static var lunaPCUserAgent: String { "LunaPC/3.3.0(359450208)" }

    private static var passportUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) SodaMusic/3.1.0 Chrome/136.0.7103.59 Electron/36.4.0-rs.22.release.main.1 TTElectron/36.4.0-rs.22.release.main.1 Safari/537.36"
    }

    // MARK: 直连基础设施

    /// 首次直连前先暖一次官网，让 ttwid 等 Cookie 进直连会话的 Cookie 存储。
    private func warmUpDirectSessionIfNeeded() async {
        directStateLock.lock()
        if directWarmedUp {
            directStateLock.unlock()
            return
        }
        directWarmedUp = true
        directStateLock.unlock()
        guard let url = URL(string: "https://www.qishui.com/") else { return }
        var request = URLRequest(url: url)
        request.setValue(Self.pcWebUserAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await directSession.data(for: request)
    }

    /// PC 网页搜索公共参数（music-lib sodaPCWebSearchURL）。
    private func directWebSearchItems(keyword: String, cursor: Int, count: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "search_id", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "search_method", value: "input"),
            URLQueryItem(name: "debug_params", value: ""),
            URLQueryItem(name: "from_search_id", value: ""),
            URLQueryItem(name: "search_scene", value: ""),
            URLQueryItem(name: "aid", value: "386088"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "channel", value: "pc_web"),
        ]
    }

    /// PC 客户端公共参数（music-lib sodaPCAppParams，无凭据分支）。
    private func directAppItems(extra: [URLQueryItem]) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "aid", value: "386088"),
            URLQueryItem(name: "app_name", value: "luna_pc"),
            URLQueryItem(name: "region", value: "cn"),
            URLQueryItem(name: "geo_region", value: "cn"),
            URLQueryItem(name: "os_region", value: "cn"),
            URLQueryItem(name: "sim_region", value: ""),
            URLQueryItem(name: "device_id", value: directDeviceID),
            URLQueryItem(name: "iid", value: directInstallID),
            URLQueryItem(name: "cdid", value: ""),
            URLQueryItem(name: "version_name", value: "3.3.0"),
            URLQueryItem(name: "version_code", value: "30030000"),
            URLQueryItem(name: "channel", value: "official"),
            URLQueryItem(name: "build_mode", value: "master"),
            URLQueryItem(name: "network_carrier", value: ""),
            URLQueryItem(name: "ac", value: "wifi"),
            URLQueryItem(name: "tz_name", value: "Asia/Shanghai"),
            URLQueryItem(name: "resolution", value: ""),
            URLQueryItem(name: "device_platform", value: "windows"),
            URLQueryItem(name: "device_type", value: "Windows"),
            URLQueryItem(name: "os_version", value: "Windows 11"),
            URLQueryItem(name: "fp", value: directDeviceID),
        ]
        items.append(contentsOf: extra)
        return items
    }

    /// 直连请求：返回完整响应根对象（不像网关那样只取 data），status_code 非 0 视为失败。
    private func directRequestObject(
        path: String,
        queryItems: [URLQueryItem],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        lunaPCHeaders: Bool = false,
        includeAuthCookie: Bool = false,
        allowNonZeroStatus: Bool = false
    ) async throws -> [String: Any] {
        await warmUpDirectSessionIfNeeded()
        guard var components = URLComponents(string: "https://api.qishui.com/" + path) else {
            throw QishuiAPIError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw QishuiAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if lunaPCHeaders {
            request.setValue(Self.lunaPCUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("foreground", forHTTPHeaderField: "x-luna-background-type")
            request.setValue("0", forHTTPHeaderField: "x-luna-is-background-req")
            request.setValue("1", forHTTPHeaderField: "x-luna-is-local-user")
        } else {
            request.setValue(Self.pcWebUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.qishui.com/", forHTTPHeaderField: "Referer")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        if includeAuthCookie {
            let cookie = QishuiMusicAuth.shared.cookieHeader
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        let (data, response) = try await directSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw QishuiAPIError.server("汽水音乐直连请求失败")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QishuiAPIError.invalidResponse
        }
        if !allowNonZeroStatus, let code = root["status_code"] as? NSNumber, code.intValue != 0 {
            throw QishuiAPIError.server("汽水音乐直连返回失败")
        }
        return root
    }

    // MARK: 直连字段归一化

    /// PC 搜索响应 result_groups[].data[].entity[key] 提取。
    private func pcResultEntities(_ root: [String: Any], key: String) -> [[String: Any]] {
        guard let groups = root["result_groups"] as? [[String: Any]] else { return [] }
        var entities: [[String: Any]] = []
        for group in groups {
            for item in dictionaryArray(group["data"]) {
                if let entity = dictionary(item["entity"]), let value = dictionary(entity[key]) {
                    entities.append([key: value])
                }
            }
        }
        return entities
    }

    /// PC track 的 label_info VIP 标记对齐网关格式的 fee 字段，makeSong 据此打标。
    private func normalizedPCTrack(_ track: [String: Any]) -> [String: Any] {
        var result = track
        if dictionaryArray(track["artists"]).isEmpty, let artist = dictionary(track["artist"]) {
            result["artists"] = [artist]
        }
        if let label = dictionary(track["label_info"]) {
            let vip = bool(label["only_vip_playable"]) || bool(label["only_vip_download"])
                || bool(label["quality_only_vip_playable"]) || bool(label["quality_only_vip_download"])
            if vip, track["fee"] == nil { result["fee"] = 1 }
        }
        return result
    }

    private func normalizedPCEntity(_ entity: [String: Any]) -> [String: Any] {
        var result = entity
        if var wrapper = dictionary(entity["track_wrapper"]), let track = dictionary(wrapper["track"]) {
            wrapper["track"] = normalizedPCTrack(track)
            result["track_wrapper"] = wrapper
        } else if let track = dictionary(entity["track"]) {
            result["track"] = normalizedPCTrack(track)
        } else if entity["duration"] != nil {
            result = normalizedPCTrack(entity)
        }
        return result
    }

    /// PC 歌单项的创建者与曲目数藏在 owner / resource_cnt 里，注入成 makePlaylist 认的字段。
    private func normalizedPCPlaylist(_ playlist: [String: Any]) -> [String: Any] {
        var result = playlist
        if firstString(playlist, keys: ["creator_name", "creatorName", "nickname"]) == nil,
           let owner = dictionary(playlist["owner"]),
           let name = firstString(owner, keys: ["nickname", "public_name", "name"]) {
            result["creator_name"] = name
        }
        if playlist["count_tracks"] == nil, let resource = dictionary(playlist["resource_cnt"]) {
            result["count_tracks"] = Int(number(resource["track_cnt"]))
        }
        return result
    }

    // MARK: 直连搜索

    private func directSearchSongs(
        keyword: String,
        targetCount: Int,
        onPartialResults: (@MainActor ([Song]) -> Void)?
    ) async throws -> [Song] {
        let pageSize = 20
        var songs: [Song] = []
        var seen = Set<String>()
        var cursor = 0
        for _ in 0..<12 where songs.count < targetCount {
            guard !Task.isCancelled else { throw CancellationError() }
            let root = try await directRequestObject(
                path: "luna/pc/search/track",
                queryItems: directWebSearchItems(keyword: keyword, cursor: cursor, count: pageSize)
            )
            let entities = pcResultEntities(root, key: "track")
            guard !entities.isEmpty else { break }
            var added = 0
            for entity in entities {
                guard let song = makeSong(normalizedPCEntity(entity)),
                      seen.insert(song.identityKey).inserted else { continue }
                songs.append(song)
                added += 1
                if songs.count >= targetCount { break }
            }
            if added > 0, let onPartialResults {
                await onPartialResults(Array(songs.prefix(targetCount)))
            }
            cursor += entities.count
            if entities.count < pageSize { break }
        }
        return Array(songs.prefix(targetCount))
    }

    /// 安卓端搜索公共参数（music-lib sodaAndroidSearchParams，含其内置的
    /// 设备标识；aid 在拼 URL 时覆盖为 386088，与原实现一致）。
    private func directAndroidSearchItems(keyword: String, cursor: Int, count: Int) -> [URLQueryItem] {
        let values: [(String, String)] = [
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("cdid", "46556f98-1720-4248-83da-62b74b60b46a"),
            ("channel", "xiaomi_8478_64"),
            ("app_name", "luna"),
            ("version_code", "100198030"),
            ("version_name", "19.8.0"),
            ("manifest_version_code", "100198030"),
            ("update_version_code", "100198030"),
            ("resolution", "1080*1920"),
            ("dpi", "480"),
            ("device_type", "ABR-AL80"),
            ("device_brand", "HUAWEI"),
            ("language", "zh"),
            ("os_api", "35"),
            ("os_version", "15"),
            ("ac", "wifi"),
            ("device_model", "ABR-AL80"),
            ("save_power", "0"),
            ("font_size", "1.00"),
            ("luna_first_launch_apk_type", "normal_apk"),
            ("diversion_channel_name", "xiaomi_8478_64"),
            ("is_car_play", "0"),
            ("battery", "0.99"),
            ("network_speed", "10156"),
            ("hybrid_version_code", "100198030"),
            ("tz_name", "Asia/Shanghai"),
            ("tz_offset", "28800"),
            ("luna_register_time", "1784311292"),
            ("diversion_category_level_two", "Xiaomi商店-自然"),
            ("package", "com.luna.music"),
            ("charge", "0"),
            ("luna_apk_type", "normal_apk"),
            ("output_device_type", "Phone"),
            ("volume", "1.00"),
            ("brightness", "0.08"),
            ("need_personal_recommend", "1"),
            ("is_teen_mode", "0"),
            ("sim_region", "cn"),
            ("diversion_category_level_one", "厂商商店-自然"),
            ("android_device_type", "default"),
            ("iid", "2204957404569386"),
            ("device_id", "2204957404565290"),
            ("_rticket", String(Int64(Date().timeIntervalSince1970 * 1000))),
            ("q", keyword),
            ("cursor", String(cursor)),
            ("count", String(count)),
            ("aid", "386088"),
        ]
        return values.map { URLQueryItem(name: $0.0, value: $0.1) }
    }

    /// 安卓端单曲搜索 /luna/search/track：响应结构与 PC 网页端一致
    /// （result_groups[].data[].entity.track，music-lib 同一套解析）。
    private func directAndroidSearchSongs(
        keyword: String,
        targetCount: Int,
        onPartialResults: (@MainActor ([Song]) -> Void)?
    ) async throws -> [Song] {
        let pageSize = 20
        var songs: [Song] = []
        var seen = Set<String>()
        var cursor = 0
        for _ in 0..<12 where songs.count < targetCount {
            guard !Task.isCancelled else { throw CancellationError() }
            guard var components = URLComponents(string: "https://api.qishui.com/luna/search/track") else {
                throw QishuiAPIError.invalidURL
            }
            components.queryItems = directAndroidSearchItems(keyword: keyword, cursor: cursor, count: pageSize)
            guard let url = components.url else { throw QishuiAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            let cookie = QishuiMusicAuth.shared.cookieHeader
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            let (data, response) = try await directSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw QishuiAPIError.server("汽水音乐安卓端搜索失败")
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QishuiAPIError.invalidResponse
            }
            if let code = root["status_code"] as? NSNumber, code.intValue != 0 {
                throw QishuiAPIError.server("汽水音乐安卓端搜索失败")
            }
            let entities = pcResultEntities(root, key: "track")
            guard !entities.isEmpty else { break }
            var added = 0
            for entity in entities {
                guard let song = makeSong(normalizedPCEntity(entity)),
                      seen.insert(song.identityKey).inserted else { continue }
                songs.append(song)
                added += 1
                if songs.count >= targetCount { break }
            }
            if added > 0, let onPartialResults {
                await onPartialResults(Array(songs.prefix(targetCount)))
            }
            cursor += entities.count
            if entities.count < pageSize { break }
        }
        return Array(songs.prefix(targetCount))
    }

    private func directSearchPlaylists(keyword: String, limit: Int) async throws -> [Playlist] {
        let pageSize = 20
        var playlists: [Playlist] = []
        var seen = Set<Int>()
        var cursor = 0
        for _ in 0..<6 where playlists.count < limit {
            guard !Task.isCancelled else { throw CancellationError() }
            let root = try await directRequestObject(
                path: "luna/pc/search/playlist",
                queryItems: directWebSearchItems(keyword: keyword, cursor: cursor, count: pageSize)
            )
            let entities = pcResultEntities(root, key: "playlist")
            guard !entities.isEmpty else { break }
            for entity in entities {
                guard let raw = dictionary(entity["playlist"]),
                      let playlist = makePlaylist(normalizedPCPlaylist(raw)),
                      seen.insert(playlist.id).inserted else { continue }
                playlists.append(playlist)
                if playlists.count >= limit { break }
            }
            cursor += entities.count
            if entities.count < pageSize { break }
        }
        return Array(playlists.prefix(limit))
    }

    private func directSearchAlbums(keyword: String, limit: Int) async throws -> [Album] {
        let root = try await directRequestObject(
            path: "luna/pc/search/album",
            queryItems: directWebSearchItems(keyword: keyword, cursor: 0, count: max(limit, 20))
        )
        var albums: [Album] = []
        var seen = Set<String>()
        for entity in pcResultEntities(root, key: "album") {
            guard let raw = dictionary(entity["album"]),
                  let identifier = firstString(raw, keys: ["id"]),
                  !identifier.isEmpty,
                  seen.insert(identifier).inserted,
                  let name = firstString(raw, keys: ["name"]), !name.isEmpty else { continue }
            let artistText = dictionaryArray(raw["artists"])
                .compactMap { firstString($0, keys: ["name", "simple_display_name"]) }
                .joined(separator: " / ")
            var releaseDate: String?
            let timestamp = number(raw["release_date"])
            if timestamp > 0 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                releaseDate = formatter.string(from: Date(timeIntervalSince1970: timestamp))
            }
            albums.append(Album(
                id: "qishui-album-\(Self.stableID(identifier))",
                name: name,
                artistName: artistText,
                coverURL: QishuiResourceURL.first(in: raw["url_cover"]),
                source: .qishui,
                trackCount: Int(number(raw["count_tracks"])),
                releaseDate: releaseDate
            ))
            if albums.count >= limit { break }
        }
        return albums
    }

    // MARK: 直连歌单

    private func directPlaylistDetails(
        id: String,
        targetCount: Int,
        onPartialSongs: (@MainActor ([Song]) -> Void)?
    ) async throws -> QishuiPlaylistDetails {
        let pageSize = 100
        var playlist: Playlist?
        var songs: [Song] = []
        var seen = Set<String>()
        var seenCursors = Set<String>()
        var cursor = "0"
        for _ in 0..<20 where songs.count < targetCount {
            guard !Task.isCancelled else { throw CancellationError() }
            let root = try await directRequestObject(
                path: "luna/pc/playlist/detail",
                queryItems: directAppItems(extra: [
                    URLQueryItem(name: "playlist_id", value: id),
                    URLQueryItem(name: "cursor", value: cursor),
                    URLQueryItem(name: "count", value: String(pageSize)),
                ]),
                lunaPCHeaders: true,
                includeAuthCookie: true
            )
            if playlist == nil, let rawPlaylist = dictionary(root["playlist"]) {
                playlist = makePlaylist(normalizedPCPlaylist(rawPlaylist))
            }
            let resources = dictionaryArray(root["media_resources"])
            guard !resources.isEmpty else { break }
            var added = 0
            for resource in resources {
                let entity = dictionary(resource["entity"]) ?? resource
                guard let song = makeSong(normalizedPCEntity(entity)),
                      seen.insert(song.identityKey).inserted else { continue }
                songs.append(song)
                added += 1
                if songs.count >= targetCount { break }
            }
            if added > 0, let onPartialSongs {
                await onPartialSongs(Array(songs.prefix(targetCount)))
            }
            let nextCursor = firstString(root, keys: ["next_cursor"]) ?? ""
            let hasMore = bool(root["has_more"])
            guard !nextCursor.isEmpty, seenCursors.insert(nextCursor).inserted else { break }
            cursor = nextCursor
            if !hasMore, added < pageSize { break }
        }
        return QishuiPlaylistDetails(playlist: playlist, songs: Array(songs.prefix(targetCount)))
    }

    private func directRecommendedPlaylists(limit: Int) async throws -> [Playlist] {
        let root = try await directRequestObject(
            path: "luna/pc/discover/mix",
            queryItems: directAppItems(extra: []),
            method: "POST",
            jsonBody: [
                "block_type": "discover_playlist_mix",
                "feed_discover_extra": [String: Any](),
                "latest_douyin_liked_playlist_show_ts": 0,
                "sub_channel_id": 0,
            ],
            lunaPCHeaders: true,
            includeAuthCookie: true
        )
        var playlists: [Playlist] = []
        var seen = Set<Int>()
        for block in dictionaryArray(root["inner_block"]) {
            for resource in dictionaryArray(block["resources"]) {
                guard let entity = dictionary(resource["entity"]),
                      let raw = dictionary(entity["playlist"]),
                      let playlist = makePlaylist(normalizedPCPlaylist(raw)),
                      seen.insert(playlist.id).inserted else { continue }
                playlists.append(playlist)
                if playlists.count >= limit { return playlists }
            }
        }
        return playlists
    }

    // MARK: 直连歌词

    private func directLyric(trackID: String) async throws -> String? {
        // 1) PC track_v2 详情自带歌词（qishui-api trackDetail）。music-lib 注明
        //    该端点已下线，失败会直接落到下面的 seo_track，不影响结果。
        if let root = try? await directRequestObject(
            path: "luna/pc/track_v2",
            queryItems: directAppItems(extra: [
                URLQueryItem(name: "track_id", value: trackID),
                URLQueryItem(name: "media_type", value: "track"),
                URLQueryItem(name: "queue_type", value: ""),
            ]),
            lunaPCHeaders: true,
            includeAuthCookie: true
        ), let text = lyricText(in: root) {
            return text
        }
        // 2) H5 seo_track（music-lib 现行歌词路线，无需签名）：lyric.content。
        let root = try await directRequestObject(
            path: "luna/h5/seo_track",
            queryItems: [
                URLQueryItem(name: "track_id", value: trackID),
                URLQueryItem(name: "device_platform", value: "web"),
            ]
        )
        return lyricText(in: root)
    }

    private func lyricText(in root: [String: Any]) -> String? {
        var lyricObjects: [[String: Any]] = []
        if let lyric = dictionary(root["lyric"]) { lyricObjects.append(lyric) }
        if let seo = dictionary(root["seo_track"]), let lyric = dictionary(seo["lyric"]) {
            lyricObjects.append(lyric)
        }
        if let player = dictionary(root["track_player"]), let lyric = dictionary(player["lyric"]) {
            lyricObjects.append(lyric)
        }
        for object in lyricObjects {
            if let text = firstString(object, keys: ["content", "lyric", "text"]), !text.isEmpty {
                return Self.convertQishuiLyric(text)
            }
        }
        return nil
    }

    /// 汽水歌词是逐字格式：[开始毫秒,时长毫秒]歌词<逐字标签>，转成现有歌词
    /// 管线能吃的标准 LRC（与 music-lib parseSodaLyric 同规则）；已是标准
    /// LRC 的行原样保留。
    static func convertQishuiLyric(_ raw: String) -> String {
        var output: [String] = []
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let header = String(line[line.index(after: line.startIndex)..<close])
            let content = String(line[line.index(after: close)...])
            let parts = header.split(separator: ",")
            if parts.count >= 2, let startMs = Int(parts[0]) {
                let clean = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let minutes = startMs / 60000
                let seconds = (startMs % 60000) / 1000
                let centis = (startMs % 1000) / 10
                output.append(String(format: "[%02d:%02d.%02d]", minutes, seconds, centis) + clean)
            } else if header.contains(":") {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: 直连评论

    private func directComments(trackID: String, limit: Int) async throws -> NetEaseAPI.SongCommentPage {
        let root = try await directRequestObject(
            path: "luna/comments",
            queryItems: [
                URLQueryItem(name: "group_id", value: trackID),
                URLQueryItem(name: "cursor", value: ""),
                URLQueryItem(name: "count", value: String(min(max(limit, 1), 50))),
                URLQueryItem(name: "group_type", value: "track"),
                URLQueryItem(name: "image_strategy", value: "tplv-luna-shrink:200:200"),
                URLQueryItem(name: "sort_type", value: "hot"),
                URLQueryItem(name: "aid", value: "386088"),
                URLQueryItem(name: "device_platform", value: "web"),
            ],
            includeAuthCookie: true
        )
        let rawComments = dictionaryArray(root["comments"] ?? root["data"] ?? root["comment_list"])
        guard !rawComments.isEmpty else { throw QishuiAPIError.invalidResponse }
        let comments = rawComments.compactMap { raw -> SongComment? in
            let user = dictionary(raw["user"]) ?? dictionary(raw["user_info"]) ?? [:]
            let content = firstString(raw, keys: ["content", "text", "comment_text"]) ?? ""
            guard !content.isEmpty else { return nil }
            let idText = firstString(raw, keys: ["id", "comment_id", "commentId"]) ?? UUID().uuidString
            let nickname = firstString(user, keys: ["nickname", "name", "user_name"])
                ?? firstString(raw, keys: ["user_name", "nickname"]) ?? "汽水用户"
            let avatar = QishuiResourceURL.first(in: user["avatar_url"] ?? user["avatar_thumb"] ?? user["avatar"])
                ?? firstString(raw, keys: ["user_avatar", "avatar_url"]).flatMap(URL.init(string:))
            let timestamp = number(raw["create_time"] ?? raw["timestamp"] ?? raw["time"])
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
            return SongComment(
                id: Self.stableID(idText),
                content: content,
                nickname: nickname,
                avatarURL: avatar,
                time: Date(timeIntervalSince1970: seconds > 0 ? seconds : Date().timeIntervalSince1970),
                likedCount: Int(number(raw["digg_count"] ?? raw["like_count"] ?? raw["likeCount"])),
                isHot: false
            )
        }
        let total = Int(number(root["total"] ?? root["total_count"]))
        return NetEaseAPI.SongCommentPage(
            total: total > 0 ? total : comments.count,
            hot: [],
            comments: comments
        )
    }

    // MARK: 每日推荐

    /// 汽水每日推荐：POST /luna/feed/song-tab（qishui-api dailyMix）。
    /// 该端点可能要求 App 上下文（status_code 1000006）；匿名先直连，
    /// 登录后自动带 Cookie。取不到就返回空，首页保持原来的无推荐状态。
    func dailySongs(limit: Int = 30) async -> [Song] {
        guard let root = try? await directRequestObject(
            path: "luna/feed/song-tab",
            queryItems: directAppItems(extra: []),
            method: "POST",
            jsonBody: [:],
            lunaPCHeaders: true,
            includeAuthCookie: true,
            allowNonZeroStatus: true
        ) else { return [] }
        if let code = root["status_code"] as? NSNumber, code.intValue == 1000006 {
            return []
        }
        var songs: [Song] = []
        var seen = Set<String>()
        collectDirectTracks(in: root, into: &songs, seen: &seen, limit: limit)
        return songs
    }

    /// feed 响应结构不固定，递归找 entity / track_wrapper / 裸 track 并映射。
    private func collectDirectTracks(in object: Any, into songs: inout [Song], seen: inout Set<String>, limit: Int) {
        guard songs.count < limit else { return }
        if let dict = object as? [String: Any] {
            if let entity = dictionary(dict["entity"]),
               let song = makeSong(normalizedPCEntity(entity)),
               seen.insert(song.identityKey).inserted {
                songs.append(song)
            }
            if dict["track_wrapper"] != nil || dict["track"] != nil
                || (dict["id"] != nil && dict["name"] != nil && dict["duration"] != nil) {
                if let song = makeSong(normalizedPCEntity(dict)),
                   seen.insert(song.identityKey).inserted {
                    songs.append(song)
                }
            }
            for value in dict.values {
                collectDirectTracks(in: value, into: &songs, seen: &seen, limit: limit)
                if songs.count >= limit { return }
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectDirectTracks(in: value, into: &songs, seen: &seen, limit: limit)
                if songs.count >= limit { return }
            }
        }
    }

    // MARK: 登录态（我的歌单 / 个人信息）

    /// 我的汽水歌单：GET /luna/pc/me/playlist（qishui-api mePlaylists，需登录
    /// Cookie）；拿不到再走 /luna/pc/me 取 user_id 后 /luna/pc/user/playlist
    /// 分页（music-lib 路线）。未登录直接返回空。
    func userPlaylists() async -> [Playlist] {
        guard QishuiMusicAuth.shared.isLoggedIn else { return [] }
        var playlists: [Playlist] = []
        var seen = Set<Int>()
        func appendItems(_ items: [[String: Any]]) {
            for item in items {
                guard let playlist = makePlaylist(normalizedPCPlaylist(item)),
                      seen.insert(playlist.id).inserted else { continue }
                playlists.append(playlist)
            }
        }
        if let root = try? await directRequestObject(
            path: "luna/pc/me/playlist",
            queryItems: [
                URLQueryItem(name: "aid", value: "386088"),
                URLQueryItem(name: "iid", value: QishuiMusicAuth.shared.passportInstallID),
                URLQueryItem(name: "version_code", value: "30020100"),
            ],
            lunaPCHeaders: true,
            includeAuthCookie: true
        ) {
            appendItems(dictionaryArray(root["playlists"] ?? root["data"]))
        }
        if playlists.isEmpty,
           let me = try? await directRequestObject(
               path: "luna/pc/me",
               queryItems: [URLQueryItem(name: "aid", value: "386088")],
               lunaPCHeaders: true,
               includeAuthCookie: true
           ),
           let info = dictionary(me["my_info"]),
           let userID = firstString(info, keys: ["id"]) {
            var cursor: String?
            for _ in 0..<10 {
                var items = directAppItems(extra: [
                    URLQueryItem(name: "user_id", value: userID),
                    URLQueryItem(name: "count", value: "50"),
                ])
                if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
                guard let page = try? await directRequestObject(
                    path: "luna/pc/user/playlist",
                    queryItems: items,
                    lunaPCHeaders: true,
                    includeAuthCookie: true
                ) else { break }
                appendItems(dictionaryArray(page["playlists"] ?? page["data"]))
                let next = firstString(page, keys: ["next_cursor"])
                guard bool(page["has_more"]), let next, !next.isEmpty else { break }
                cursor = next
            }
        }
        return playlists
    }

    /// 登录后刷新昵称 / 头像 / user_id 存进 QishuiMusicAuth。
    func refreshProfile() async {
        guard QishuiMusicAuth.shared.isLoggedIn else { return }
        guard let root = try? await directRequestObject(
            path: "luna/pc/me",
            queryItems: [URLQueryItem(name: "aid", value: "386088")],
            lunaPCHeaders: true,
            includeAuthCookie: true
        ), let info = dictionary(root["my_info"]) else { return }
        QishuiMusicAuth.shared.updateProfile(
            userID: firstString(info, keys: ["id"]) ?? "",
            nickname: firstString(info, keys: ["nickname", "name"]) ?? "",
            avatar: QishuiResourceURL.first(in: info["larger_avatar_url"] ?? info["avatar_url"])?.absoluteString ?? ""
        )
    }

    // MARK: 扫码登录（passport）

    /// passport biz_trace_id：进程内生成一次后保持不变（music-lib
    /// sodaPassportBizTraceID，8 位十六进制），同时用作请求头
    /// X-Tt-Passport-Trace-Id。
    private static let passportBizTraceIDStorage: String = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    private var passportBizTraceID: String { Self.passportBizTraceIDStorage }

    /// passport 公共参数：逐项对齐 music-lib buildSodaPassportNormalValues
    /// （base values + account_sdk_source/p_js_*/p_zt/p_ver/request_host/p_bd）。
    /// 早期版本只带了 qishui-api 的最小参数集，真机表现是能出码、能扫、
    /// 能确认，但服务端始终不下发会话 Cookie；参数面补齐到官方网页端
    /// SDK 的完整形态后再验。
    private func passportQueryItems(extra: [URLQueryItem] = []) -> [URLQueryItem] {
        let deviceID = QishuiMusicAuth.shared.passportDeviceID
        let installID = QishuiMusicAuth.shared.passportInstallID
        var items = [
            URLQueryItem(name: "passport_jssdk_version", value: "2.4.13"),
            URLQueryItem(name: "passport_jssdk_type", value: "normal"),
            URLQueryItem(name: "is_from_ttaccountsdk", value: "1"),
            URLQueryItem(name: "aid", value: "386088"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "account_sdk_source", value: "web"),
            URLQueryItem(name: "p_js_v", value: "2.4.13"),
            URLQueryItem(name: "p_js_t", value: "pro"),
            URLQueryItem(name: "p_zt", value: "3.3.5"),
            URLQueryItem(name: "p_ver", value: "1.0.29"),
            URLQueryItem(name: "request_host", value: "app://resources"),
            URLQueryItem(name: "p_bd", value: "1.0.0.41"),
            URLQueryItem(name: "biz_trace_id", value: passportBizTraceID),
            URLQueryItem(name: "is_new_login", value: "1"),
            URLQueryItem(name: "is_from_iesaccountsaas", value: "1"),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "install_id", value: installID),
            URLQueryItem(name: "did", value: deviceID),
            URLQueryItem(name: "iid", value: installID),
            URLQueryItem(name: "device_platform", value: "PC"),
            URLQueryItem(name: "version_code", value: "3.3.0"),
        ]
        items.append(contentsOf: extra)
        return items
    }

    /// passport POST 要求携带的请求头（music-lib postSodaPassportWithCookie：
    /// sec-ch-ua 三件套 + bd-ticket-guard 四件套 + trace id）。
    private func applyPassportHeaders(to request: inout URLRequest) {
        request.setValue(Self.passportUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("\"Not.A/Brand\";v=\"99\", \"Chromium\";v=\"136\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"Windows\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("2", forHTTPHeaderField: "bd-ticket-guard-version")
        request.setValue("2", forHTTPHeaderField: "bd-ticket-guard-iteration-version")
        request.setValue("BAnIxKL96Jby5x+Um9i7HZ2c8O6lfZJRxm6yk73Mqcr06l2qIw2iqu2Mtm3U/6OI98usukA9dqxUlsctVWK9rKA=", forHTTPHeaderField: "bd-ticket-guard-ree-public-key")
        request.setValue("0", forHTTPHeaderField: "bd-ticket-guard-server-cert-sn")
        request.setValue(passportBizTraceID, forHTTPHeaderField: "X-Tt-Passport-Trace-Id")
    }

    /// GET /passport/web/get_qrcode/：拿 token 与二维码内容（data.qrcode，
    /// 兜底 qrcode_index_url / web_url），并保存响应下发的 Cookie 供轮询使用。
    func createQRCode() async throws -> QishuiQRCodeSession {
        await warmUpDirectSessionIfNeeded()
        guard var components = URLComponents(string: "https://api.qishui.com/passport/web/get_qrcode/") else {
            throw QishuiAPIError.invalidURL
        }
        components.queryItems = passportQueryItems(extra: [
            URLQueryItem(name: "next", value: "https://api.qishui.com"),
            URLQueryItem(name: "need_logo", value: "false"),
            URLQueryItem(name: "need_short_url", value: "false"),
            URLQueryItem(name: "is_frontier", value: "true"),
        ])
        guard let url = components.url else { throw QishuiAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(Self.passportUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        let (data, response) = try await directSession.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QishuiAPIError.invalidResponse
        }
        let payload = dictionary(root["data"]) ?? root
        guard let token = firstString(payload, keys: ["token"]), !token.isEmpty else {
            throw QishuiAPIError.invalidResponse
        }
        // 实测（2026-11-23）：data.qrcode 是服务端画好的二维码 PNG，
        // 形如 data:image/png;base64,...（约 18 KB），不是待编码的文本；
        // 把它当文本喂 CIQRCodeGenerator 会超容量返回 nil，界面只剩空白框。
        var qrImageData: Data? = nil
        var qrContent = ""
        let rawQR = firstString(payload, keys: ["qrcode"]) ?? ""
        if rawQR.hasPrefix("data:image"), let comma = rawQR.firstIndex(of: ",") {
            let base64 = String(rawQR[rawQR.index(after: comma)...])
            qrImageData = Data(base64Encoded: base64)
        } else if !rawQR.isEmpty {
            qrContent = rawQR
        }
        if qrImageData == nil, qrContent.isEmpty {
            qrContent = firstString(payload, keys: ["qrcode_index_url", "web_url"]) ?? ""
        }
        guard qrImageData != nil || !qrContent.isEmpty else { throw QishuiAPIError.invalidResponse }
        let initialCookies = Self.responseCookieHeader(response, for: url)
        updateQRCookeJar(for: token, header: initialCookies.isEmpty ? nil : initialCookies)
        return QishuiQRCodeSession(
            token: token,
            qrContent: qrContent,
            qrImageData: qrImageData,
            cookieHeader: initialCookies
        )
    }

    /// POST /passport/web/check_qrconnect/ 轮询。状态语义对齐 music-lib：
    /// new = 等待扫码，scanned / confirmed = 已扫码（confirmed 后继续轮询等
    /// 会话 Cookie 下发），expired = 过期，error_code 7 = 限频（继续轮询），
    /// error_code 2046 / account_flow=verify = 需要短信验证（本版不支持）。
    /// 成功判据：合并 Cookie 里出现 sessionid。
    func checkQRCode(session: QishuiQRCodeSession) async throws -> QishuiQRCodeStatus {
        guard var components = URLComponents(string: "https://api.qishui.com/passport/web/check_qrconnect/") else {
            throw QishuiAPIError.invalidURL
        }
        components.queryItems = passportQueryItems()
        guard let url = components.url else { throw QishuiAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyPassportHeaders(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let jarCookie = qrCookieJar(for: session.token) ?? session.cookieHeader
        if !jarCookie.isEmpty {
            request.setValue(jarCookie, forHTTPHeaderField: "Cookie")
        }
        // 表单字段顺序对齐 music-lib sodaEncodePassportForm 的 check 顺序。
        request.httpBody = Self.formEncoded([
            ("need_logo", "false"),
            ("need_short_url", "false"),
            ("is_frontier", "true"),
            ("token", session.token),
            ("is_new_login", "1"),
            ("next", "https://api.qishui.com"),
        ])
        let (data, response) = try await directSession.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .waiting
        }
        let payload = dictionary(root["data"]) ?? root
        let stored = (HTTPCookieStorage.shared.cookies(for: url) ?? [])
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        var merged = Self.mergedCookieHeader([
            jarCookie,
            Self.responseCookieHeader(response, for: url),
            stored,
        ])
        // 确认后服务端常只回 redirect_url：真正的会话 Cookie 要访问那个
        // 地址才下发（music-lib 把 redirect_url 透出给上层正是为此）。
        // 不跟这一步，轮询永远停在 confirmed，登录态永远落不了地。
        let redirectRaw = firstString(payload, keys: ["redirect_url"]) ?? firstString(root, keys: ["redirect_url"])
        if let redirectRaw, let redirectURL = URL(string: redirectRaw) {
            var redirectRequest = URLRequest(url: redirectURL)
            redirectRequest.setValue(Self.passportUserAgent, forHTTPHeaderField: "User-Agent")
            if !merged.isEmpty {
                redirectRequest.setValue(merged, forHTTPHeaderField: "Cookie")
            }
            if let (_, redirectResponse) = try? await directSession.data(for: redirectRequest) {
                let redirectStored = (HTTPCookieStorage.shared.cookies(for: redirectURL) ?? [])
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                merged = Self.mergedCookieHeader([
                    merged,
                    Self.responseCookieHeader(redirectResponse, for: redirectURL),
                    redirectStored,
                ])
            }
        }
        updateQRCookeJar(for: session.token, header: merged.isEmpty ? nil : merged)
        if Self.hasSessionCookie(merged) {
            updateQRCookeJar(for: session.token, header: nil)
            return .success(cookie: merged)
        }
        let status = (firstString(payload, keys: ["status"]) ?? "").lowercased()
        let errorCode = Int(number(payload["error_code"]))
        let accountFlow = (firstString(payload, keys: ["account_flow"]) ?? "").lowercased()
        if accountFlow == "verify" || errorCode == 2046 {
            return .verifyRequired
        }
        if errorCode == 7 {
            return .waiting
        }
        switch status {
        case "scanned", "confirmed":
            return .scanned
        case "expired":
            return .expired
        case "error", "failed":
            return .failed(firstString(payload, keys: ["description"]) ?? firstString(root, keys: ["message"]) ?? "登录失败")
        default:
            if errorCode != 0 {
                return .failed(firstString(payload, keys: ["description"]) ?? firstString(root, keys: ["message"]) ?? "登录失败")
            }
            return .waiting
        }
    }

    /// 字节系会话 Cookie 名（music-lib sodaCookiesHaveSession 的判据集合）：
    /// 任一存在且非空即视为已登录，不只认 sessionid / sessionid_ss。
    private static let sessionCookieNames: Set<String> = ["sessionid", "sessionid_ss", "sid_tt", "sid_guard"]

    private static func hasSessionCookie(_ header: String) -> Bool {
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if sessionCookieNames.contains(name), !value.isEmpty { return true }
        }
        return false
    }

    private func qrCookieJar(for token: String) -> String? {
        directStateLock.lock()
        defer { directStateLock.unlock() }
        return qrCookieJars[token]
    }

    private func updateQRCookeJar(for token: String, header: String?) {
        directStateLock.lock()
        defer { directStateLock.unlock() }
        qrCookieJars[token] = header
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func escape(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return pairs.map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func responseCookieHeader(_ response: URLResponse?, for url: URL) -> String {
        guard let http = response as? HTTPURLResponse,
              let fields = http.allHeaderFields as? [String: String] else { return "" }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func mergedCookieHeader(_ headers: [String]) -> String {
        var pairs: [(String, String)] = []
        var indexByName: [String: Int] = [:]
        for header in headers {
            for part in header.split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces)
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let name = String(pair[..<eq])
                let value = String(pair[pair.index(after: eq)...])
                if let index = indexByName[name] {
                    pairs[index] = (name, value)
                } else {
                    indexByName[name] = pairs.count
                    pairs.append((name, value))
                }
            }
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
}
