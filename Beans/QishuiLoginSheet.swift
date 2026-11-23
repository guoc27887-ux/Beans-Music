import SwiftUI

/// 汽水音乐扫码登录：passport get_qrcode + check_qrconnect 轮询，
/// 布局与状态机跟随网易云 LoginView 的既有样式。
struct QishuiLoginSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var session: QishuiQRCodeSession?
    @State private var status: QRStatus = .loading
    @State private var timer: Timer?

    // 扫码后短信验证（MFA）的界面状态
    @State private var mfaChallenge: QishuiMFAChallenge?
    @State private var mfaUseUpSMS = false
    @State private var mfaCode = ""
    @State private var mfaMobile = ""
    @State private var mfaRetrySeconds = 0
    @State private var mfaBusy = false
    @State private var mfaError: String?
    @State private var showWebLogin = false

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

                if let challenge = mfaChallenge {
                    mfaView(challenge)
                } else {
                    qrArea
                        .frame(width: 250, height: 250)
                        .padding(18)
                        .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 30, style: .continuous)) }
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)

                    statusView

                    Button {
                        showWebLogin = true
                    } label: {
                        Label("扫码登不上？用官方网页登录", systemImage: "globe")
                            .font(BeansFont.appFont(13, .semibold))
                            .foregroundStyle(Color.beansSage)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background { BeansSurface(shape: Capsule()) }
                            .clipShape(Capsule())
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                }

                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onAppear { startLogin() }
        .onDisappear { timer?.invalidate() }
        .sheet(isPresented: $showWebLogin) {
            QishuiWebLoginPanel {
                timer?.invalidate()
                timer = nil
                status = .success
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var qrArea: some View {
        ZStack {
            if let session {
                if !session.scanURL.isEmpty {
                    // 优先扫 qrcode_index_url（music-lib 同款）：服务端 PNG 里的
                    // web_url 走的可能是身份验证口味的扫码通道，扫了能确认却
                    // 不下发登录会话；index URL 是官方扫码登录入口。
                    QRCodeView(text: session.scanURL)
                } else if let data = session.qrImageData, let image = UIImage(data: data) {
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
        case .verifyRequired(let challenge):
            timer?.invalidate()
            timer = nil
            mfaChallenge = challenge
            mfaUseUpSMS = challenge.smsMode == "up"
            mfaCode = ""
            mfaMobile = challenge.mobile
            mfaError = nil
            if !mfaUseUpSMS {
                sendMFACode()
            }
        case .failed(let message):
            timer?.invalidate()
            timer = nil
            status = .error(message)
        case .success(let cookie):
            timer?.invalidate()
            timer = nil
            completeLogin(cookie: cookie)
        }
    }

    private func completeLogin(cookie: String) {
        status = .success
        QishuiMusicAuth.shared.saveLogin(cookie: cookie)
        Task {
            await QishuiAPI.shared.refreshProfile()
            await MainActor.run { dismiss() }
        }
    }

    // MARK: - 短信验证（MFA）

    private func mfaView(_ challenge: QishuiMFAChallenge) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.beansSage)
            Text("账号需要短信验证")
                .font(BeansFont.appFont(17, .semibold))
                .foregroundStyle(Color.beansLabel)

            if mfaUseUpSMS {
                Text("请用账号绑定的手机号发送下面这条短信到指定号码，发送后点「我已发送」：")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                    .multilineTextAlignment(.center)
                if !challenge.upSMSContent.isEmpty {
                    Text(challenge.upSMSContent)
                        .font(BeansFont.appFont(15, .semibold))
                        .foregroundStyle(Color.beansLabel)
                        .textSelection(.enabled)
                }
                if !challenge.upSMSMobile.isEmpty {
                    Text("发送到：\(challenge.upSMSMobile)")
                        .font(BeansFont.appFont(14))
                        .foregroundStyle(Color.beansLabel)
                        .textSelection(.enabled)
                }
                GlassButton(title: mfaBusy ? "确认中…" : "我已发送，继续", systemName: "checkmark.circle", prominent: true) {
                    verifyUpSMS()
                }
                .disabled(mfaBusy)
                if challenge.canUpSMS {
                    Button("改用验证码验证") {
                        mfaUseUpSMS = false
                        mfaError = nil
                        sendMFACode()
                    }
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                }
            } else {
                Text("验证码会发送到 \(mfaMobile.isEmpty ? "账号绑定的手机号" : mfaMobile)")
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    TextField("6 位验证码", text: $mfaCode)
                        .keyboardType(.numberPad)
                        .font(BeansFont.appFont(16))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 10)
                        .background { BeansSurface(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button(mfaRetrySeconds > 0 ? "\(mfaRetrySeconds)s" : "发送验证码") {
                        sendMFACode()
                    }
                    .font(BeansFont.appFont(13, .semibold))
                    .foregroundStyle(mfaRetrySeconds > 0 || mfaBusy ? Color.beansComment : Color.beansSage)
                    .disabled(mfaRetrySeconds > 0 || mfaBusy)
                }
                GlassButton(title: mfaBusy ? "验证中…" : "验证并登录", systemName: "checkmark.seal", prominent: true) {
                    submitMFACode()
                }
                .disabled(mfaBusy || mfaCode.trimmingCharacters(in: .whitespaces).count < 4)
                if challenge.canUpSMS {
                    Button("改用上行短信验证") {
                        mfaUseUpSMS = true
                        mfaError = nil
                    }
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.beansComment)
                }
            }

            if let mfaError {
                Text(mfaError)
                    .font(BeansFont.appFont(13))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            Button("重新扫码") {
                mfaChallenge = nil
                mfaError = nil
                startLogin()
            }
            .font(BeansFont.appFont(13))
            .foregroundStyle(Color.beansComment)
        }
        .frame(maxWidth: 320)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if mfaRetrySeconds > 0 { mfaRetrySeconds -= 1 }
        }
    }

    private func sendMFACode() {
        guard let challenge = mfaChallenge, !mfaBusy else { return }
        mfaBusy = true
        Task {
            do {
                let result = try await QishuiAPI.shared.sendSMSCode(challenge: challenge)
                await MainActor.run {
                    mfaBusy = false
                    if !result.mobile.isEmpty { mfaMobile = result.mobile }
                    mfaRetrySeconds = result.retryTime > 0 ? result.retryTime : 60
                    mfaError = nil
                }
            } catch {
                await MainActor.run {
                    mfaBusy = false
                    mfaError = error.localizedDescription
                }
            }
        }
    }

    private func submitMFACode() {
        guard let challenge = mfaChallenge, let session, !mfaBusy else { return }
        mfaBusy = true
        Task {
            do {
                let result = try await QishuiAPI.shared.validateSMSCode(challenge: challenge, code: mfaCode, session: session)
                await MainActor.run {
                    mfaBusy = false
                    finishMFA(result)
                }
            } catch {
                await MainActor.run {
                    mfaBusy = false
                    mfaError = error.localizedDescription
                }
            }
        }
    }

    private func verifyUpSMS() {
        guard let challenge = mfaChallenge, let session, !mfaBusy else { return }
        mfaBusy = true
        Task {
            do {
                let result = try await QishuiAPI.shared.verifyUpSMS(challenge: challenge, session: session)
                await MainActor.run {
                    mfaBusy = false
                    finishMFA(result)
                }
            } catch {
                await MainActor.run {
                    mfaBusy = false
                    mfaError = error.localizedDescription
                }
            }
        }
    }

    private func finishMFA(_ result: QishuiQRCodeStatus) {
        switch result {
        case .success(let cookie):
            mfaChallenge = nil
            mfaError = nil
            completeLogin(cookie: cookie)
        case .failed(let message):
            mfaError = message
        default:
            mfaError = "验证未完成，请重试"
        }
    }
}
