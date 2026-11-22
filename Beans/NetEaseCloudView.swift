//
//  NetEaseCloudView.swift
//  Beans
//
//  音乐云盘界面与状态，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Features/Cloud/CloudMusicView.swift、Core/Cloud/CloudMusicStore.swift。
//  改动：Observation 改为 Beans 通用的 ObservableObject；登录态以 AuthStore
//  为准（MeloX 以 Cookie 字符串变化作为刷新触发）；播放走 Beans PlayerManager；
//  行视图复用 Beans 的 CoverImage。
//  简化：MeloX 云盘页带页内搜索（搜索时自动补拉全部分页），本次未移植页内
//  搜索，其余分页 / 上传 / 删除 / 容量展示与原版一致。
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NetEaseCloudStore: ObservableObject {
    @Published private(set) var items: [NetEaseCloudSong] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var totalCount = 0
    @Published private(set) var usedSize: Int64 = 0
    @Published private(set) var maxSize: Int64 = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isUploading = false
    @Published var errorMessage: String?

    private var didLoad = false
    private let pageSize = 200

    var songs: [Song] { items.map(\.song) }

    var quotaDescription: String? {
        guard maxSize > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "已用 \(formatter.string(fromByteCount: usedSize)) / \(formatter.string(fromByteCount: maxSize))"
    }

    func refresh(force: Bool = false) async {
        guard force || !didLoad else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await NetEaseAPI.shared.cloudSongs(limit: pageSize)
            apply(page, replacing: true)
            didLoad = true
        } catch is CancellationError {
            return
        } catch {
            if items.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadMoreIfNeeded(after item: NetEaseCloudSong) async {
        guard item.id == items.last?.id else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await NetEaseAPI.shared.cloudSongs(limit: pageSize, offset: items.count)
            apply(page, replacing: false)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func upload(fileAt url: URL) async {
        guard !isUploading else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            try await NetEaseAPI.shared.uploadCloudSong(fileAt: url)
            didLoad = false
            await refresh(force: true)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "上传失败：\(error.localizedDescription)"
        }
    }

    func delete(_ item: NetEaseCloudSong) async {
        do {
            try await NetEaseAPI.shared.deleteCloudSong(id: item.songID)
            items.removeAll { $0.id == item.id }
            totalCount = max(totalCount - 1, 0)
            usedSize = max(usedSize - item.fileSize, 0)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func apply(_ page: NetEaseCloudPage, replacing: Bool) {
        if replacing {
            items = page.songs
        } else {
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: page.songs.filter { !existingIDs.contains($0.id) })
        }
        totalCount = page.count
        usedSize = page.size
        maxSize = page.maxSize
        hasMore = page.hasMore && items.count < page.count
    }
}

struct NetEaseCloudView: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var store = NetEaseCloudStore()

    @State private var showsFileImporter = false
    @State private var pendingDeletion: NetEaseCloudSong?

    var body: some View {
        content
            .navigationTitle("音乐云盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsFileImporter = true
                    } label: {
                        if store.isUploading {
                            ProgressView()
                        } else {
                            Label("上传音乐", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(store.isUploading)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await store.upload(fileAt: url) }
                case .failure(let error):
                    store.errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog(
                "从云盘删除这首歌？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { item in
                Button("删除「\(item.songName)」", role: .destructive) {
                    Task { await store.delete(item) }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("删除后将从网易云音乐云盘中移除，无法恢复。")
            }
            .alert(
                "云盘",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "未知错误")
            }
            .task {
                await store.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading, store.items.isEmpty {
            ProgressView("正在加载云盘")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage, store.items.isEmpty {
            ErrorStateView(message: error) {
                Task { await store.refresh(force: true) }
            }
        } else {
            cloudList
        }
    }

    private var cloudList: some View {
        List {
            if store.isUploading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在上传到云盘…")
                        .font(BeansFont.appFont(13))
                        .foregroundStyle(Color.beansComment)
                }
            }

            if !store.items.isEmpty {
                Section {
                    Button {
                        player.play(songs: store.songs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                } header: {
                    if let quota = store.quotaDescription {
                        Text(quota)
                    } else {
                        Text("共 \(store.totalCount) 首")
                    }
                }
            }

            ForEach(store.items) { item in
                Button {
                    if let index = store.items.firstIndex(where: { $0.id == item.id }) {
                        player.play(songs: store.songs, startAt: index)
                    }
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(url: item.song.coverURL, song: item.song, size: 44, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.songName)
                                .font(BeansFont.appFont(15))
                                .foregroundStyle(Color.beansLabel)
                                .lineLimit(1)
                            Text(item.artist)
                                .font(BeansFont.appFont(12))
                                .foregroundStyle(Color.beansComment)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(item.song.formattedDuration)
                            .font(BeansFont.appFont(12, .regular, .monospaced))
                            .foregroundStyle(Color.beansComment)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDeletion = item
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .task {
                    await store.loadMoreIfNeeded(after: item)
                }
            }

            if store.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.refresh(force: true)
        }
        .overlay {
            if store.items.isEmpty, !store.isUploading, !store.isLoading {
                EmptyStateView(icon: "externaldrive", text: "云盘里还没有歌曲，点右上角上传")
            }
        }
    }
}
