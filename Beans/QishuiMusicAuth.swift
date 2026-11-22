import Foundation

/// 汽水音乐登录态（扫码登录得到的 Cookie）。
///
/// 存放方式跟随 KugouMusicAuth 的惯例：UserDefaults 字典持久化，
/// 登录 / 退出都发 .beansQishuiLoginDidUpdate 通知，资料库与发现页据此刷新。
final class QishuiMusicAuth: ObservableObject {
    static let shared = QishuiMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userID = ""
    @Published private(set) var nickname = ""
    @Published private(set) var avatarURL: URL?

    private let defaults = UserDefaults.standard
    private let key = "beans.qishui.auth.v1"
    private var store: [String: String] = [:]

    private init() {
        if let saved = defaults.dictionary(forKey: key) as? [String: String] {
            store = saved
            apply(saved)
        }
    }

    var cookieHeader: String { store["cookie"] ?? "" }

    /// passport 扫码用的稳定 device_id / iid：首次生成后持久化，模拟同一台 PC 客户端。
    var passportDeviceID: String { ensurePassportIDs().deviceID }
    var passportInstallID: String { ensurePassportIDs().installID }

    private func ensurePassportIDs() -> (deviceID: String, installID: String) {
        if let deviceID = store["passportDeviceID"], let installID = store["passportInstallID"] {
            return (deviceID, installID)
        }
        let seed = Int64(Date().timeIntervalSince1970 * 1000)
        let deviceID = "\(seed)\(Int.random(in: 100...999))"
        let installID = "\(seed + 1)\(Int.random(in: 100...999))"
        var next = store
        next["passportDeviceID"] = deviceID
        next["passportInstallID"] = installID
        save(next, notify: false)
        return (deviceID, installID)
    }

    func saveLogin(cookie: String) {
        var next = store
        next["cookie"] = cookie
        save(next)
    }

    func updateProfile(userID: String, nickname: String, avatar: String) {
        var next = store
        if !userID.isEmpty { next["userID"] = userID }
        if !nickname.isEmpty { next["nickname"] = nickname }
        if !avatar.isEmpty { next["avatar"] = avatar }
        guard next != store else { return }
        save(next)
    }

    func logout() {
        store = [:]
        defaults.removeObject(forKey: key)
        updatePublishedState {
            self.isLoggedIn = false
            self.userID = ""
            self.nickname = ""
            self.avatarURL = nil
            NotificationCenter.default.post(name: .beansQishuiLoginDidUpdate, object: nil)
        }
    }

    private func save(_ value: [String: String], notify: Bool = true) {
        store = value
        defaults.set(value, forKey: key)
        apply(value)
        if notify {
            updatePublishedState {
                NotificationCenter.default.post(name: .beansQishuiLoginDidUpdate, object: nil)
            }
        }
    }

    private func apply(_ value: [String: String]) {
        let cookie = value["cookie"] ?? ""
        let loggedIn = cookie.contains("sessionid=") || cookie.contains("sessionid_ss=")
        let nextNickname = value["nickname"] ?? ""
        let nextUserID = value["userID"] ?? ""
        let nextAvatar = URL(string: value["avatar"] ?? "")
        updatePublishedState {
            if self.isLoggedIn != loggedIn { self.isLoggedIn = loggedIn }
            if self.userID != nextUserID { self.userID = nextUserID }
            if self.nickname != nextNickname { self.nickname = nextNickname }
            if self.avatarURL != nextAvatar { self.avatarURL = nextAvatar }
        }
    }

    /// 与 KugouMusicAuth 一致：@Published 的变更统一在主线程成批发布。
    private func updatePublishedState(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.sync(execute: update)
        }
    }
}
