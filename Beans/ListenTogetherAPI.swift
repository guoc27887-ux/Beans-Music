//
//  ListenTogetherAPI.swift
//  Beans
//
//  一起听接口层，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Core/Networking/NeteaseListenTogetherAPI.swift
//  改动：MeloX 的 Codable 客户端（client.eapi / client.weapi）改为 Beans 的
//  字典式请求层 NetEaseAPI.request，再经 JSONSerialization 桥接回 Codable 解码；
//  错误类型由 APIError 换为 Beans 的 NetEaseError。
//  简化：房间状态接口在 MeloX 中 weapi 返回空体时降级 eapi 重试，Beans 的请求层
//  不区分空体错误，此处只走 weapi 一条路径。
//

import Foundation

enum ListenTogetherCommandType: String {
    case play = "PLAY"
    case pause = "PAUSE"
    case next = "NEXT"
    case previous = "PREV"
    case goTo = "GOTO"
    case progress = "PROGRESS"
}

extension NetEaseAPI {
    // MARK: - 一起听请求桥（字典响应 -> Codable）

    private func listenTogetherRequest<T: Decodable>(
        _ uri: String,
        payload: [String: Any] = [:],
        crypto: String
    ) async throws -> T {
        let json = try await request(uri, payload: payload, crypto: crypto)
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NetEaseError.decoding("一起听数据解析失败")
        }
    }

    private func validateListenTogetherCode(_ code: Int, message: String?) throws {
        guard code == 200 else {
            throw NetEaseError.unknown(message ?? "一起听请求失败（\(code)）")
        }
    }

    // MARK: - 歌曲详情（按 ID 批量获取，供房间队列同步加载缺失歌曲）

    func songDetails(ids: [Int]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let c = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        let json = try await request(
            "/api/v3/song/detail",
            payload: ["c": c],
            crypto: "weapi"
        )
        let list = json["songs"] as? [[String: Any]] ?? []
        return list.compactMap(Song.init(json:))
    }

    // MARK: - 一起听接口

    func createListenTogetherRoom() async throws -> ListenTogetherRoomPayload {
        let response: ListenTogetherRoomResponse = try await listenTogetherRequest(
            "/api/listen/together/room/create",
            payload: ["refer": "songplay_more"],
            crypto: "eapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        guard let data = response.data,
              let room = data.roomInfo,
              !room.id.isEmpty else {
            throw NetEaseError.unknown("创建房间失败")
        }
        return data
    }

    func listenTogetherRoomStatus() async throws -> ListenTogetherRoomStatus {
        // 该接口在官方实现中明确走 weapi。
        let response: ListenTogetherRoomStatusResponse = try await listenTogetherRequest(
            "/api/listen/together/status/get",
            crypto: "weapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        guard let data = response.data else {
            throw NetEaseError.unknown("获取房间状态失败")
        }
        return data
    }

    func checkListenTogetherRoom(
        roomID: String
    ) async throws -> ListenTogetherRoomCheck {
        let response: ListenTogetherRoomCheckResponse = try await listenTogetherRequest(
            "/api/listen/together/room/check",
            payload: ["roomId": roomID],
            crypto: "eapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        guard let data = response.data else {
            throw NetEaseError.unknown("检查房间失败")
        }
        return data
    }

    func acceptListenTogetherInvitation(
        roomID: String,
        inviterID: String
    ) async throws -> ListenTogetherRoomPayload {
        let response: ListenTogetherRoomResponse = try await listenTogetherRequest(
            "/api/listen/together/play/invitation/accept",
            payload: [
                "refer": "inbox_invite",
                "roomId": roomID,
                "inviterId": inviterID,
            ],
            crypto: "eapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        guard let data = response.data else {
            throw NetEaseError.unknown("接受邀请失败")
        }
        return data
    }

    func listenTogetherPlayback(
        roomID: String
    ) async throws -> ListenTogetherPlaybackPayload {
        let response: ListenTogetherPlaybackResponse = try await listenTogetherRequest(
            "/api/listen/together/sync/playlist/get",
            payload: ["roomId": roomID],
            crypto: "eapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        guard let data = response.data else {
            throw NetEaseError.unknown("获取房间播放状态失败")
        }
        return data
    }

    func reportListenTogetherPlaylist(
        roomID: String,
        userID: Int,
        version: Int,
        displaySongIDs: [Int],
        randomSongIDs: [Int],
        commandType: String = "REPLACE"
    ) async throws {
        let playlist = try listenTogetherJSONString([
            "commandType": commandType,
            "version": [
                [
                    "userId": userID,
                    "version": version,
                ],
            ],
            "anchorSongId": "",
            "anchorPosition": -1,
            "randomList": randomSongIDs.map(String.init),
            "displayList": displaySongIDs.map(String.init),
        ])
        let response: ListenTogetherActionResponse = try await listenTogetherRequest(
            "/api/listen/together/sync/list/command/report",
            payload: [
                "roomId": roomID,
                "playlistParam": playlist,
            ],
            crypto: "eapi"
        )
        try validateListenTogetherAction(response)
    }

    func reportListenTogetherCommand(
        roomID: String,
        commandType: ListenTogetherCommandType,
        progressMilliseconds: Int64,
        isPlaying: Bool,
        formerSongID: Int?,
        targetSongID: Int,
        clientSequence: Int
    ) async throws {
        let command = try listenTogetherJSONString([
            "commandType": commandType.rawValue,
            "progress": max(progressMilliseconds, 0),
            "playStatus": isPlaying ? "PLAY" : "PAUSE",
            "formerSongId": String(formerSongID ?? -1),
            "targetSongId": String(targetSongID),
            "clientSeq": clientSequence,
        ])
        let response: ListenTogetherActionResponse = try await listenTogetherRequest(
            "/api/listen/together/play/command/report",
            payload: [
                "roomId": roomID,
                "commandInfo": command,
            ],
            crypto: "eapi"
        )
        try validateListenTogetherAction(response)
    }

    @discardableResult
    func sendListenTogetherHeartbeat(
        roomID: String,
        songID: Int,
        isPlaying: Bool,
        progressMilliseconds: Int64
    ) async throws -> Int? {
        let response: ListenTogetherActionResponse = try await listenTogetherRequest(
            "/api/listen/together/heartbeat",
            payload: [
                "roomId": roomID,
                "songId": songID,
                "playStatus": isPlaying ? "PLAY" : "PAUSE",
                "progress": max(progressMilliseconds, 0),
            ],
            crypto: "eapi"
        )
        try validateListenTogetherAction(response)
        return response.data?.timeSpan
    }

    func endListenTogetherRoom(roomID: String) async throws {
        let response: ListenTogetherActionResponse = try await listenTogetherRequest(
            "/api/listen/together/end/v2",
            payload: ["roomId": roomID],
            crypto: "eapi"
        )
        try validateListenTogetherCode(response.code, message: response.message)
        if response.data?.success == false
            || response.data?.result == false {
            throw NetEaseError.unknown(response.message ?? "结束一起听失败")
        }
    }

    private func validateListenTogetherAction(
        _ response: ListenTogetherActionResponse
    ) throws {
        try validateListenTogetherCode(response.code, message: response.message)
        if response.data?.result == false
            || response.data?.success == false {
            throw NetEaseError.unknown(response.message ?? "一起听操作未完成")
        }
    }

    private func listenTogetherJSONString(
        _ object: [String: Any]
    ) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NetEaseError.unknown("一起听参数编码失败")
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw NetEaseError.unknown("一起听参数编码失败")
        }
        return string
    }
}
