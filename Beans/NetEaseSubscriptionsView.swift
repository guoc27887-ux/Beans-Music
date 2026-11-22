//
//  NetEaseSubscriptionsView.swift
//  Beans
//
//  网易云收藏专辑 / 关注歌手列表，移植自 MeloX
//  （https://github.com/youshen2/MeloX，GPL-3.0）。
//  原接口：MeloX/Core/Networking/NeteaseAPI+AlbumSubscriptions.swift、
//          NeteaseAPI+ArtistSubscriptions.swift（接口层见 NetEaseSocialAPI.swift）。
//  改动：列表直接复用 Beans 的 Album / Artist 模型与既有详情页
//  （AlbumDetailView / ArtistHomeSheet），不另建详情页。
//

import SwiftUI

struct NetEaseSubscribedAlbumsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore

    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedAlbum: Album?

    var body: some View {
        Group {
            if isLoading, albums.isEmpty {
                ProgressView("正在加载收藏专辑")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, albums.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if albums.isEmpty {
                EmptyStateView(icon: "square.stack", text: "还没有收藏的专辑")
            } else {
                List(albums) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(url: album.coverURL, size: 52, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.name)
                                    .font(BeansFont.appFont(15))
                                    .foregroundStyle(Color.beansLabel)
                                    .lineLimit(1)
                                Text(album.artistName)
                                    .font(BeansFont.appFont(12))
                                    .foregroundStyle(Color.beansComment)
                                    .lineLimit(1)
                                if !album.releaseCaption.isEmpty {
                                    Text(album.releaseCaption)
                                        .font(BeansFont.appFont(11))
                                        .foregroundStyle(Color.beansComment)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("收藏的专辑")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await NetEaseAPI.shared.subscribedAlbums()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct NetEaseFollowedArtistsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore

    @State private var artists: [Artist] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedArtist: Artist?

    var body: some View {
        Group {
            if isLoading, artists.isEmpty {
                ProgressView("正在加载关注歌手")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, artists.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else if artists.isEmpty {
                EmptyStateView(icon: "person.2", text: "还没有关注的歌手")
            } else {
                List(artists) { artist in
                    Button {
                        selectedArtist = artist
                    } label: {
                        HStack(spacing: 12) {
                            BeansAvatarView(remoteURL: artist.coverURL, size: 48)
                                .clipShape(Circle())
                            Text(artist.name)
                                .font(BeansFont.appFont(15))
                                .foregroundStyle(Color.beansLabel)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("关注的歌手")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $selectedArtist) { artist in
            ArtistHomeSheet(artist: artist)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            artists = try await NetEaseAPI.shared.subscribedArtists()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
