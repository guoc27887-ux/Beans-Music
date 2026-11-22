import SwiftUI

/// iOS 18 兼容垫片：为 iOS 26 的液态玻璃与工具栏 API 提供 iOS 18 降级实现。
/// 所有垫片在 iOS 26 上保持原生行为不变，仅在 iOS 18 上走降级分支。

// MARK: - GlassEffectContainer

/// iOS 26 使用原生 GlassEffectContainer；iOS 18 直接呈现内容，
/// 子视图自身的背景材质负责外观。
struct GlassEffectContainerCompat<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Glass button styles

extension View {
    /// iOS 26 使用 .glass / .glassProminent；iOS 18 降级为系统描边按钮样式。
    @ViewBuilder
    func glassButtonStyleCompat(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// iOS 26 的 scrollEdgeEffectStyle 在 iOS 18 上无对应效果，直接省略。
    @ViewBuilder
    func scrollEdgeEffectStyleSoftCompat(for edges: Edge.Set) -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// iOS 26 的 tabBarMinimizeBehavior(.never) 在 iOS 18 上无需设置。
    @ViewBuilder
    func tabBarMinimizeBehaviorNeverCompat() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }

    /// iOS 26 的 safeAreaBar 在 iOS 18 上用 safeAreaInset 实现相同布局。
    @ViewBuilder
    func safeAreaBarCompat<BarContent: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> BarContent
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            self.safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }
}

// MARK: - Toolbar shared background visibility

extension ToolbarContent {
    /// iOS 26 的 sharedBackgroundVisibility 在 iOS 18 上省略（工具栏背景保持默认）。
    @ToolbarContentBuilder
    func sharedBackgroundVisibilityCompat(_ visibility: Visibility) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(visibility)
        } else {
            self
        }
    }
}
