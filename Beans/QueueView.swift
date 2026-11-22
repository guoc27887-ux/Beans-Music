import SwiftUI

/// 经典播放器使用的原始播放队列列表。
struct QueueView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @AppStorage("beans.queueOverlayPresented") private var queueOverlayPresented = false

    var body: some View {
        let _ = theme.accent
        BeansNavigationStack {
            Group {
                if player.queue.isEmpty {
                    EmptyStateView(icon: "music.note.list", text: "播放队列为空")
                } else {
                    let songs = player.queue
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text("接下来 (\(songs.count) 首)")
                                .font(BeansFont.appFont(13, .semibold))
                                .foregroundStyle(Color.beansComment)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            // 使用位置索引而不是歌曲 identityKey。播放队列允许同一首歌
                            // 重复出现，低系统的 SwiftUI List 在重复 ID 下容易直接崩溃。
                            // LazyVStack 只实例化可见行：旧实现是普通 VStack，上百行
                            // 全部常驻，滚动时整表参与布局与合成，严重掉帧。
                            // 原先挂在这里的 .swipeActions 只在 List 行上生效，
                            // 在 VStack 里是死代码，已随本次重构移除（移除功能走行内
                            // contextMenu，一直都在）。
                            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                                QueueRowView(
                                    song: song,
                                    index: index,
                                    isCurrent: index == player.currentIndex,
                                    isPlaying: player.isPlaying,
                                    onTap: {
                                        guard player.queue.indices.contains(index) else { return }
                                        player.playQueueIndex(index)
                                    },
                                    onRemove: {
                                        guard player.queue.indices.contains(index) else { return }
                                        player.removeFromQueue(at: index)
                                    }
                                )
                                .equatable()
                                .padding(.horizontal, 8)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .beansScrollContentBackgroundHidden()
                    .background(LinearGradient.beansBackdrop)
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            player.clearQueue()
                        } label: {
                            Label("清空队列", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { queueOverlayPresented = true }
        .onDisappear { queueOverlayPresented = false }
    }
}

/// 队列单行。只依赖 (song, index, isCurrent, isPlaying) 四个值输入并实现
/// Equatable：PlayerManager 的常规发布（缓冲状态翻转、切歌、睡眠定时器等）
/// 让 QueueView 重算时，只有真正受影响的行才重算 body，其余行被 Equatable
/// 短路。旧实现是 QueueView 内部的 row() 函数，上百行随每次发布整表重建，
/// 是长队列滚动掉帧的主因之一。闭包只捕获 EnvironmentObject 单例与 index，
/// 而 index 已参与相等比较，相等判断忽略闭包本身是安全的。
private struct QueueRowView: View, Equatable {
    let song: Song
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    static func == (lhs: QueueRowView, rhs: QueueRowView) -> Bool {
        lhs.index == rhs.index
            && lhs.song == rhs.song
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isPlaying == rhs.isPlaying
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 42pt 显示只需 126px（@3x）位图：按上限解码，避免原图
                // 全尺寸位图在快速滚动时逐行解码与上传纹理。
                CoverImage(url: song.coverURL, song: song, size: 42, cornerRadius: 9, decodeMaxPixelSize: 126)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(BeansFont.appFont(15, isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.beansAmber : Color.beansLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(song.artists)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    if isPlaying {
                        NowPlayingIndicator()
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.beansAmber)
                    }
                } else {
                    Text(song.formattedDuration)
                        .font(BeansFont.appFont(12, .regular, .monospaced))
                        .foregroundStyle(Color.beansComment)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("移除", systemImage: "trash")
            }
        }
    }
}

/// 只允许从右侧手柄开始排序，避免整行点击和多个歌曲同时响应拖动。
struct QueueReorderHandle: View {
    let position: Int
    let maxPosition: Int
    let rowStep: CGFloat
    let onMove: (Int, Int) -> Void
    let onCommit: () -> Void

    @State private var originPosition: Int?
    @State private var lastPosition: Int?
    @State private var isDragging = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.beansComment.opacity(0.78))
            .frame(width: 38, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("长按并拖动调整顺序")
            .gesture(queueDragGesture)
    }

    private var queueDragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.34)
            .sequenced(before: DragGesture(minimumDistance: 4))
            .onChanged { value in
                switch value {
                case .first(true):
                    guard originPosition == nil else { return }
                    originPosition = position
                    lastPosition = position
                    isDragging = true
                    BeansHaptics.medium()
                case .second(true, let drag?):
                    guard let origin = originPosition, let last = lastPosition else { return }
                    let rawOffset = drag.translation.height / rowStep
                    let slotOffset = CGFloat(last - origin)
                    let hysteresis: CGFloat = 0.60
                    let next: Int
                    if rawOffset > slotOffset + hysteresis {
                        next = min(last + 1, maxPosition)
                    } else if rawOffset < slotOffset - hysteresis {
                        next = max(last - 1, 0)
                    } else {
                        return
                    }
                    guard next != last else { return }

                    // Move one slot per update with hysteresis. The dead zone
                    // prevents two adjacent rows from bouncing at the boundary.
                    // 恢复最初的即时换位，避免长按排序时动画堆积、掉帧和相邻项抖动。
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        onMove(last, next)
                    }
                    lastPosition = next
                    BeansHaptics.tap()
                default:
                    break
                }
            }
            .onEnded { _ in
                guard isDragging else { return }
                onCommit()
                originPosition = nil
                lastPosition = nil
                isDragging = false
            }
    }
}
