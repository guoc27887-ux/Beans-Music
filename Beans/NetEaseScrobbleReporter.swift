//
//  NetEaseScrobbleReporter.swift
//  Beans
//
//  网易云听歌上报（scrobble），行为参考 Kumone（missuo/kumone，LGPL-3.0）的
//  PlayerService scrobble 逻辑，代码为 Beans 自行编写：
//   - 一首歌真正开始播放后上报一次 startplay（写入「最近播放」）；
//   - 这次播放结束时（自然播完、切歌、停止）上报一次 play，
//     秒数为本次实际收听时长；自然播完时按整首时长上报；
//   - 同一次播放内两类上报各只发一次，重复播放（单曲循环）重新计；
//   - 只上报网易云来源且已登录的歌曲；失败静默，不影响播放。
//  实现上不侵入 PlayerManager：观察器每 2 秒读一次其公开播放状态，
//  靠进度增量累计实际收听秒数（暂停、拖动不计入），网络请求只在
//  上述两个事件点发生，不按秒上报。
//

import Foundation

@MainActor
final class NetEaseScrobbleReporter {
    static let shared = NetEaseScrobbleReporter()

    private weak var player: PlayerManager?
    private weak var auth: AuthStore?
    private var timer: Timer?

    // 当前播放会话（以歌曲 identityKey + 一次起播为界）
    private var sessionIdentity: String?
    private var sessionSongID = 0
    private var sessionIsNetEase = false
    private var startedReported = false
    private var finishReported = false
    private var listenedSeconds: Double = 0
    private var lastProgress: Double = 0

    private init() {}

    /// 在 App 根视图出现时启动一次（重复调用无副作用）。
    func start(player: PlayerManager, auth: AuthStore) {
        self.player = player
        self.auth = auth
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let player else { return }
        let song = player.currentSong
        let progress = player.currentPlaybackTime()
        let duration = player.duration > 0 ? player.duration : (song?.duration ?? 0)

        // 歌曲切换（含停止后清空）：先结算上一首，再开新会话。
        if song?.identityKey != sessionIdentity {
            finishSessionIfNeeded()
            beginSession(song: song)
            lastProgress = progress
        } else if let song, finishReported, progress < 3, lastProgress > progress + 5 {
            // 单曲循环回到开头：视为同歌的一次新播放，重新计。
            beginSession(song: song)
            lastProgress = progress
        }

        guard sessionIsNetEase, auth?.isLoggedIn == true,
              let song, song.id == sessionSongID else {
            lastProgress = progress
            return
        }

        if player.isPlaying {
            // 实际收听秒数 = 播放中的进度增量累计（暂停与拖动跳变不计入）。
            let delta = progress - lastProgress
            if delta > 0, delta <= 15 {
                listenedSeconds += delta
            }
            if !startedReported, listenedSeconds > 0.5 {
                startedReported = true
                let id = song.id
                Task.detached { await NetEaseAPI.shared.scrobbleStart(songID: id, sourceID: 0) }
            }
            // 自然播完：进度到达末尾，按整首时长结算（Kumone 的 completed 路径）。
            if !finishReported, duration > 0, progress >= duration - 1.5, listenedSeconds > 1 {
                finishReported = true
                let id = song.id
                let seconds = Int(duration)
                Task.detached {
                    await NetEaseAPI.shared.scrobbleFinish(songID: id, sourceID: 0, seconds: seconds)
                }
            }
        }
        lastProgress = progress
    }

    private func beginSession(song: Song?) {
        sessionIdentity = song?.identityKey
        sessionSongID = song?.id ?? 0
        sessionIsNetEase = song?.source == .netease
        startedReported = false
        finishReported = false
        listenedSeconds = 0
    }

    /// 切歌 / 停止时结算上一首：实际收听超过 1 秒才上报（同 Kumone 的
    /// progress > 1 门槛），秒数取累计实际收听时长；已按自然播完结算过的不重复。
    private func finishSessionIfNeeded() {
        guard sessionIsNetEase, sessionSongID > 0,
              !finishReported, listenedSeconds > 1,
              auth?.isLoggedIn == true else { return }
        finishReported = true
        let id = sessionSongID
        let seconds = Int(listenedSeconds)
        Task.detached {
            await NetEaseAPI.shared.scrobbleFinish(songID: id, sourceID: 0, seconds: seconds)
        }
    }
}
