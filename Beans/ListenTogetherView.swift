//
//  ListenTogetherView.swift
//  Beans
//
//  一起听界面，移植自 MeloX（https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Features/ListenTogether/ListenTogetherView.swift、
//          ListenTogetherMemberViews.swift、ListenTogetherSyncStatusView.swift
//  改动：Observation 环境注入改为 Beans 通用的 @EnvironmentObject；
//        文案改为中文字面量；封面/歌手信息改用 Beans 的 Song 字段；
//        材质全部使用普通 SwiftUI 材质（无液态玻璃等 iOS 26 接口）。
//

import SwiftUI

struct ListenTogetherView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var listenTogether: ListenTogetherStore

    @State private var invitationText = ""
    @State private var showsLeaveConfirmation = false

    /// 剪贴板识别到一起听邀请时预填邀请文本，其余入口保持默认空。
    init(invitationText: String = "") {
        _invitationText = State(initialValue: invitationText)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let room = listenTogether.room {
                    activeRoomContent(room)
                } else {
                    inactiveContent
                }
            }
            .navigationTitle("一起听")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                    .disabled(listenTogether.operation == .leaving)
                }

                if let operation = listenTogether.operation {
                    ToolbarItem(placement: .primaryAction) {
                        ProgressView()
                            .accessibilityLabel(operation.title)
                    }
                }
            }
            .disabled(listenTogether.isBusy)
            .confirmationDialog(
                listenTogether.isHost ? "结束一起听？" : "离开一起听？",
                isPresented: $showsLeaveConfirmation
            ) {
                Button(
                    listenTogether.isHost ? "结束一起听" : "离开房间",
                    role: .destructive
                ) {
                    Task {
                        await listenTogether.leaveRoom()
                    }
                }
            } message: {
                Text(
                    listenTogether.isHost
                        ? "你是房主，结束后所有成员都会离开房间。"
                        : "离开后可凭邀请链接重新加入。"
                )
            }
            .alert(
                "一起听出错",
                isPresented: Binding(
                    get: { listenTogether.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            listenTogether.dismissError()
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {
                    listenTogether.dismissError()
                }
            } message: {
                Text(listenTogether.errorMessage ?? "操作未完成")
            }
        }
    }

    @ViewBuilder
    private var inactiveContent: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                Text("和朋友一起听")
                    .font(.title3.weight(.semibold))

                Text("创建房间或加入朋友的房间，播放、暂停、切歌和进度都会实时同步。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
        }

        if auth.isLoggedIn {
            Section {
                Button {
                    Task {
                        await listenTogether.createRoom()
                    }
                } label: {
                    Label("开始一起听", systemImage: "person.2.badge.plus")
                }
                .disabled(!canCreateRoom)
            } header: {
                Text("创建房间")
            } footer: {
                if player.currentSong == nil {
                    Text("先播放一首歌再开始一起听")
                } else if player.currentSong?.source != .netease {
                    Text("一起听仅支持网易云歌曲，请先播放一首网易云的歌")
                } else {
                    Text("以当前歌曲和播放队列创建房间，再把邀请链接发给朋友。")
                }
            }

            Section {
                TextField(
                    "粘贴邀请链接",
                    text: $invitationText,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button {
                    Task {
                        await listenTogether.joinRoom(
                            invitationText: invitationText
                        )
                    }
                } label: {
                    Label("加入房间", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(
                    invitationText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            } header: {
                Text("加入房间")
            } footer: {
                Text("邀请链接里需要包含房间 ID 和邀请人 ID。")
            }
        } else {
            Section {
                ContentUnavailableView {
                    Label("需要登录网易云", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("一起听使用网易云官方房间服务，登录后才能创建或加入房间。")
                }
            }
        }
    }

    private var canCreateRoom: Bool {
        guard let song = player.currentSong else { return false }
        return song.source == .netease
    }

    @ViewBuilder
    private func activeRoomContent(
        _ room: ListenTogetherRoom
    ) -> some View {
        Section("正在播放") {
            if let song = player.currentSong {
                HStack(spacing: 12) {
                    AsyncImage(url: song.coverURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(song.artists)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            } else {
                Label("等待播放同步", systemImage: "music.note")
                    .foregroundStyle(.secondary)
            }
        }

        Section("同步状态") {
            ListenTogetherSyncStatusView()
        }

        Section {
            ListenTogetherMemberRows(room: room)
        } header: {
            Text("房间成员")
        } footer: {
            Text("当前 \(room.users.count) 人在线")
        }

        Section {
            LabeledContent("房间 ID", value: room.id)
                .textSelection(.enabled)

            if let invitationURL = listenTogether.invitationURL {
                ShareLink(
                    item: invitationURL,
                    subject: Text("一起来听歌"),
                    message: Text("我在 Beans 开了一起听房间，点链接加入：")
                ) {
                    Label("邀请朋友", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("邀请")
        } footer: {
            Text("朋友打开链接或把链接粘贴到一起听页面即可加入。")
        }

        Section {
            Button(
                listenTogether.isHost ? "结束一起听" : "离开房间",
                systemImage: "rectangle.portrait.and.arrow.right",
                role: .destructive
            ) {
                showsLeaveConfirmation = true
            }
        }
    }
}

// MARK: - 同步状态（原 ListenTogetherSyncStatusView）

struct ListenTogetherSyncStatusView: View {
    @EnvironmentObject private var listenTogether: ListenTogetherStore

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                statusIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(listenTogether.isHost ? "房主" : "成员")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        statusColor.opacity(0.12),
                        in: Capsule()
                    )
            }

            Divider()

            HStack(spacing: 12) {
                lastSyncLabel

                Spacer()

                Button {
                    refresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("同步中")
                    } else {
                        Label("立即同步", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
            }
            .font(.footnote)
        }
        .padding(.vertical, 5)
        .animation(
            .default,
            value: listenTogether.connectionState
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.14))

            if listenTogether.connectionState == .reconnecting {
                ProgressView()
                    .tint(statusColor)
                    .controlSize(.small)
            } else {
                Image(systemName: statusSystemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var lastSyncLabel: some View {
        if let lastSyncDate = listenTogether.lastSyncDate {
            Label {
                HStack(spacing: 3) {
                    Text("上次同步")
                    Text(lastSyncDate, style: .relative)
                }
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.secondary)
        } else {
            Label("等待首次同步", systemImage: "clock")
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch listenTogether.connectionState {
        case .idle:
            "正在准备同步"
        case .connected:
            "播放已同步"
        case .reconnecting:
            "正在恢复连接"
        }
    }

    private var statusDetail: String {
        switch listenTogether.connectionState {
        case .idle:
            "正在读取房间播放状态"
        case .connected:
            "房间内任何人的播放、暂停、切歌都会同步到所有人"
        case .reconnecting:
            "网络或服务器暂时无响应，正在自动重试"
        }
    }

    private var statusSystemImage: String {
        switch listenTogether.connectionState {
        case .idle:
            "clock"
        case .connected:
            "checkmark"
        case .reconnecting:
            "arrow.clockwise"
        }
    }

    private var statusColor: Color {
        switch listenTogether.connectionState {
        case .idle:
            .secondary
        case .connected:
            .green
        case .reconnecting:
            .orange
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            await listenTogether.refresh()
            isRefreshing = false
        }
    }
}

// MARK: - 成员列表（原 ListenTogetherMemberViews）

struct ListenTogetherMemberRows: View {
    let room: ListenTogetherRoom

    @ViewBuilder
    var body: some View {
        if room.users.isEmpty {
            Label("正在加载成员", systemImage: "person.2")
                .foregroundStyle(.secondary)
        } else {
            ForEach(room.users) { user in
                ListenTogetherMemberRow(
                    user: user,
                    isHost: user.id == room.creatorID
                )
            }
        }
    }
}

private struct ListenTogetherMemberRow: View {
    let user: ListenTogetherUser
    let isHost: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: user.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Circle())
            .accessibilityHidden(true)

            Text(user.nickname)
                .lineLimit(1)

            Spacer()

            if isHost {
                Text("房主")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
