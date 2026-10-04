import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 手機的「更多」：誰在用、這支手機在哪家店、同步得怎樣；查會員；這支手機的設定（收款、營業模式、外觀、自動鎖定）。
/// 動作照設計規則放在下面：大鍵「換人」（鎖定、讓下一位打 PIN），「⋯」裡是結束示範／解除配對。
/// 個人的手機（用 StudioX 帳號登入）：寫「這支手機是 王小美 的（個人）」，沒有換人；「⋯」裡是「登出這支手機」
struct PhoneMoreView: View {
    @Environment(POSModel.self) private var model

    @State private var confirmEndDemo = false
    @State private var confirmUnpair = false
    @State private var confirmSignOut = false

    private struct Appearance: Identifiable {
        let id: String
        let label: String
        let icon: String
    }

    private static let appearances = [
        Appearance(id: "system", label: "跟著手機", icon: "device-phone-mobile"),
        Appearance(id: "light", label: "淺色", icon: "sun"),
        Appearance(id: "dark", label: "深色", icon: "moon"),
    ]
    private static let lockChoices = [0, 1, 3, 5, 10, 30]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(title: "This *phone*", subtitle: "更多")
                whoPanel
                if model.phoneMoreSections.contains(.members) {
                    membersRow
                }
                phonePanel
                Text("StudioX POS \(Bundle.main.appVersion)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .dockSelection(.page("phone-more", primary: lockAction, actions: leaveActions))
        .confirmationDialog("登出這支手機？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("登出這支手機", role: .destructive) {
                Task { await model.signOutPersonalDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
        .confirmationDialog("結束示範？", isPresented: $confirmEndDemo, titleVisibility: .visible) {
            Button("結束示範", role: .destructive) { model.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("示範的單、班、打卡都會清掉，回到配對畫面。")
        }
        .confirmationDialog("解除配對？", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("解除配對並清掉這支手機的資料", role: .destructive) {
                Task { await model.unpair() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("還沒送出去的資料會先試著送到後台。之後要再用，請在後台「門市 POS → 裝置」產生新的配對碼。")
        }
    }

    // MARK: 誰、哪家店、同步

    private var whoPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let s = model.currentStaff {
                    StaffAvatar(name: s.name, swatch: s.swatch, size: 44, active: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                            .font(.brand(18, .semibold))
                            .foregroundStyle(Theme.ink)
                        Text((s.title ?? s.role.label) + (model.isClockedIn(s) ? "・上班中" : ""))
                            .textRole(.small)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                SyncDot(status: model.syncStatus, demo: model.isDemo)
            }
            Rule(color: Theme.hair)
            ValueRow(label: "店", value: model.store.name)
            if model.isPersonalDevice {
                Text("這支手機是 \(model.personalName) 的（個人）")
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink)
            } else {
                ValueRow(label: "這支手機", value: model.device.name.isEmpty ? model.role.label : "\(model.device.name)・\(model.role.label)")
            }
            ValueRow(label: "結帳", value: model.takesPayment ? "這支手機也能收款" : "送到結帳櫃台")
            if !model.isDemo {
                ValueRow(label: "同步", value: model.syncStatus.label)
            }
        }
        .panel(padding: 18)
    }

    // MARK: 會員

    private var membersRow: some View {
        Button {
            model.go(.members)
        } label: {
            HStack(spacing: 12) {
                HeroIcon("user-group", size: 20)
                    .foregroundStyle(Theme.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("查會員")
                        .font(.brand(16, .medium))
                        .foregroundStyle(Theme.ink)
                    Text("打電話查儲值金、課程卡、上次來做了什麼")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                HeroIcon("chevron-right", size: 14)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .panel(padding: 0)
    }

    // MARK: 這支手機

    private var phonePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("這支手機")
            if model.role.takesPayment {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { PhoneSettings.shared.takesPayment },
                                         set: { on in Task { await model.setPhoneTakesPayment(on) } })) {
                        Text("這支手機也能收款（刷卡、電子支付）")
                            .font(.brand(15.5, .medium))
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.accent)
                    Text(PhoneSettings.shared.takesPayment
                         ? "單子可以在這裡結帳：刷卡、電子支付；現金請到結帳櫃台（手機沒有錢櫃）。關掉不用授權。"
                         : "關著：點好的單「送到結帳櫃台」，客人到櫃台一起結。打開要店長授權。")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rule(color: Theme.hair)
            }
            if model.store.serviceModes.count > 1 && !model.role.isKitchen {
                HStack {
                    Text("營業模式")
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(model.store.serviceModes, id: \.self) { m in
                            Button {
                                model.setMode(m)
                            } label: {
                                if m == model.mode {
                                    Label("\(m.label)・\(m.summary)", systemImage: "checkmark")
                                } else {
                                    Text("\(m.label)・\(m.summary)")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.mode.label)
                            HeroIcon("chevron-down", size: 12)
                        }
                        .font(.brand(14.5, .medium))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Theme.accentSoft, in: .capsule)
                    }
                }
                Rule(color: Theme.hair)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("外觀")
                    .font(.brand(15.5, .medium))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    ForEach(Self.appearances) { a in
                        Button {
                            model.settings.appearance = a.id
                        } label: {
                            VStack(spacing: 5) {
                                HeroIcon(a.icon, size: 18)
                                Text(a.label)
                            }
                        }
                        .buttonStyle(.choice(currentAppearance == a.id, height: 64))
                    }
                }
            }
            Rule(color: Theme.hair)
            HStack {
                Text("閒置自動鎖定")
                    .font(.brand(15.5, .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Menu {
                    ForEach(Self.lockChoices, id: \.self) { m in
                        Button(lockLabel(m)) { model.settings.autoLockMinutes = m }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(lockLabel(model.settings.autoLockMinutes))
                        HeroIcon("chevron-down", size: 12)
                    }
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .overlay { Capsule().strokeBorder(Theme.line) }
                }
            }
            Text(model.printers.printers.isEmpty
                 ? "出單機、收據、發票在 iPad 的「設定」改。這支手機送出的單，廚房螢幕馬上看得到；這支手機沒有出單機，不會自己印廚房單。"
                 : "出單機、收據、發票在 iPad 的「設定」改。這支手機送出的單，廚房螢幕馬上看得到，廚房單從這支手機設定的出單機印。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 18)
    }

    private var currentAppearance: String {
        ["light", "dark"].contains(model.settings.appearance) ? model.settings.appearance : "system"
    }

    private func lockLabel(_ m: Int) -> String {
        m == 0 ? "不自動" : "\(m) 分"
    }

    /// 大鍵「換人」：個人的手機沒有（只有他自己；閒置時自動鎖、用 Face ID 解開）
    private var lockAction: POSAction? {
        if model.isPersonalDevice { return nil }
        return POSAction("換人（鎖定）", icon: "lock-closed") { model.lock() }
    }

    private var signOutMessage: String {
        let pending = model.syncStatus.pending
        let first = pending > 0 ? "還有 \(pending) 筆沒送到後台，會先試著送。" : ""
        return first + "這支手機不再是你在「\(model.store.name)」的點餐機，StudioX 帳號也會登出；要再用，重新用 StudioX 帳號登入。"
    }

    /// 「⋯」：示範模式是「結束示範」；個人的手機是「登出這支手機」（不用授權，是他自己的）；配對了的是「解除配對」（要店長授權、再確認一次）
    private var leaveActions: [POSAction] {
        if model.isDemo {
            return [POSAction("結束示範", icon: "x-circle", destructive: true) { confirmEndDemo = true }]
        }
        if model.isPersonalDevice {
            return [POSAction("登出這支手機", icon: "arrow-right-start-on-rectangle", destructive: true) { confirmSignOut = true }]
        }
        if model.pairing != nil {
            return [POSAction("解除配對", icon: "arrow-right-start-on-rectangle", destructive: true) { Task { await askUnpair() } }]
        }
        return []
    }

    private func askUnpair() async {
        guard await model.authorize(.manageDevice, detail: "解除這支手機的配對") != nil else { return }
        confirmUnpair = true
    }
}
