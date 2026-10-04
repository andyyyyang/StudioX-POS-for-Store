import Foundation
import LocalAuthentication
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 個人的裝置（用 StudioX 帳號登入）的鎖定畫面：沒有人員名單、沒有 PIN、不能換人；用 Face ID／手機密碼解開。
///
///   ┌──────────────────────────────┐
///   │            14:05             │
///   │        10月4日 星期六          │
///   │                              │
///   │             (王)              │
///   │            王小美              │
///   │   晨麥手作・這支手機是你的（個人）  │
///   │                              │
///   │  [ ◉ 用 Face ID 解鎖        ]  │  大鍵（品牌橘）
///   └──────────────────────────────┘
///
/// 離開一陣子回來（App 回到前景時鎖起來的）直接跳出 Face ID；閒置鎖定的等人按（手機放在桌上時不要一直跳）。
struct PersonalLockView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// 一出現就跳出 Face ID（剛從背景回來）
    var promptOnAppear = false
    /// 鎖著的時候 App 進了背景：回來時跳出 Face ID（Face ID 自己的視窗只會讓 App 變 inactive，不會一直重跳）
    @State private var wasAway = false

    @State private var unlocking = false
    @State private var message: String?
    @State private var method: UnlockMethod?
    @State private var confirmSignOut = false

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            clock
            Spacer(minLength: 28)
            who
            Spacer(minLength: 28)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.bottom, compact ? 20 : 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .task { await appeared() }
        .onChange(of: scenePhase) { _, p in returned(to: p) }
        .confirmationDialog("登出\(model.deviceNoun)？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("登出\(model.deviceNoun)", role: .destructive) {
                Task { await model.signOutPersonalDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.deviceNoun)不再是你在「\(model.store.name)」的點餐機；要再用，重新用 StudioX 帳號登入。")
        }
    }

    // MARK: 時間

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: compact ? 6 : 12) {
                Text(TaipeiTime.clock(ctx.date))
                    .font(.brand(compact ? 76 : 120, .medium))
                    .tracking(compact ? -3 : -6)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(ctx.date.dayTitle)
                    .textRole(.lead)
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    // MARK: 是誰的

    private var who: some View {
        VStack(spacing: 12) {
            if let s = model.personalStaff {
                StaffAvatar(name: s.name, swatch: s.swatch, size: compact ? 68 : 84, active: true)
            } else {
                HeroIcon("user-circle", size: compact ? 68 : 84)
                    .foregroundStyle(Theme.faint)
            }
            Text(model.personalName)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(model.store.name)・\(model.deviceNoun)是你的（個人）")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 解鎖

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            if model.personalStaff == nil {
                missingStaff
            } else {
                unlockButton
            }
            Text(message ?? " ")
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.dangerFG)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)
                .opacity(message == nil ? 0 : 1)
        }
    }

    private var unlockButton: some View {
        let m = method ?? UnlockMethod.fallback(phone: model.isPhone)
        return Button {
            Task { await unlock() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: m.symbol)
                    .font(.system(size: 19, weight: .medium))
                Text(unlocking ? "解鎖中…" : m.title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(.accent, size: .lg, fullWidth: true))
        .disabled(unlocking)
        .keyboardShortcut(.defaultAction)
    }

    /// 開機資料裡沒有綁著的那位（還沒同步到、或被停用了）：只能登出再登入
    private var missingStaff: some View {
        VStack(spacing: 12) {
            Text("找不到你在這家店的門市人員資料。連上網路後會自動再試；一直這樣請登出，再用 StudioX 帳號登入。")
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("登出\(model.deviceNoun)") { confirmSignOut = true }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
        }
    }

    private func appeared() async {
        method = UnlockMethod.current(phone: model.isPhone)
        if promptOnAppear { await unlock() }
    }

    private func returned(to p: ScenePhase) {
        if p == .background {
            wasAway = true
        } else if p == .active, wasAway {
            wasAway = false
            Task { await unlock() }
        }
    }

    private func unlock() async {
        guard !unlocking else { return }
        unlocking = true
        message = nil
        message = await model.unlockPersonal()
        unlocking = false
    }
}

/// 鍵上寫什麼：這台有登記 Face ID／Touch ID 就寫那個，否則是手機密碼（.deviceOwnerAuthentication 兩種都收）
private struct UnlockMethod {
    var title: String
    var symbol: String

    static func current(phone: Bool) -> UnlockMethod {
        let context = LAContext()
        var problem: NSError?
        let enrolled = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem)
        // 截圖（-personal 示範）：模擬器沒有登記 Face ID，照硬體寫（biometryType 不管有沒有登記都會設）
        #if DEBUG
        let demo = LaunchArguments.has("-personal")
        #else
        let demo = false
        #endif
        guard enrolled || demo else { return fallback(phone: phone) }
        switch context.biometryType {
        case .faceID: return UnlockMethod(title: "用 Face ID 解鎖", symbol: "faceid")
        case .touchID: return UnlockMethod(title: "用 Touch ID 解鎖", symbol: "touchid")
        case .opticID: return UnlockMethod(title: "用 Optic ID 解鎖", symbol: "opticid")
        default: return fallback(phone: phone)
        }
    }

    static func fallback(phone: Bool) -> UnlockMethod {
        UnlockMethod(title: phone ? "用手機密碼解鎖" : "用密碼解鎖", symbol: "lock.open")
    }
}

/// 個人的裝置：綁著的門市人員被停用了（401 staff_inactive）。
/// 本機資料都留著（還沒送的帳不能丟）：等店長在後台重新啟用。同步恢復時自動解開；也可以按「重試」馬上再問一次。
///
///   ┌──────────────────────────────┐
///   │             (!)              │
///   │  你在這家店的門市人員被停用了，    │
///   │           請找店長             │
///   │   王小美・晨麥手作・3 筆還沒送出   │
///   │  [          重試           ]  │  大鍵
///   │         登出這支手機            │  安靜的（要確認；還沒送的會丟掉）
///   └──────────────────────────────┘
struct PersonalBlockedView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var retrying = false
    @State private var message: String?
    @State private var confirmSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            notice
            Spacer(minLength: 28)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.bottom, sizeClass == .compact ? 20 : 56)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page.ignoresSafeArea())
        .confirmationDialog("登出\(model.deviceNoun)？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("登出\(model.deviceNoun)", role: .destructive) {
                Task { await model.signOutPersonalDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(signOutWarning)
        }
    }

    private var pending: Int { model.ledger?.journal.pendingCount ?? 0 }

    private var notice: some View {
        VStack(spacing: 14) {
            HeroIcon("no-symbol", size: 44)
                .foregroundStyle(Theme.dangerFG)
            Text(APIError.staffInactive.userMessage)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.personalName)・\(model.store.name)")
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
            Text(detail)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let kept = pending > 0 ? "還有 \(pending) 筆帳沒送到後台，都留在\(model.deviceNoun)，不會清掉。" : "\(model.deviceNoun)的資料都留著。"
        return kept + "店長在後台「門市 POS → 人員」重新啟用你之後，會自動補送、照常使用。"
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button {
                Task { await retry() }
            } label: {
                HStack(spacing: 8) {
                    if retrying { ProgressView().tint(Theme.onAccent) }
                    Text(retrying ? "重試中…" : "重試")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.accent, size: .lg, fullWidth: true))
            .disabled(retrying)
            .keyboardShortcut(.defaultAction)
            Text(message ?? " ")
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.dangerFG)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)
                .opacity(message == nil ? 0 : 1)
            Button("登出\(model.deviceNoun)") { confirmSignOut = true }
                .buttonStyle(.brand(.quiet, size: .sm))
                .disabled(retrying)
        }
    }

    /// 被停用時後台不收這台的帳：登出的話還沒送的會跟著清掉，說清楚
    private var signOutWarning: String {
        let lost = pending > 0 ? "還沒送到後台的 \(pending) 筆帳會跟著清掉（後台現在不收），建議先請店長重新啟用你。" : ""
        return lost + "\(model.deviceNoun)不再是你在「\(model.store.name)」的裝置，StudioX 帳號也會登出。"
    }

    private func retry() async {
        guard !retrying else { return }
        retrying = true
        message = nil
        message = await model.retryPersonalAccess()
        retrying = false
    }
}
