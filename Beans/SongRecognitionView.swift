//
//  SongRecognitionView.swift
//  Beans
//
//  听歌识曲界面，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Features/SongRecognition/SongRecognitionView.swift。
//  改动：环境注入改为 Beans 的 @EnvironmentObject / @StateObject；结果行
//  复用 Beans 的 CoverImage；收藏走 Beans 的 FavoritesStore；播放走
//  PlayerManager.play 后再 seek 到匹配位置（Beans 没有 MeloX 的
//  play(startAt:) 入参，这里用起播后跳转近似，属已知简化）。
//  时长偏好（3/6/9 秒与持续识别）在页内以菜单切换，不再单独占设置页。
//

import SwiftUI
import UIKit

struct SongRecognitionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var favorites = FavoritesStore.shared

    @StateObject private var recognition = SongRecognitionStore()
    @StateObject private var preferences = SongRecognitionPreferences()

    var body: some View {
        Group {
            switch recognition.phase {
            case .ready:
                readyView
            case .requestingPermission:
                progressView(
                    title: recognition.audioSource.preparationTitle,
                    description: recognition.audioSource.permissionMessage
                )
            case .listening:
                if recognition.isContinuous {
                    continuousListeningView
                } else {
                    listeningView
                }
            case .matching:
                progressView(title: "正在匹配", description: "正在与网易云曲库比对…")
            case .results:
                resultsView
            case .noMatch:
                noMatchView
            case .failed(let failure):
                failureView(failure)
            }
        }
        .navigationTitle("听歌识曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsRestartButton {
                ToolbarItem(placement: .primaryAction) {
                    Button("重新识别", systemImage: "arrow.clockwise", action: startRecognition)
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("识别时长", selection: $preferences.duration) {
                        ForEach(SongRecognitionDuration.allCases) { duration in
                            Text("\(duration.title) · \(duration.detail)").tag(duration)
                        }
                    }
                } label: {
                    Image(systemName: "timer")
                }
                .accessibilityLabel("识别时长")
            }
        }
        .onDisappear {
            recognition.cancel()
        }
    }

    private var readyView: some View {
        ContentUnavailableView {
            Label("听歌识曲", systemImage: "waveform")
        } description: {
            Text(readyDescription)
        } actions: {
            VStack(spacing: 14) {
                Picker("音频来源", selection: $preferences.audioSource) {
                    ForEach(SongRecognitionAudioSource.availableCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Button("开始识别", systemImage: preferences.audioSource.systemImage, action: startRecognition)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var listeningView: some View {
        VStack(spacing: 22) {
            Spacer()
            listeningSymbol
            VStack(spacing: 8) {
                Text("正在聆听")
                    .font(.title2.bold())
                Text(
                    recognition.audioSource == .microphone
                        ? "将手机靠近音源，聆听 \(preferences.duration.title)"
                        : recognition.audioSource.detail
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            Button("取消", role: .cancel) {
                recognition.cancel()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
    }

    private var continuousListeningView: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    listeningSymbol
                    VStack(spacing: 6) {
                        Text("持续识别中")
                            .font(.title3.bold())
                        Text("保持页面打开，识别到的歌曲会持续累积")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("停止", role: .cancel) {
                        recognition.stopContinuousRecognition()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowSeparator(.hidden)
            }

            if !recognition.results.isEmpty {
                Section("识别结果") {
                    ForEach(recognition.results) { result in
                        recognitionResultRow(result)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var resultsView: some View {
        List {
            Section("识别结果") {
                ForEach(recognition.results) { result in
                    recognitionResultRow(result)
                }
            }
        }
        .listStyle(.plain)
    }

    private var listeningSymbol: some View {
        Image(systemName: "waveform")
            .font(.system(size: 64, weight: .medium))
            .foregroundStyle(.tint)
            .symbolEffect(
                .variableColor.iterative,
                options: .repeating.speed(1.2),
                isActive: !reduceMotion
            )
            .accessibilityHidden(true)
    }

    private func recognitionResultRow(_ result: SongRecognitionResult) -> some View {
        Button {
            play(result)
        } label: {
            HStack(spacing: 12) {
                CoverImage(url: result.song.coverURL, song: result.song, size: 44, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.song.name)
                        .font(BeansFont.appFont(15))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(result.song.artists)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle")
                    .foregroundStyle(Color.beansComment)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button {
                Task { await favorites.toggle(result.song) }
            } label: {
                Label(
                    favorites.isLiked(result.song) ? "取消收藏" : "收藏",
                    systemImage: favorites.isLiked(result.song) ? "heart.slash" : "heart"
                )
            }
            .tint(.pink)
        }
    }

    private var noMatchView: some View {
        ContentUnavailableView {
            Label("未识别到歌曲", systemImage: "questionmark.circle")
        } description: {
            Text("没有匹配到结果，换个位置或靠近音源再试一次")
        } actions: {
            Button("再试一次", systemImage: "arrow.clockwise", action: startRecognition)
                .buttonStyle(.borderedProminent)
        }
    }

    private func failureView(_ failure: SongRecognitionFailure) -> some View {
        ContentUnavailableView {
            Label("识别失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            if failure.opensSystemSettings, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("打开系统设置", systemImage: "gear") {
                    openURL(settingsURL)
                }
                .buttonStyle(.borderedProminent)

                Button("重试", systemImage: "arrow.clockwise", action: startRecognition)
                    .buttonStyle(.bordered)
            } else {
                Button("重试", systemImage: "arrow.clockwise", action: startRecognition)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func progressView(title: String, description: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("取消", role: .cancel) {
                recognition.cancel()
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsRestartButton: Bool {
        switch recognition.phase {
        case .results, .noMatch, .failed: return true
        case .ready, .requestingPermission, .listening, .matching: return false
        }
    }

    private var readyDescription: String {
        let duration = preferences.duration
        if preferences.audioSource != .microphone {
            let timing = duration.isContinuous
                ? "将持续捕获并识别"
                : "将捕获 \(duration.title)"
            return preferences.audioSource.detail + "\n" + timing
        }
        if duration.isContinuous {
            return "持续聆听周围的音乐并累积识别结果"
        }
        return "聆听周围的音乐 \(duration.title)，识别正在播放的歌曲"
    }

    private func play(_ result: SongRecognitionResult) {
        recognition.prepareForResultPlayback()
        let songs = recognition.results.map(\.song)
        let index = songs.firstIndex { $0.id == result.song.id } ?? 0
        player.play(songs: songs, startAt: index)
        if result.playbackPosition > 1 {
            let position = result.playbackPosition
            Task { @MainActor in
                // 等待起播完成后再跳到匹配位置，避免被加载流程覆盖。
                try? await Task.sleep(nanoseconds: 800_000_000)
                player.seekPrecisely(to: position)
            }
        }
    }

    private func startRecognition() {
        if preferences.audioSource == .microphone, player.isPlaying {
            player.togglePlayPause()
        }
        recognition.start(
            duration: preferences.duration,
            source: preferences.audioSource
        )
    }
}
