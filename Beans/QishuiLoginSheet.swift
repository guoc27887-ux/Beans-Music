import SwiftUI

/// 汽水音乐扫码登录：passport get_qrcode + check_qrconnect 轮询，
/// 布局与状态机跟随网易云 LoginView 的既有样式。
struct QishuiLoginSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var session: QishuiQRCodeSession?
    @State private var status: QRStatus = .loading
    @State private var timer: Timer?

    var body: some View {
        let _ = theme.accent
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            VStack(spacing: 22) {
                Spacer()
                Image("BrandQishui")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("汽水音乐")
                    .font(BeansFont.appFont(30, .bold))
                    .foregroundStyle(Color.beansLabel)
                Text("使用汽水音乐或抖音 App 扫码登录，同步你的歌单")
                    .font(BeansFont.appFont(14))
                    .foregroundStyle(Color.beansComment)
                    .multilineTextAlignment(.center)

                qrArea
                    .frame(width: 250, height: 250)
                    .padding(18)
                    .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 30, style: .continuous)) }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)

                statusView

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onAppear { startLogin() }
        .onDisappear { timer?.invalidate() }
    }

    @ViewBuilder
    private var qrArea: some View {
        ZStack {
            if let session {
                if let data = session.qrImageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                } else {
                    QRCodeView(text: session.qrContent)
                }
            } else {
                ProgressView().tint(Color.beansAmber)
            }
            if status == .expired || isError {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 34))
                    Text(isError ? errorText : "二维码已过期")
                        .font(BeansFont.appFont(13))
                    GlassButton(title: "刷新", systemName: "arrow.clockwise", prominent: true) {
                        startLogin()
                    }
                }
                .foregroundStyle(Color.beansLabel)
                .frame(width: 210, height: 210)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var statusView: some View {
        Group {
            switch status {
            case .loading:
                Text("正在生成二维码…")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            case .waiting:
                Label("请使用汽水音乐或抖音 App 扫码", systemImage: "qrcode.viewfinder")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            case .scanned:
                Label("已扫码，请在手机上确认登录", systemImage: "checkmark.circle")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansSage)
            case .success:
                Label("登录成功，正在同步歌单…", systemImage: "checkmark.seal.fill")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansSage)
            case .expired:
                Text("二维码已过期")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
            case .error(let message):
                Text(message)
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(height: 44)
    }

    private var isError: Bool {
        if case .error = status { return true }
        return false
    }

    private var errorText: String {
        if case .error(let message) = status { return message }
        return ""
    }

    // MARK: - 登录流程

    private func startLogin() {
        timer?.invalidate()
        timer = nil
        session = nil
        status = .loading
        Task {
            do {
                let created = try await QishuiAPI.shared.createQRCode()
                await MainActor.run {
                    session = created
                    status = .waiting
                    startPolling()
                }
            } catch {
                await MainActor.run {
                    status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startPolling() {
        // check_qrconnect 有限频（error_code 7），轮询间隔保持 2.5 秒。
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            guard let session else { return }
            Task {
                do {
                    let result = try await QishuiAPI.shared.checkQRCode(session: session)
                    await MainActor.run {
                        handle(result)
                    }
                } catch {
                    // 网络抖动：跳过本次轮询，等待下一次
                }
            }
        }
    }

    private func handle(_ result: QishuiQRCodeStatus) {
        switch result {
        case .waiting:
            break
        case .scanned:
            status = .scanned
        case .expired:
            timer?.invalidate()
            timer = nil
            status = .expired
        case .verifyRequired:
            timer?.invalidate()
            timer = nil
            status = .error("账号触发了短信验证，本版本暂不支持，请稍后再试")
        case .failed(let message):
            timer?.invalidate()
            timer = nil
            status = .error(message)
        case .success(let cookie):
            timer?.invalidate()
            timer = nil
            status = .success
            QishuiMusicAuth.shared.saveLogin(cookie: cookie)
            Task {
                await QishuiAPI.shared.refreshProfile()
                await MainActor.run { dismiss() }
            }
        }
    }
}
