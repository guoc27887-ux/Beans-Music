//
//  ListenTogetherStore.swift
//  Beans
//
//  一起听会话与同步逻辑，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Core/Playback/Session/ListenTogetherStore.swift、
//          ListenTogetherStore+PlayerEvents.swift、ListenTogetherStore+Synchronization.swift
//  改动：@Observable 改为 Beans 通用的 ObservableObject + @Published；
//        播放器由 MeloX 的 PlayerStore 换为 Beans 的 PlayerManager（同名适配接口）；
//        账号与接口走 Beans 的 NetEaseAPI；本地化文案改为中文字面量。
//  同步方式与原版一致：1 秒轮询房间播放状态 + 周期性房间状态刷新 + 心跳，无 WebSocket。
//

import Foundation

enum ListenTogetherConnectionState: Equatable {
    case idle
    case connected
    case reconnecting

    var title: String {
        switch self {
        case .idle:
            "未连接"
        case .connected:
            "已连接"
        case .reconnecting:
            "重新连接中"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            "circle"
        case .connected:
            "checkmark.circle.fill"
        case .reconnecting:
            "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

enum ListenTogetherOperation: Equatable {
    case creating
    case joining
    case leaving

    var title: String {
        switch self {
        case .creating:
            "正在创建房间"
        case .joining:
            "正在加入房间"
        case .leaving:
            "正在离开房间"
        }
    }
}

enum ListenTogetherSessionError: LocalizedError {
    case noCurrentSong
    case roomUnavailable(String?)
    case missingRoom
    case missingAccount
    case invalidPlaybackState

    var errorDescription: String? {
        switch self {
        case .noCurrentSong:
            "先播放一首歌再开始一起听"
        case .roomUnavailable(let status):
            if status?.uppercased() == "FULL" {
                "房间已满员"
            } else {
                "房间不可用或已结束"
            }
        case .missingRoom:
            "未能获取房间信息"
        case .missingAccount:
            "未获取到账号信息"
        case .invalidPlaybackState:
            "房间播放状态异常"
        }
    }
}

struct PendingListenTogetherTransportReport {
    let type: ListenTogetherCommandType
    let formerSongID: Int?
    let targetSongID: Int
    let isPlaying: Bool
    let progressMilliseconds: Int64
}

@MainActor
final class ListenTogetherStore: ObservableObject {
    @Published var room: ListenTogetherRoom?
    @Published var isHost = false
    @Published var connectionState: ListenTogetherConnectionState = .idle
    @Published private(set) var operation: ListenTogetherOperation?
    @Published var lastSyncDate: Date?
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    var isInRoom: Bool {
        room != nil
    }

    var isBusy: Bool {
        operation != nil
    }

    var invitationURL: URL? {
        guard let room,
              let inviterID = localUserID.map(String.init)
                ?? nonEmpty(room.creatorID),
              let songID = player.currentSong?.id else {
            return nil
        }
        var components = URLComponents(
            string: "https://st.music.163.com/listen-together/share/"
        )
        components?.queryItems = [
            URLQueryItem(name: "songId", value: String(songID)),
            URLQueryItem(name: "roomId", value: room.id),
            URLQueryItem(name: "inviterId", value: inviterID),
        ]
        return components?.url
    }

    let api = NetEaseAPI.shared
    let player: PlayerManager

    var localUserID: Int?
    var clientSequence = 0

    /// 本机刚上报过的命令序号；服务器回显这些命令时不能把播放再拉回去。
    var locallyReportedCommandSequences: [Int] = []

    var monitorTask: Task<Void, Never>?
    var queueReportTask: Task<Void, Never>?
    var queueReportRevision = 0
    var transportReportTask: Task<Void, Never>?
    var pendingTransportReport: PendingListenTogetherTransportReport?
    var sessionRevision = 0
    var localChangeRevision = 0
    var synchronizingSession: Int?
    var lastPlaylistSignature: String?
    var lastCommandSignature: String?
    var consecutiveSyncFailures = 0

    init(player: PlayerManager) {
        self.player = player
        player.onListenTogetherTransport = { [weak self] type, formerSongID in
            self?.playerTransportDidChange(type: type, formerSongID: formerSongID)
        }
        player.onListenTogetherQueueEdit = { [weak self] in
            self?.playerQueueDidChange()
        }
    }

    func accountDidChange(hasCredentials: Bool) async {
        if isInRoom {
            clearSession()
        }
        guard hasCredentials else { return }
        await restoreSession()
    }

    func createRoom() async {
        guard !isBusy, !isInRoom else { return }
        guard player.currentSong != nil else {
            errorMessage =
                ListenTogetherSessionError.noCurrentSong.localizedDescription
            return
        }

        operation = .creating
        errorMessage = nil
        noticeMessage = nil
        defer { operation = nil }

        do {
            let profile = try await api.account()
            let payload = try await api.createListenTogetherRoom()
            guard let createdRoom = payload.roomInfo else {
                throw ListenTogetherSessionError.missingRoom
            }

            establishSession(
                room: createdRoom,
                localUserID: profile.uid
            )
            do {
                try await sendPlaylistSnapshot()
                try await sendCurrentPlaybackCommand(type: .goTo)
                try await sendHeartbeat()
            } catch is CancellationError {
                startMonitoring()
                return
            } catch {
                connectionState = .reconnecting
                errorMessage =
                    "房间已创建，但首次同步失败：\(error.localizedDescription)"
            }
            startMonitoring()
        } catch is CancellationError {
            return
        } catch {
            if isInRoom {
                clearSession()
            }
            errorMessage = error.localizedDescription
        }
    }

    func joinRoom(invitationText: String) async {
        guard !isBusy, !isInRoom else { return }

        operation = .joining
        errorMessage = nil
        noticeMessage = nil
        defer { operation = nil }

        do {
            let invitation = try ListenTogetherInvitation(
                text: invitationText
            )
            let profile = try await api.account()
            let roomCheck = try await api.checkListenTogetherRoom(
                roomID: invitation.roomID
            )
            guard roomCheck.isJoinable else {
                throw ListenTogetherSessionError.roomUnavailable(
                    roomCheck.status
                )
            }

            let payload = try await api.acceptListenTogetherInvitation(
                roomID: invitation.roomID,
                inviterID: invitation.inviterID
            )
            let joinedRoom: ListenTogetherRoom
            if let acceptedRoom = payload.roomInfo {
                joinedRoom = acceptedRoom
            } else {
                let status = try await api.listenTogetherRoomStatus()
                guard status.isInRoom,
                      let statusRoom = status.roomInfo,
                      statusRoom.id == invitation.roomID else {
                    throw ListenTogetherSessionError.missingRoom
                }
                joinedRoom = statusRoom
            }

            establishSession(
                room: joinedRoom,
                localUserID: profile.uid
            )
            do {
                try await synchronizeFromServer(initial: true)
                try await sendHeartbeat()
            } catch is CancellationError {
                startMonitoring()
                return
            } catch {
                connectionState = .reconnecting
                errorMessage =
                    "已加入房间，等待同步播放状态：\(error.localizedDescription)"
            }
            startMonitoring()
        } catch is CancellationError {
            return
        } catch {
            if isInRoom {
                clearSession()
            }
            errorMessage = error.localizedDescription
        }
    }

    func leaveRoom() async {
        guard !isBusy, let room else { return }

        operation = .leaving
        errorMessage = nil
        var leaveError: Error?
        do {
            try await api.endListenTogetherRoom(roomID: room.id)
        } catch is CancellationError {
            operation = nil
            return
        } catch {
            leaveError = error
        }

        clearSession()
        operation = nil
        if let leaveError {
            noticeMessage =
                "已离开房间，但服务器结束失败：\(leaveError.localizedDescription)"
        }
    }

    func refresh() async {
        guard !isBusy, isInRoom else { return }
        do {
            try await refreshRoomStatus()
            guard isInRoom else { return }
            try await synchronizeFromServer(initial: false)
            try await sendHeartbeat()
            connectionState = .connected
            consecutiveSyncFailures = 0
            lastSyncDate = .now
        } catch is CancellationError {
            return
        } catch {
            connectionState = .reconnecting
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissNotice() {
        noticeMessage = nil
    }

    func establishSession(
        room: ListenTogetherRoom,
        localUserID: Int
    ) {
        sessionRevision += 1
        monitorTask?.cancel()
        queueReportTask?.cancel()
        queueReportTask = nil
        transportReportTask?.cancel()
        transportReportTask = nil
        pendingTransportReport = nil
        self.room = room
        self.localUserID = localUserID
        isHost = room.creatorID == String(localUserID)
        clientSequence = 0
        locallyReportedCommandSequences = []
        lastPlaylistSignature = nil
        lastCommandSignature = nil
        consecutiveSyncFailures = 0
        connectionState = .connected
        lastSyncDate = nil
        player.beginListenTogetherSession()
    }

    func clearSession(notice: String? = nil) {
        sessionRevision += 1
        monitorTask?.cancel()
        monitorTask = nil
        queueReportTask?.cancel()
        queueReportTask = nil
        transportReportTask?.cancel()
        transportReportTask = nil
        pendingTransportReport = nil
        room = nil
        localUserID = nil
        isHost = false
        clientSequence = 0
        locallyReportedCommandSequences = []
        lastPlaylistSignature = nil
        lastCommandSignature = nil
        consecutiveSyncFailures = 0
        connectionState = .idle
        lastSyncDate = nil
        player.endListenTogetherSession()
        if let notice {
            noticeMessage = notice
        }
    }

    private func restoreSession() async {
        guard !isInRoom else { return }
        do {
            async let profile = api.account()
            async let roomStatus = api.listenTogetherRoomStatus()
            let (loadedProfile, status) = try await (
                profile,
                roomStatus
            )
            guard status.isInRoom,
                  let restoredRoom = status.roomInfo,
                  !restoredRoom.id.isEmpty else {
                return
            }

            establishSession(
                room: restoredRoom,
                localUserID: loadedProfile.uid
            )
            do {
                try await synchronizeFromServer(initial: true)
            } catch is CancellationError {
                startMonitoring()
                return
            } catch {
                connectionState = .reconnecting
            }
            startMonitoring()
        } catch is CancellationError {
            return
        } catch {
            // 服务端没有进行中的房间是正常启动状态。
            return
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

// MARK: - 播放器事件上报（原 ListenTogetherStore+PlayerEvents）

extension ListenTogetherStore {
    func playerTransportDidChange(
        type: ListenTogetherCommandType,
        formerSongID: Int?
    ) {
        guard isInRoom, operation != .leaving,
              let targetSongID = player.currentSong?.id else { return }
        localChangeRevision += 1
        let pending = pendingTransportReport
        let preservesTrackChange = pending?.type == .goTo
            && pending?.targetSongID == targetSongID
        let isPlaying: Bool
        switch type {
        case .play: isPlaying = true
        case .pause: isPlaying = false
        default: isPlaying = player.listenTogetherReportedPlaying
        }
        pendingTransportReport = PendingListenTogetherTransportReport(
            type: preservesTrackChange ? .goTo : type,
            formerSongID: preservesTrackChange ? pending?.formerSongID : formerSongID,
            targetSongID: targetSongID,
            isPlaying: isPlaying,
            progressMilliseconds: Int64((player.estimatedProgress() * 1_000).rounded())
        )
        guard transportReportTask == nil else { return }
        let session = sessionRevision
        transportReportTask = Task { @MainActor [weak self] in
            await self?.sendPendingTransportReports(session: session)
        }
    }

    private func sendPendingTransportReports(session: Int) async {
        defer {
            if sessionRevision == session {
                transportReportTask = nil
            }
        }
        // 合并短时间内的连续操作再发送；发送中按序完成，避免新操作被旧请求覆盖。
        while !Task.isCancelled, sessionRevision == session,
              pendingTransportReport != nil {
            do {
                try await Task.sleep(for: .milliseconds(40))
                guard sessionRevision == session, operation != .leaving,
                      let pending = pendingTransportReport else { return }
                pendingTransportReport = nil
                try await sendCommand(
                    type: pending.type,
                    formerSongID: pending.formerSongID,
                    targetSongID: pending.targetSongID,
                    isPlaying: pending.isPlaying,
                    progressMilliseconds: pending.progressMilliseconds
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, sessionRevision == session else { return }
                connectionState = .reconnecting
            }
        }
    }

    func playerQueueDidChange() {
        guard isInRoom, operation != .leaving else { return }
        localChangeRevision += 1
        queueReportTask?.cancel()
        queueReportRevision += 1
        let session = sessionRevision
        let revision = queueReportRevision
        queueReportTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.sessionRevision == session,
                   self.queueReportRevision == revision {
                    self.queueReportTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self,
                      self.sessionRevision == session,
                      self.operation != .leaving else { return }
                try await self.sendPlaylistSnapshot()
            } catch {
                guard !Task.isCancelled, let self,
                      self.sessionRevision == session else { return }
                self.connectionState = .reconnecting
            }
        }
    }

    func sendPlaylistSnapshot() async throws {
        guard let room,
              let localUserID else {
            throw ListenTogetherSessionError.missingAccount
        }
        let displaySongIDs = player.listenTogetherDisplaySongIDs
        guard !displaySongIDs.isEmpty else {
            throw ListenTogetherSessionError.noCurrentSong
        }
        let randomSongIDs = player.listenTogetherRandomSongIDs
        clientSequence += 1
        try await api.reportListenTogetherPlaylist(
            roomID: room.id,
            userID: localUserID,
            version: clientSequence,
            displaySongIDs: displaySongIDs,
            randomSongIDs: randomSongIDs.isEmpty
                ? displaySongIDs
                : randomSongIDs
        )
    }

    func sendCurrentPlaybackCommand(
        type: ListenTogetherCommandType
    ) async throws {
        guard let songID = player.currentSong?.id else {
            throw ListenTogetherSessionError.noCurrentSong
        }
        try await sendCommand(
            type: type,
            formerSongID: songID,
            targetSongID: songID
        )
    }

    private func sendCommand(
        type: ListenTogetherCommandType,
        formerSongID: Int?,
        targetSongID: Int,
        isPlaying: Bool? = nil,
        progressMilliseconds: Int64? = nil
    ) async throws {
        guard let room else { return }
        clientSequence += 1
        locallyReportedCommandSequences.append(clientSequence)
        if locallyReportedCommandSequences.count > 16 {
            locallyReportedCommandSequences.removeFirst()
        }
        try await api.reportListenTogetherCommand(
            roomID: room.id,
            commandType: type,
            progressMilliseconds: progressMilliseconds ?? Int64(
                (player.estimatedProgress() * 1_000).rounded()
            ),
            isPlaying: isPlaying ?? player.listenTogetherReportedPlaying,
            formerSongID: formerSongID,
            targetSongID: targetSongID,
            clientSequence: clientSequence
        )
    }

    func sendHeartbeat() async throws {
        guard let room,
              let songID = player.currentSong?.id else {
            return
        }
        try await api.sendListenTogetherHeartbeat(
            roomID: room.id,
            songID: songID,
            isPlaying: player.listenTogetherReportedPlaying,
            progressMilliseconds: Int64(
                (player.estimatedProgress() * 1_000).rounded()
            )
        )
    }

    func commandOriginatedLocally(_ command: ListenTogetherPlayCommand?) -> Bool {
        guard let command,
              let localUserID,
              command.userID == String(localUserID),
              let sequence = Int(exactly: command.clientSequence) else { return false }
        return locallyReportedCommandSequences.contains(sequence)
    }
}

// MARK: - 服务器同步（原 ListenTogetherStore+Synchronization）

extension ListenTogetherStore {
    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            await self?.monitorSession()
        }
    }

    private func monitorSession() async {
        var tick = 0
        while !Task.isCancelled, isInRoom {
            tick += 1
            await pollServer(
                includesRoomStatus: tick == 1 || tick.isMultiple(of: 5)
            )
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func pollServer(
        includesRoomStatus: Bool
    ) async {
        let session = sessionRevision
        do {
            try await synchronizeFromServer(initial: false)
            guard isInRoom, sessionRevision == session else { return }

            if includesRoomStatus {
                try await refreshRoomStatus()
                guard isInRoom, sessionRevision == session else { return }
                try await sendHeartbeat()
            }

            guard sessionRevision == session else { return }
            consecutiveSyncFailures = 0
            connectionState = .connected
            lastSyncDate = .now
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, sessionRevision == session else { return }
            consecutiveSyncFailures += 1
            if consecutiveSyncFailures >= 2 {
                connectionState = .reconnecting
            }
        }
    }

    func refreshRoomStatus() async throws {
        guard let expectedRoom = room else { return }
        let session = sessionRevision
        let status = try await api.listenTogetherRoomStatus()
        try Task.checkCancellation()
        guard sessionRevision == session else { return }
        guard status.isInRoom else {
            clearSession(notice: "一起听已结束")
            return
        }
        guard let updatedRoom = status.roomInfo else { return }
        guard updatedRoom.id == expectedRoom.id else {
            clearSession(notice: "你已在其他设备加入了一起听")
            return
        }
        room = updatedRoom
        if let localUserID {
            isHost = updatedRoom.creatorID == String(localUserID)
        }
    }

    func synchronizeFromServer(initial: Bool) async throws {
        guard let room, operation != .leaving else { return }
        let session = sessionRevision
        guard synchronizingSession != session, transportReportTask == nil,
              queueReportTask == nil else { return }
        synchronizingSession = session
        defer {
            if synchronizingSession == session {
                synchronizingSession = nil
            }
        }
        let revision = localChangeRevision
        let payload = try await api.listenTogetherPlayback(roomID: room.id)
        try Task.checkCancellation()
        guard sessionRevision == session, localChangeRevision == revision,
              operation != .leaving else { return }

        let playlistSignature = signature(for: payload.playlist)
        let commandSignature = signature(for: payload.playCommand)
        let playlistChanged = playlistSignature != lastPlaylistSignature
        let commandChanged = commandSignature != lastCommandSignature
        guard initial || playlistChanged || commandChanged else { return }

        let command = payload.playCommand
        let appliesTransport = initial || (
            commandChanged && command != nil && !commandOriginatedLocally(command)
        )
        if !appliesTransport, !playlistChanged {
            lastCommandSignature = commandSignature
            return
        }

        var songIDs = payload.playlist?.playbackSongIDs ?? []
        if songIDs.isEmpty {
            songIDs = player.queue.map(\.id)
        }
        let targetSongID = (appliesTransport ? command?.targetSongNumericID : nil)
            ?? player.currentSong?.id ?? songIDs.first
        guard let targetSongID else {
            throw ListenTogetherSessionError.invalidPlaybackState
        }
        if !songIDs.contains(targetSongID) {
            songIDs.append(targetSongID)
        }

        let songs: [Song]
        if songIDs == player.queue.map(\.id) {
            songs = player.queue
        } else {
            songs = try await loadSongsPreservingOrder(ids: songIDs)
        }
        try Task.checkCancellation()
        guard sessionRevision == session, localChangeRevision == revision,
              operation != .leaving else { return }
        guard songs.contains(where: { $0.id == targetSongID }) else {
            throw ListenTogetherSessionError.invalidPlaybackState
        }

        if appliesTransport {
            let shouldPlay = command?.shouldPlay ?? player.listenTogetherReportedPlaying
            let progress = command.map { TimeInterval($0.progressMilliseconds) / 1_000 }
                ?? player.estimatedProgress()
            await player.synchronizeListenTogetherPlayback(
                songs: songs,
                targetSongID: targetSongID,
                progress: progress,
                isPlaying: shouldPlay,
                adoptsRoomPlayMode: initial,
                playMode: payload.playlist?.playMode
            )
        } else {
            player.synchronizeListenTogetherQueue(songs: songs)
        }
        guard sessionRevision == session, operation != .leaving else { return }
        lastPlaylistSignature = playlistSignature
        lastCommandSignature = commandSignature
    }

    private func loadSongsPreservingOrder(
        ids: [Int]
    ) async throws -> [Song] {
        var loadedByID: [Int: Song] = [:]
        for song in player.queue {
            loadedByID[song.id] = song
        }
        let missingIDs = ids.filter { loadedByID[$0] == nil }
        var start = 0
        while start < missingIDs.count {
            try Task.checkCancellation()
            let end = min(start + 100, missingIDs.count)
            let page = try await api.songDetails(
                ids: Array(missingIDs[start..<end])
            )
            for song in page {
                loadedByID[song.id] = song
            }
            start = end
        }
        return ids.compactMap { loadedByID[$0] }
    }

    private func signature(
        for playlist: ListenTogetherPlaylistSnapshot?
    ) -> String? {
        guard let playlist else { return nil }
        let ids = playlist.playbackSongIDs.map(String.init).joined(
            separator: ","
        )
        let versions = playlist.versions.map {
            "\($0.userID):\($0.version)"
        }.joined(separator: ",")
        return "\(playlist.playMode ?? "")|\(ids)|\(versions)"
    }

    private func signature(
        for command: ListenTogetherPlayCommand?
    ) -> String? {
        guard let command else { return nil }
        return [
            String(command.serverSequence),
            String(command.clientSequence),
            command.userID ?? "",
            command.commandType ?? "",
            command.targetSongID ?? "",
            String(command.progressMilliseconds),
            command.playStatus ?? "",
        ].joined(separator: "|")
    }
}
