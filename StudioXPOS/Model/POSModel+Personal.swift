import Foundation
import LocalAuthentication
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 個人的裝置（docs/API.md「用 StudioX 帳號登入」）：店員用 StudioX 帳號登入自己的手機（或自己的 iPad），
/// 這台就綁著他在那家店的門市人員。
///
///   - 開 App 直接是他（不用 PIN、沒有人員名單、不能換人）
///   - 鎖定（閒置、離開一陣子回來）換成 Face ID／手機密碼解鎖（PersonalLockView）
///   - 這台被停用（401 revoked）：清掉這台、回配對畫面，說清楚是怎麼了
///   - 他被停用（401 staff_inactive）：**不清**本機資料（還沒送的帳要留著），擋住畫面「請找店長」＋重試（PersonalBlockedView）；
///     店長重新啟用之後同步恢復就自動解開
///   - 設定「登出這支手機」：網站停用這台（POST /devices/self/revoke）、清掉 StudioX 帳號的 token、回配對畫面
///
/// 店裡共用的裝置（配對碼、或用 StudioX 帳號登入時選「店裡共用的」）照舊：大家用 PIN 登入。
extension POSModel {
    /// 為什麼這台被登出了
    enum PersonalLoss {
        /// 店長在後台停用了這台（401 revoked）
        case revoked
    }

    // MARK: 是誰的

    /// 這台是個人的：開機資料（device.personal）優先，還沒抓到就看配對時存的
    var isPersonalDevice: Bool { device.personal ?? pairing?.personal ?? false }

    /// 綁著的門市人員 id
    var personalStaffId: String? {
        guard isPersonalDevice else { return nil }
        return device.staffId ?? pairing?.staffId
    }

    /// 綁著的門市人員（開機資料裡沒有＝被停用了、或資料還沒到）
    var personalStaff: StaffMember? {
        guard let id = personalStaffId else { return nil }
        return staff.first { $0.id == id }
    }

    /// 「王小美」：開機資料還沒到時用配對時存的名字
    var personalName: String { personalStaff?.name ?? pairing?.staffName ?? "你" }

    /// 「這支手機」「這台 iPad」
    var deviceNoun: String { isPhone ? "這支手機" : "這台 iPad" }

    /// 配對時告訴後台這是哪一台（後台「裝置」頁看到的名稱、型號）
    var deviceInfo: DeviceInfo {
        DeviceInfo(name: UIDevice.current.name, model: UIDevice.current.modelIdentifier,
                   systemVersion: UIDevice.current.systemVersion, appVersion: Bundle.main.appVersion)
    }

    // MARK: 登入、鎖定

    /// 開機、配對完（鎖定畫面）：個人的裝置直接登入綁著的那位。
    /// 不打卡（打開 App 不等於上班；要打卡在交班頁）
    func autoLoginPersonal() {
        guard isPersonalDevice, !staffBlocked, phase == .locked, currentStaff == nil, let s = personalStaff else { return }
        login(s)
    }

    /// 鎖定畫面的「用 Face ID 解鎖」：Face ID／Touch ID，不行就手機密碼（.deviceOwnerAuthentication）。
    /// 回傳要顯示的一句話（nil＝解開了，或自己取消了）
    func unlockPersonal() async -> String? {
        guard !staffBlocked else { return APIError.staffInactive.userMessage }
        guard let s = personalStaff else { return "找不到你在這家店的門市人員資料，請登出再登入一次" }
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            // 這台沒有設密碼（也就沒有 Face ID）：沒有東西可以驗，直接解開
            if problem?.code == LAError.Code.passcodeNotSet.rawValue {
                login(s)
                return nil
            }
            return "沒辦法驗證身分：\(problem?.localizedDescription ?? "請到系統設定打開 Face ID 或設定密碼")"
        }
        let reason = "解鎖「\(store.name)」的門市 POS"
        // 系統在別的執行緒回呼：閉包標成 @Sendable（不屬於 MainActor），只把結果傳回來
        let outcome: (ok: Bool, code: Int, message: String) = await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable ok, error in
                let ns = error as NSError?
                cont.resume(returning: (ok, ns?.code ?? 0, ns?.localizedDescription ?? ""))
            }
        }
        if outcome.ok {
            login(s)
            return nil
        }
        let quiet: Set<Int> = [LAError.Code.userCancel.rawValue, LAError.Code.appCancel.rawValue, LAError.Code.systemCancel.rawValue]
        if quiet.contains(outcome.code) { return nil }
        return outcome.message.isEmpty ? "沒有解開，請再試一次" : "沒有解開：\(outcome.message)"
    }

    /// App 回到前景：個人的裝置離開超過「閒置自動鎖定」的時間就鎖起來（回來用 Face ID）。
    /// 回傳 true＝剛鎖起來（鎖定畫面直接跳出 Face ID）；其他情況照舊算一次「有人在用」
    @discardableResult
    func returnedToForeground() -> Bool {
        let away = Date().timeIntervalSince(lastActivity)
        if isPersonalDevice, phase == .ready, settings.autoLockMinutes > 0, away > Double(settings.autoLockMinutes * 60) {
            lock()
            return true
        }
        touch()
        return false
    }

    // MARK: 被停用、登出

    /// 剛抓到開機資料（後台只給啟用中的人員）：綁著的那位不在＝被停用了 → 擋住；在、而且剛才擋著 → 解開。
    /// 回傳 true＝擋住了
    @discardableResult
    func checkPersonalStaff() -> Bool {
        guard isPersonalDevice, !isDemo, let id = personalStaffId else { return false }
        if staff.contains(where: { $0.id == id }) {
            if staffBlocked { staffBlocked = false }
            return false
        }
        personalStaffBlocked()
        return true
    }

    /// 綁的那位被停用了（401 staff_inactive）：鎖起來、鎖定畫面換成「請找店長」＋重試。
    /// **不清**本機資料：還沒送到後台的帳要留著，店長重新啟用之後自動補送、照常使用（同步恢復時 POSModel.syncChanged 解開）
    func personalStaffBlocked() {
        guard isPersonalDevice else { return }
        if !staffBlocked { staffBlocked = true }
        if phase == .ready { lock() }
    }

    /// 「請找店長」畫面的重試：重新抓開機資料。回傳要顯示的一句話（nil＝解開了）
    func retryPersonalAccess() async -> String? {
        guard let api else { return nil }
        do {
            let b = try await api.bootstrap(ifNoneMatch: nil)
            apply(b)
            if !isDemo { DeviceStore.save(b) }
            if checkPersonalStaff() { return "還是找不到你在這家店的門市人員資料，請找店長" }
            staffBlocked = false
            _ = await syncNow()
            return nil
        } catch APIError.staffInactive {
            return "還是停用中：請店長到後台「門市 POS → 人員」重新啟用你"
        } catch APIError.revoked {
            personalDeviceLost(.revoked)
            return nil
        } catch let e as APIError {
            return e.userMessage
        } catch {
            return "連不上後台，請稍後再試"
        }
    }

    /// 這台不能再用了：清掉本機的資料與 StudioX 帳號的 token，回配對畫面，跳一句說明
    func personalDeviceLost(_ why: PersonalLoss) {
        let noun = deviceNoun
        forgetPersonalDevice()
        switch why {
        case .revoked:
            alert = AlertInfo(title: "\(noun)的登入被停用了",
                              message: "店長在後台停用了\(noun)，本機的資料已經清掉。要再使用，請重新用 StudioX 帳號登入。")
        }
    }

    /// 設定「登出這支手機」：先把還沒送的送出去，網站停用這台（POST /devices/self/revoke；網路不通也照樣登出），
    /// 清掉本機的資料與 StudioX 帳號的 token，回配對畫面
    func signOutPersonalDevice() async {
        if isDemo {
            reset()
            device.personal = nil
            device.staffId = nil
            return
        }
        let noun = deviceNoun
        _ = await syncNow()
        if let p = pairing, let token = DeviceStore.token {
            try? await POSClient(cmsURL: p.cmsURL, token: token).revokeSelf()
        }
        forgetPersonalDevice()
        show("已經登出\(noun)", tone: .info)
    }

    private func forgetPersonalDevice() {
        let id = pairing?.deviceId
        staffBlocked = false
        reset()
        DeviceStore.forget(deviceId: id)
        ConsoleAccount.forget(consoleURL: settings.consoleURL)
        // 下一家（或下一個人）配對時重新從開機資料讀
        device.personal = nil
        device.staffId = nil
    }

    // MARK: 用 StudioX 帳號配對

    /// console 代轉配對回來之後：和配對碼一樣存起來、抓開機資料；個人的直接登入綁著的那位
    func completeAccountPairing(_ r: PersonalPairResponse) async throws {
        guard let url = URL(string: r.cmsUrl), url.host() != nil else {
            throw APIError.decoding("後台網址不對")
        }
        try await completePairing(cmsURL: url, response: r.pair, personalStaff: r.boundStaff)
    }

    // MARK: 示範（截圖）

    /// -personal：示範店當成這個人的個人手機（不用 PIN、鎖定是 Face ID）
    func bindDemoPersonal(to s: StaffMember) {
        guard isDemo else { return }
        device.personal = true
        device.staffId = s.id
    }
}
