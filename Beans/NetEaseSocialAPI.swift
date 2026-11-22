//
//  NetEaseSocialAPI.swift
//  Beans
//
//  网易云私信 / 收藏专辑 / 关注歌手 / 音乐云盘接口层，移植自 MeloX
//  （https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Core/Networking/NeteaseSocialAPI.swift、
//          NeteaseAPI+AlbumSubscriptions.swift、NeteaseAPI+ArtistSubscriptions.swift、
//          NeteaseAPI.swift（cloudSongs / deleteCloudSong / uploadCloudSong）、
//          Core/Cloud/CloudMusicModels.swift、CloudUploadFile.swift、
//          Core/Models/Social/PrivateMessageModels.swift、SocialShareModels.swift。
//  改动：MeloX 的 Codable 客户端（client.weapi / client.eapi）改为 Beans 的
//  字典式请求层 NetEaseAPI.request；模型按 Beans 习惯以 [String: Any] 解析，
//  歌曲/歌单/专辑复用 Beans 的 Song / Playlist / Album。
//  简化：MeloX 在 weapi 返回空体时降级 eapi；Beans 请求层不区分空体错误，
//  这里仅在 JSON 解析失败（NetEaseError.decoding）时降级 eapi，其余错误直接抛出。
//

import AVFoundation
import CryptoKit
import Foundation

// MARK: - 模型（私信）

struct NetEaseMessageContact: Identifiable, Hashable {
    let id: Int
    let nickname: String
    let avatarURL: URL?
    let signature: String?
    let remarkName: String?
    let mutual: Bool?

    var displayName: String {
        let remark = remarkName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remark, !remark.isEmpty { return remark }
        return nickname
    }

    init(id: Int, nickname: String, avatarURL: URL? = nil, signature: String? = nil, remarkName: String? = nil, mutual: Bool? = nil) {
        self.id = id
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.signature = signature
        self.remarkName = remarkName
        self.mutual = mutual
    }

    init?(json: [String: Any]) {
        guard let id = json["userId"] as? Int ?? (json["id"] as? Int) else { return nil }
        self.id = id
        nickname = json["nickname"] as? String ?? "网易云用户"
        let avatar = json["avatarUrl"] as? String ?? ""
        avatarURL = avatar.isEmpty ? nil : URL(string: avatar)
        signature = json["signature"] as? String
        remarkName = json["remarkName"] as? String
        mutual = json["mutual"] as? Bool
    }
}

/// 私信里附带的歌曲 / 歌单 / 专辑卡片。
struct NetEaseMessageResource: Hashable {
    enum Kind: Hashable {
        case song, playlist, album
    }

    let kind: Kind
    let song: Song?
    let playlist: Playlist?
    let album: Album?

    var title: String {
        switch kind {
        case .song: return song?.name ?? ""
        case .playlist: return playlist?.name ?? ""
        case .album: return album?.name ?? ""
        }
    }

    var kindTitle: String {
        switch kind {
        case .song: return "歌曲"
        case .playlist: return "歌单"
        case .album: return "专辑"
        }
    }

    var coverURL: URL? {
        switch kind {
        case .song: return song?.coverURL
        case .playlist: return playlist?.coverURL
        case .album: return album?.coverURL
        }
    }
}

struct NetEasePrivateMessagePayload: Hashable {
    let text: String
    let resource: NetEaseMessageResource?

    var summary: String {
        if !text.isEmpty { return text }
        if let resource {
            return "[\(resource.kindTitle)] \(resource.title)"
        }
        return "私信"
    }

    /// msg / lastMsg 字段是 JSON 字符串，结构为 {msg: 文本, song/playlist/album: {...}}。
    static func decode(_ serialized: String) -> NetEasePrivateMessagePayload {
        guard let data = serialized.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return NetEasePrivateMessagePayload(text: serialized, resource: nil)
        }
        let text = (dict["msg"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var resource: NetEaseMessageResource?
        if let songDict = dict["song"] as? [String: Any], let song = Song(json: songDict) {
            resource = NetEaseMessageResource(kind: .song, song: song, playlist: nil, album: nil)
        } else if let playlistDict = dict["playlist"] as? [String: Any], let playlist = Playlist(json: playlistDict) {
            resource = NetEaseMessageResource(kind: .playlist, song: nil, playlist: playlist, album: nil)
        } else if let albumDict = dict["album"] as? [String: Any], let album = NetEaseAlbumMapping.album(from: albumDict) {
            resource = NetEaseMessageResource(kind: .album, song: nil, playlist: nil, album: album)
        }
        return NetEasePrivateMessagePayload(text: text, resource: resource)
    }
}

struct NetEasePrivateConversation: Identifiable, Hashable {
    let fromUser: NetEaseMessageContact?
    let toUser: NetEaseMessageContact?
    let lastMessageTime: Int64
    let lastMessage: NetEasePrivateMessagePayload
    var unreadCount: Int

    var id: String {
        [fromUser?.id ?? 0, toUser?.id ?? 0].sorted().map(String.init).joined(separator: "-")
    }

    func participant(currentUserID: Int) -> NetEaseMessageContact {
        if let fromUser, fromUser.id != currentUserID { return fromUser }
        if let toUser, toUser.id != currentUserID { return toUser }
        return fromUser ?? toUser ?? NetEaseMessageContact(id: 0, nickname: "网易云用户")
    }

    init?(json: [String: Any]) {
        fromUser = (json["fromUser"] as? [String: Any]).flatMap(NetEaseMessageContact.init(json:))
        toUser = (json["toUser"] as? [String: Any]).flatMap(NetEaseMessageContact.init(json:))
        lastMessageTime = (json["lastMsgTime"] as? NSNumber)?.int64Value ?? 0
        lastMessage = NetEasePrivateMessagePayload.decode(json["lastMsg"] as? String ?? "")
        unreadCount = json["newMsgCount"] as? Int ?? 0
    }
}

struct NetEasePrivateMessage: Identifiable, Hashable {
    let id: Int64
    let fromUser: NetEaseMessageContact?
    let toUser: NetEaseMessageContact?
    let time: Int64
    let payload: NetEasePrivateMessagePayload

    func isOutgoing(currentUserID: Int) -> Bool {
        fromUser?.id == currentUserID
    }

    init?(json: [String: Any]) {
        fromUser = (json["fromUser"] as? [String: Any]).flatMap(NetEaseMessageContact.init(json:))
        toUser = (json["toUser"] as? [String: Any]).flatMap(NetEaseMessageContact.init(json:))
        time = (json["time"] as? NSNumber)?.int64Value ?? 0
        id = (json["id"] as? NSNumber)?.int64Value ?? time
        payload = NetEasePrivateMessagePayload.decode(json["msg"] as? String ?? "")
    }
}

// MARK: - 模型（云盘）

struct NetEaseCloudSong: Identifiable, Hashable {
    let songID: Int
    let songName: String
    let artist: String
    let album: String
    let fileSize: Int64
    let bitrate: Int
    let addTime: Int64
    let song: Song

    var id: Int { songID }

    init?(json: [String: Any]) {
        guard let simple = json["simpleSong"] as? [String: Any], let song = Song(json: simple) else { return nil }
        self.song = song
        songID = json["songId"] as? Int ?? song.id
        songName = json["songName"] as? String ?? song.name
        artist = json["artist"] as? String ?? song.artists
        album = json["album"] as? String ?? song.album
        fileSize = (json["fileSize"] as? NSNumber)?.int64Value ?? 0
        bitrate = json["bitrate"] as? Int ?? 0
        addTime = (json["addTime"] as? NSNumber)?.int64Value ?? 0
    }
}

struct NetEaseCloudPage {
    let songs: [NetEaseCloudSong]
    let count: Int
    let size: Int64
    let maxSize: Int64
    let hasMore: Bool
}

// MARK: - 专辑字典映射（与 NetEaseAPI.searchAlbums 的字段口径一致）

enum NetEaseAlbumMapping {
    static func album(from item: [String: Any]) -> Album? {
        guard let id = item["id"] as? Int else { return nil }
        let artistName = (item["artist"] as? [String: Any])?["name"] as? String
            ?? (item["artists"] as? [[String: Any]])?.first?["name"] as? String ?? ""
        let pic = item["picUrl"] as? String ?? ""
        return Album(
            id: "netease-\(id)",
            name: item["name"] as? String ?? "",
            artistName: artistName,
            coverURL: pic.isEmpty ? nil : URL(string: pic),
            source: .netease,
            trackCount: item["size"] as? Int,
            releaseType: item["subType"] as? String ?? item["type"] as? String,
            releaseDate: Album.releaseDateText(from: item["publishTime"] ?? item["publishDate"])
        )
    }

    static func artist(from item: [String: Any]) -> Artist? {
        guard let id = item["id"] as? Int else { return nil }
        let pic = item["picUrl"] as? String ?? (item["img1v1Url"] as? String ?? "")
        return Artist(
            id: "netease-\(id)",
            name: item["name"] as? String ?? "",
            coverURL: pic.isEmpty ? nil : URL(string: pic),
            source: .netease
        )
    }
}

// MARK: - 接口

extension NetEaseAPI {
    /// weapi 优先；仅当响应体不是合法 JSON（服务端空体）时降级 eapi，与 MeloX 的回退条件对齐。
    private func socialRequest(_ uri: String, payload: [String: Any]) async throws -> [String: Any] {
        do {
            return try await request(uri, payload: payload, crypto: "weapi")
        } catch let error as NetEaseError {
            if case .decoding = error {
                return try await request(uri, payload: payload, crypto: "eapi")
            }
            throw error
        }
    }

    private func validateSocialCode(_ json: [String: Any]) throws {
        let code = json["code"] as? Int ?? 200
        guard code == 200 else {
            throw NetEaseError.unknown((json["message"] as? String) ?? (json["msg"] as? String) ?? "请求失败（\(code)）")
        }
    }

    // MARK: 私信

    func privateMessageConversations(offset: Int = 0, limit: Int = 50) async throws -> [NetEasePrivateConversation] {
        let json = try await socialRequest(
            "/api/msg/private/users",
            payload: ["offset": offset, "limit": limit, "total": "true"]
        )
        try validateSocialCode(json)
        let list = json["msgs"] as? [[String: Any]] ?? []
        return list.compactMap(NetEasePrivateConversation.init(json:))
    }

    func privateMessageHistory(userID: Int, before: Int64? = nil, limit: Int = 100) async throws -> [NetEasePrivateMessage] {
        // 网易云网页端首次打开会话时发送 -1，该请求同时承担服务端已读上报；
        // 0 只返回历史记录，不会清除未读状态（与 MeloX 原注释一致）。
        let json = try await socialRequest(
            "/api/msg/private/history",
            payload: ["userId": userID, "limit": limit, "time": before ?? -1, "total": "true"]
        )
        try validateSocialCode(json)
        let list = json["msgs"] as? [[String: Any]] ?? []
        return list.compactMap(NetEasePrivateMessage.init(json:)).sorted { $0.time < $1.time }
    }

    func sendPrivateText(_ message: String, to userIDs: [Int]) async throws {
        let recipients = Array(Set(userIDs)).sorted()
        guard !recipients.isEmpty else { throw NetEaseError.unknown("没有可发送的联系人") }
        let json = try await request(
            "/api/msg/private/send",
            payload: [
                "type": "text",
                "msg": message,
                "userIds": "[\(recipients.map(String.init).joined(separator: ","))]",
            ],
            crypto: "eapi"
        )
        try validateSocialCode(json)
    }

    /// 关注列表（用于发起新私信时选联系人），分页拉取，口径同 MeloX messageContacts。
    func messageContacts(userID: Int, pageSize: Int = 100, maximumCount: Int = 1000) async throws -> [NetEaseMessageContact] {
        var contacts: [NetEaseMessageContact] = []
        var loadedIDs = Set<Int>()
        var offset = 0
        var hasMore = true
        while hasMore, contacts.count < maximumCount {
            let json = try await socialRequest(
                "/api/user/getfollows/\(userID)",
                payload: ["offset": offset, "limit": min(pageSize, maximumCount - contacts.count), "order": true]
            )
            try validateSocialCode(json)
            let follow = (json["follow"] as? [[String: Any]] ?? []).compactMap(NetEaseMessageContact.init(json:))
            for contact in follow where loadedIDs.insert(contact.id).inserted {
                contacts.append(contact)
            }
            offset += follow.count
            hasMore = (json["more"] as? Bool ?? false) && !follow.isEmpty
        }
        return contacts
    }

    // MARK: 收藏专辑 / 关注歌手

    func subscribedAlbums(limit: Int = 2000) async throws -> [Album] {
        let json = try await socialRequest(
            "/api/album/sublist",
            payload: ["limit": max(limit, 1), "offset": 0, "total": true]
        )
        try validateSocialCode(json)
        let list = json["data"] as? [[String: Any]] ?? []
        return list.compactMap(NetEaseAlbumMapping.album(from:))
    }

    func subscribedArtists(limit: Int = 2000) async throws -> [Artist] {
        let json = try await socialRequest(
            "/api/artist/sublist",
            payload: ["limit": max(limit, 1), "offset": 0, "total": true]
        )
        try validateSocialCode(json)
        let list = json["data"] as? [[String: Any]] ?? []
        return list.compactMap(NetEaseAlbumMapping.artist(from:))
    }

    func setArtistFollowed(id: Int, followed: Bool) async throws {
        let json = try await socialRequest(
            followed ? "/api/artist/sub" : "/api/artist/unsub",
            payload: ["artistId": id, "artistIds": "[\(id)]"]
        )
        try validateSocialCode(json)
    }

    // MARK: 音乐云盘

    func cloudSongs(limit: Int = 200, offset: Int = 0) async throws -> NetEaseCloudPage {
        let json = try await socialRequest(
            "/api/v1/cloud/get",
            payload: ["limit": limit, "offset": offset]
        )
        try validateSocialCode(json)
        let list = (json["data"] as? [[String: Any]] ?? []).compactMap(NetEaseCloudSong.init(json:))
        let count = json["count"] as? Int ?? list.count
        return NetEaseCloudPage(
            songs: list,
            count: count,
            size: (json["size"] as? NSNumber)?.int64Value ?? 0,
            maxSize: (json["maxSize"] as? NSNumber)?.int64Value ?? 0,
            hasMore: (json["hasMore"] as? Bool) ?? (list.count < count)
        )
    }

    func deleteCloudSong(id: Int) async throws {
        let json = try await socialRequest(
            "/api/cloud/del",
            payload: ["songIds": [id]]
        )
        try validateSocialCode(json)
    }

    /// 云盘上传全链路，步骤与参数同 MeloX uploadCloudSong（源自 @neteaseapireborn/api 的 cloud.js）。
    func uploadCloudSong(fileAt url: URL) async throws {
        let file = try await NetEaseCloudUploadFile.prepare(from: url)
        let bitrate = 999_000

        let check = try await request(
            "/api/cloud/upload/check",
            payload: [
                "bitrate": String(bitrate),
                "ext": "",
                "length": file.size,
                "md5": file.md5,
                "songId": "0",
                "version": 1,
            ],
            crypto: "eapi"
        )
        try validateSocialCode(check)
        let needUpload = check["needUpload"] as? Bool ?? false
        let checkSongID = check["songId"] as? Int ?? 0

        let metadataToken = try await request(
            "/api/nos/token/alloc",
            payload: [
                "bucket": "",
                "ext": file.fileExtension,
                "filename": file.normalizedStem,
                "local": false,
                "nos_product": 3,
                "type": "audio",
                "md5": file.md5,
            ],
            crypto: "eapi"
        )
        try validateSocialCode(metadataToken)
        guard let metadataResult = metadataToken["result"] as? [String: Any],
              let resourceID = metadataResult["resourceId"] as? String else {
            throw NetEaseError.unknown("云盘上传令牌无效")
        }

        if needUpload {
            let bucket = "jd-musicrep-privatecloud-audio-public"
            // songUpload.js 故意为 NOS 传输单独取一份 weapi 令牌，resourceId 仍用上面的 eapi 结果。
            let tokenJSON = try await socialRequest(
                "/api/nos/token/alloc",
                payload: [
                    "bucket": bucket,
                    "ext": file.fileExtension,
                    "filename": file.normalizedStem,
                    "local": false,
                    "nos_product": 3,
                    "type": "audio",
                    "md5": file.md5,
                ]
            )
            try validateSocialCode(tokenJSON)
            guard let result = tokenJSON["result"] as? [String: Any],
                  let objectKey = result["objectKey"] as? String,
                  let token = result["token"] as? String else {
                throw NetEaseError.unknown("云盘上传令牌无效")
            }
            try await uploadToNOS(fileURL: file.url, bucket: bucket, objectKey: objectKey, token: token, md5: file.md5, fileSize: file.size)
        }

        let info = try await request(
            "/api/upload/cloud/info/v2",
            payload: [
                "md5": file.md5,
                "songid": checkSongID,
                "filename": file.filename,
                "song": file.songName,
                "album": file.album,
                "artist": file.artist,
                "bitrate": String(bitrate),
                "resourceId": resourceID,
            ],
            crypto: "eapi"
        )
        try validateSocialCode(info)
        let uploadedSongID = info["songId"] as? Int ?? 0

        let publish = try await request(
            "/api/cloud/pub/v2",
            payload: ["songid": uploadedSongID],
            crypto: "eapi"
        )
        try validateSocialCode(publish)
    }

    /// NOS 对象存储直传（先向 wanproxy LBS 取上传节点），同 MeloX NeteaseDirectClient.uploadToNOS。
    private func uploadToNOS(fileURL: URL, bucket: String, objectKey: String, token: String, md5: String, fileSize: Int64) async throws {
        var lbsComponents = URLComponents(string: "https://wanproxy.127.net/lbs")
        lbsComponents?.queryItems = [
            URLQueryItem(name: "version", value: "1.0"),
            URLQueryItem(name: "bucketname", value: bucket),
        ]
        guard let lbsURL = lbsComponents?.url else { throw NetEaseError.unknown("上传地址无效") }
        let (lbsData, lbsResponse) = try await URLSession.shared.data(from: lbsURL)
        guard let lbsHTTP = lbsResponse as? HTTPURLResponse, (200..<300).contains(lbsHTTP.statusCode),
              let lbsJSON = (try? JSONSerialization.jsonObject(with: lbsData)) as? [String: Any],
              let uploadHost = (lbsJSON["upload"] as? [String])?.first else {
            throw NetEaseError.unknown("没有可用的上传服务器")
        }

        var objectKeyAllowed = CharacterSet.urlPathAllowed
        objectKeyAllowed.remove(charactersIn: "/?#")
        guard let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: objectKeyAllowed),
              let uploadURL = URL(string: "\(uploadHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(bucket)/\(encodedKey)?offset=0&complete=true&version=1.0") else {
            throw NetEaseError.unknown("上传地址无效")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 200
        request.setValue(token, forHTTPHeaderField: "x-nos-token")
        request.setValue(md5, forHTTPHeaderField: "Content-MD5")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 200
        let (_, response) = try await URLSession(configuration: config).upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetEaseError.unknown("上传失败")
        }
    }
}

// MARK: - 云盘上传文件准备（同 MeloX CloudUploadFile：元数据 + MD5）

struct NetEaseCloudUploadFile: Sendable {
    let url: URL
    let filename: String
    let fileExtension: String
    let normalizedStem: String
    let size: Int64
    let md5: String
    let songName: String
    let artist: String
    let album: String

    static func prepare(from url: URL) async throws -> NetEaseCloudUploadFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw NetEaseError.unknown("所选文件不是有效的音频文件")
        }

        let metadata = await audioMetadata(for: url)
        let filename = url.lastPathComponent
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        let normalizedStem = fallbackName
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: ".", with: "_")

        let md5 = try await Task.detached(priority: .userInitiated) {
            try md5Hex(of: url)
        }.value

        return NetEaseCloudUploadFile(
            url: url,
            filename: filename,
            fileExtension: fileExtension,
            normalizedStem: normalizedStem.isEmpty ? "music" : normalizedStem,
            size: Int64(fileSize),
            md5: md5,
            songName: metadata.title ?? fallbackName,
            artist: metadata.artist ?? "未知歌手",
            album: metadata.album ?? "未知专辑"
        )
    }

    private struct AudioMetadata {
        var title: String?
        var artist: String?
        var album: String?
    }

    private static func audioMetadata(for url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return AudioMetadata() }
        var metadata = AudioMetadata()
        for item in items {
            guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            switch item.commonKey {
            case .commonKeyTitle: metadata.title = value
            case .commonKeyArtist: metadata.artist = value
            case .commonKeyAlbumName: metadata.album = value
            default: continue
            }
        }
        return metadata
    }

    private static func md5Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
