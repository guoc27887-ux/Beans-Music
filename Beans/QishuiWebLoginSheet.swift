import SwiftUI
import WebKit

// MARK: - 汽水官方网页登录（应用内打开 qishui.com 官方登录，登录后读取 Cookie）
// 原理：WKWebView 打开汽水官网，页面自带官方登录 SDK（扫码 / 手机号，
// 签名与风控都由官方 JS 处理），用户在页面内完成登录后，登录态 Cookie
// （sessionid / sid_tt 等）写入 WKWebView 默认 Cookie 存储，应用读取
// 这些 Cookie 存进 QishuiMusicAuth 即完成登录。
// 背景：第三方 check_qrconnect 轮询在扫码确认后会被服务端限频
// （error_code 7「访问太频繁」）锁死数分钟，会话 Cookie 拿不到；
// 官方页面自己的轮询带签名，不受此限（2026-11-23 对照实验实证）。

struct QishuiWebLoginPanel: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    let onSuccess: () -> Void

    @State private var pageLoaded = false
    @State private var syncing = false
    @State private var message = ""
    @State private var finished = false

    var body: some View {
        let _ = theme.accent
        VStack(spacing: 10) {
            Text("在下方汽水官方网页中点右上角「登录」，用汽水 App 扫码或手机号完成登录，登录成功后会自动同步")
                .font(BeansFont.appFont(12))
                .foregroundStyle(Color.beansComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            ZStack {
                QishuiWebView(onLoaded: { pageLoaded = true })
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.horizontal, 20)

                if !pageLoaded {
                    ProgressView("正在加载汽水音乐…")
                        .tint(Color.beansAmber)
                }
            }
            .frame(maxHeight: .infinity)

            if !message.isEmpty {
                Text(message)
                    .font(BeansFont.appFont(12))
                    .foregroundStyle(message.hasPrefix("✓") ? Color.beansSage : Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button {
                syncNow()
            } label: {
                HStack(spacing: 6) {
                    if syncing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncing ? "正在读取登录状态…" : "同步登录状态")
                }
                .font(BeansFont.appFont(14, .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.beansAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .disabled(syncing)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
            // 自动检测：登录态 Cookie 一出现就直接完成，不必手动点同步。
            if !finished {
                readCookies { header in
                    if let header {
                        finish(header: header)
                    }
                }
            }
        }
    }

    // MARK: - 同步登录态

    private func syncNow() {
        syncing = true
        message = ""
        readCookies { header in
            syncing = false
            guard let header else {
                message = "未检测到有效登录态，请先在网页中完成汽水登录"
                return
            }
            finish(header: header)
        }
    }

    private func finish(header: String) {
        guard !finished else { return }
        finished = true
        message = "✓ 汽水登录成功，正在同步…"
        BeansHaptics.success()
        ToastCenter.shared.show("汽水登录成功")
        QishuiMusicAuth.shared.saveLogin(cookie: header)
        Task {
            await QishuiAPI.shared.refreshProfile()
            await MainActor.run {
                dismiss()
                onSuccess()
            }
        }
    }

    /// 从 WKWebView 默认 Cookie 存储读取汽水登录态 Cookie，合并成请求头；
    /// 没有会话 Cookie（sessionid / sid_tt 等）时返回 nil。
    private func readCookies(_ completion: @escaping (String?) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var pairs: [String] = []
            var seen = Set<String>()
            for cookie in cookies where cookie.domain.contains("qishui.com") {
                guard seen.insert(cookie.name).inserted else { continue }
                pairs.append("\(cookie.name)=\(cookie.value)")
            }
            let header = pairs.joined(separator: "; ")
            DispatchQueue.main.async {
                completion(QishuiAPI.hasSessionCookie(header) ? header : nil)
            }
        }
    }
}

// MARK: - WKWebView 封装（打开汽水官网）

struct QishuiWebView: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://www.qishui.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.onLoaded()
            }
        }
    }
}
