//
//  NetEaseEngagementAPI.swift
//  Beans
//
//  网易云互动类接口补充：歌单订阅（收藏他人歌单）、雷达歌单、听歌上报。
//  接口与行为参考 Kumone（missuo/kumone，LGPL-3.0）的对应实现与
//  NeteaseCloudMusicApi 的公开接口定义；代码为 Beans 自行编写，
//  统一走 Beans 现有 NetEaseAPI 的加密请求通道，不另起网络层。
//

import Foundation

extension NetEaseAPI {
    // MARK: - 歌单订阅（收藏 / 取消收藏他人的歌单）

    /// 订阅或取消订阅一个歌单。端点 /api/playlist/subscribe|unsubscribe（weapi），
    /// 与 NeteaseCloudMusicApi 的 playlist_subscribe 模块一致（t: 1 订阅 / 2 取消）。
    func setPlaylistSubscribed(id: Int, subscribed: Bool) async throws {
        let uri = subscribed ? "/api/playlist/subscribe" : "/api/playlist/unsubscribe"
        let json = try await request(
            uri,
            payload: ["t": subscribed ? 1 : 2, "id": id],
            crypto: "weapi"
        )
        guard (json["code"] as? Int ?? 200) == 200 else {
            throw NetEaseError.unknown("歌单订阅操作失败")
        }
    }

    /// 查询歌单的订阅状态与创建者：取歌单详情里的 subscribed 与 userId 字段，
    /// 与账号实际状态同步（不靠本地猜测）。
    func playlistSubscriptionState(id: Int) async throws -> (subscribed: Bool, ownerID: Int) {
        let json = try await request(
            "/api/v6/playlist/detail",
            payload: ["id": id, "n": 0, "s": 8],
            crypto: "eapi"
        )
        let playlist = json["playlist"] as? [String: Any] ?? [:]
        return (
            subscribed: playlist["subscribed"] as? Bool ?? false,
            ownerID: playlist["userId"] as? Int ?? 0
        )
    }

    // MARK: - 雷达歌单

    /// 雷达歌单的固定歌单 ID（私人 / 华语 / 欧美 / 日系），与 Kumone 的
    /// HomeViewModel.radarPlaylistIDs 及 YesPlayMusic 的特殊处理一致：
    /// ID 全局固定，内容由服务端按当前登录账号生成。
    static var radarPlaylistIDs: [Int] { [3_136_952_023, 2_829_883_282, 2_829_816_518, 2_829_896_389] }

    /// 并发取 4 个雷达歌单的简要信息（走现有 playlistInfo，即
    /// /api/v6/playlist/detail）。名称形如「今天从《…》听起|私人雷达」：
    /// 竖线后为标题（私人雷达等），竖线前为副标题，拆分方式同 Kumone。
    /// 未登录或单个歌单取不到时跳过该项，整体失败返回空数组。
    func radarPlaylists() async -> [Playlist] {
        let briefs = await withTaskGroup(of: (Int, Playlist?).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    let brief = (try? await self.playlistInfo(id: id)) ?? nil
                    return (id, brief)
                }
            }
            var byID: [Int: Playlist] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        return Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            let parts = brief.name.components(separatedBy: "|")
            let title = parts.count > 1 ? (parts.last ?? brief.name) : brief.name
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return Playlist(
                id: brief.id,
                name: title,
                coverURL: brief.coverURL,
                trackCount: brief.trackCount,
                playCount: brief.playCount,
                creatorName: brief.creatorName,
                creatorAvatarURL: brief.creatorAvatarURL,
                playlistDescription: subtitle ?? brief.playlistDescription,
                source: .netease
            )
        }
    }

    // MARK: - 听歌上报（scrobble）

    /// 上报一首歌开始播放（startplay weblog）：写入账号的「最近播放」。
    /// 端点与载荷同 Kumone 的 scrobbleStart：eapi /api/feedback/weblog，
    /// logs 为 JSON 字符串。失败静默（try?），不影响播放。
    /// sourceID 为来源歌单 ID，未知时传 0。
    func scrobbleStart(songID: Int, sourceID: Int) async {
        let log: [[String: Any]] = [[
            "action": "startplay",
            "json": [
                "id": songID, "type": "song",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ] as [String: Any],
        ]]
        await sendWeblog(log)
    }

    /// 上报一首歌的实际收听时长（play weblog）：累加听歌排行计数与时长。
    /// 同 Kumone 的 scrobbleFinish（end 固定 playend，seconds 为实际收听秒数）。
    func scrobbleFinish(songID: Int, sourceID: Int, seconds: Int) async {
        let log: [[String: Any]] = [[
            "action": "play",
            "json": [
                "download": 0, "end": "playend", "id": songID,
                "sourceId": String(sourceID), "time": seconds,
                "type": "song", "wifi": 0, "source": "list",
                "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=\(sourceID)",
            ] as [String: Any],
        ]]
        await sendWeblog(log)
    }

    private func sendWeblog(_ log: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: log),
              let logs = String(data: data, encoding: .utf8) else { return }
        _ = try? await request("/api/feedback/weblog", payload: ["logs": logs], crypto: "eapi")
    }
}
