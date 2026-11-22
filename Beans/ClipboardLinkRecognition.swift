//
//  ClipboardLinkRecognition.swift
//  Beans
//
//  剪贴板网易云链接识别，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/App/ClipboardLinkRecognition.swift、Core/Links/NeteaseMusicLink.swift。
//  改动：MeloX 只识别歌曲与一起听邀请，这里按 Beans 的导航能力扩展到
//  歌单 / 专辑；打开歌曲改为直接起播（Beans 没有独立歌曲详情页）；
//  一起听邀请复用 Beans 已移植的 ListenTogetherView 并预填邀请文本。
//  隐私处理（对齐 MeloX 的克制做法并加强）：
//   - 仅在 scenePhase 回到 .active 时检查，且以 UIPasteboard.changeCount
//     为闸门：剪贴板内容没变过就不重复检查、更不重复弹窗（处理过的水位
//     持久化在 UserDefaults）。
//   - 先用系统模式检测（detectPatterns [.probableWebURL]）确认剪贴板里
//     大概率有网址，才真正读取字符串内容，避免无谓读取与系统粘贴提示滥用。
//   - 命中后只弹窗询问，用户点「打开」才跳转，忽略即不再打扰（同一内容
//     不会二次弹窗）。
//

import SwiftUI
import UIKit

enum BeansMusicLink: Hashable, Identifiable {
    case song(id: Int)
    case playlist(id: Int)
    case album(id: Int)
    case listenTogether(invitationText: String, roomID: String)

    var id: String {
        switch self {
        case .song(let id): return "song-\(id)"
        case .playlist(let id): return "playlist-\(id)"
        case .album(let id): return "album-\(id)"
        case .listenTogether(_, let roomID): return "listen-together-\(roomID)"
        }
    }

    var promptTitle: String {
        switch self {
        case .song: return "检测到歌曲链接"
        case .playlist: return "检测到歌单链接"
        case .album: return "检测到专辑链接"
        case .listenTogether: return "检测到一起听邀请"
        }
    }

    var promptMessage: String {
        switch self {
        case .song: return "剪贴板里有一首网易云歌曲，是否打开并播放？"
        case .playlist: return "剪贴板里有一个网易云歌单，是否打开？"
        case .album: return "剪贴板里有一张网易云专辑，是否打开？"
        case .listenTogether: return "剪贴板里有一条一起听邀请，是否查看？"
        }
    }

    var actionTitle: String {
        switch self {
        case .song: return "播放歌曲"
        case .playlist: return "打开歌单"
        case .album: return "打开专辑"
        case .listenTogether: return "查看邀请"
        }
    }
}

enum BeansMusicLinkParser {
    static func parse(_ text: String) -> BeansMusicLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for url in detectedURLs(in: trimmed) where isNeteaseURL(url) {
            if isListenTogetherURL(url),
               let invitation = try? ListenTogetherInvitation(text: trimmed) {
                return .listenTogether(invitationText: trimmed, roomID: invitation.roomID)
            }
            if let id = resourceID(from: url, paths: ["/song", "/m/song"]) {
                return .song(id: id)
            }
            if let id = resourceID(from: url, paths: ["/playlist", "/m/playlist"]) {
                return .playlist(id: id)
            }
            if let id = resourceID(from: url, paths: ["/album", "/m/album"]) {
                return .album(id: id)
            }
        }
        return nil
    }

    private static func detectedURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return URL(string: text).map { [$0] } ?? []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var urls = detector.matches(in: text, options: [], range: range).compactMap(\.url)

        if let directURL = URL(string: text), !urls.contains(directURL) {
            urls.append(directURL)
        }
        return urls
    }

    private static func isNeteaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "music.163.com" || host.hasSuffix(".music.163.com")
    }

    private static func isListenTogetherURL(_ url: URL) -> Bool {
        url.path.lowercased().contains("/listen-together/")
            || (url.query?.localizedCaseInsensitiveContains("roomId=") ?? false)
    }

    /// 同时支持 music.163.com/song?id= 与 music.163.com/#/song?id= 两种形态。
    private static func resourceID(from url: URL, paths: [String]) -> Int? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        if paths.contains(components.path.lowercased()),
           let id = positiveID(in: components.queryItems ?? []) {
            return id
        }

        guard let fragment = components.fragment else { return nil }
        let fragmentPath = fragment.hasPrefix("/") ? fragment : "/\(fragment)"
        guard let fragmentComponents = URLComponents(string: "https://music.163.com\(fragmentPath)"),
              paths.contains(fragmentComponents.path.lowercased()) else {
            return nil
        }
        return positiveID(in: fragmentComponents.queryItems ?? [])
    }

    private static func positiveID(in queryItems: [URLQueryItem]) -> Int? {
        guard let value = queryItems.first(where: {
            $0.name.caseInsensitiveCompare("id") == .orderedSame
        })?.value,
              let id = Int(value),
              id > 0 else {
            return nil
        }
        return id
    }
}

struct BeansClipboardLinkModifier: ViewModifier {
    let player: PlayerManager
    let auth: AuthStore
    let theme: ThemeStore
    let listenTogether: ListenTogetherStore

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("beans.clipboard.lastHandledChangeCount") private var lastHandledChangeCount = -1

    @State private var detectedLink: BeansMusicLink?
    @State private var listenTogetherItem: ListenTogetherInvitationItem?
    @State private var isOpening = false
    @State private var errorMessage: String?
    @State private var sheetPlaylist: Playlist?
    @State private var sheetAlbum: Album?

    func body(content: Content) -> some View {
        content
            .task {
                inspectClipboard()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                inspectClipboard()
            }
            .alert(
                detectedLink?.promptTitle ?? "检测到链接",
                isPresented: detectedLinkPresented
            ) {
                if let link = detectedLink {
                    Button(link.actionTitle) {
                        open(link)
                    }
                }
                Button("忽略", role: .cancel) {}
            } message: {
                Text(detectedLink?.promptMessage ?? "")
            }
            .alert(
                "打开失败",
                isPresented: errorPresented
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请稍后再试")
            }
            .sheet(item: $listenTogetherItem) { item in
                ListenTogetherView(invitationText: item.text)
                    .environmentObject(player)
                    .environmentObject(auth)
                    .environmentObject(theme)
                    .environmentObject(listenTogether)
            }
            .sheet(item: $sheetPlaylist) { playlist in
                PlaylistView(playlist: playlist)
                    .environmentObject(player)
                    .environmentObject(auth)
                    .environmentObject(theme)
            }
            .sheet(item: $sheetAlbum) { album in
                AlbumDetailView(album: album)
                    .environmentObject(player)
                    .environmentObject(theme)
            }
            .overlay {
                if isOpening {
                    ProgressView("正在打开…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
    }

    private var detectedLinkPresented: Binding<Bool> {
        Binding(
            get: { detectedLink != nil },
            set: { if !$0 { detectedLink = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func inspectClipboard() {
        guard scenePhase == .active, detectedLink == nil else { return }
        let board = UIPasteboard.general
        let changeCount = board.changeCount
        guard changeCount != lastHandledChangeCount else { return }

        // 先用系统模式检测确认大概率有网址，再读字符串，避免无谓读取。
        board.detectPatterns(for: [UIPasteboard.DetectionPattern.probableWebURL]) { result in
            switch result {
            case .success(let patterns):
                guard patterns.contains(.probableWebURL) else {
                    Task { @MainActor in lastHandledChangeCount = changeCount }
                    return
                }
                Task { @MainActor in
                    lastHandledChangeCount = changeCount
                    guard let text = UIPasteboard.general.string,
                          let link = BeansMusicLinkParser.parse(text) else {
                        return
                    }
                    detectedLink = link
                }
            case .failure:
                return
            }
        }
    }

    private func open(_ link: BeansMusicLink) {
        switch link {
        case .song(let id):
            openSong(id: id)
        case .playlist(let id):
            openPlaylist(id: id)
        case .album(let id):
            openAlbum(id: id)
        case .listenTogether(let invitationText, _):
            listenTogetherItem = ListenTogetherInvitationItem(text: invitationText)
        }
    }

    private func openSong(id: Int) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                let songs = try await NetEaseAPI.shared.songDetails(ids: [id])
                guard let song = songs.first else {
                    throw NetEaseError.unknown("未找到这首歌曲")
                }
                player.play(songs: [song], startAt: 0)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openPlaylist(id: Int) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                guard let playlist = try await NetEaseAPI.shared.playlistInfo(id: id) else {
                    throw NetEaseError.unknown("未找到这个歌单")
                }
                sheetPlaylist = playlist
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openAlbum(id: Int) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            // 先取专辑字典补全名称/封面，失败则用占位专辑直接打开详情页。
            if let json = try? await NetEaseAPI.shared.request("/api/v1/album/\(id)", payload: [:], crypto: "weapi"),
               let albumDict = json["album"] as? [String: Any],
               let album = NetEaseAlbumMapping.album(from: albumDict) {
                sheetAlbum = album
            } else {
                sheetAlbum = Album(
                    id: "netease-\(id)",
                    name: "专辑",
                    artistName: "",
                    coverURL: nil,
                    source: .netease
                )
            }
        }
    }
}

struct ListenTogetherInvitationItem: Identifiable {
    let text: String
    var id: String { text }
}
