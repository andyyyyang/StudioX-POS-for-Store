import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 設定 → 刷卡機（銀行 EDC 的收銀機連線）：打開、哪一家、IP、連接埠、逾時、哪些付款方式經刷卡機。
/// 測試連線、查上一筆、刷卡機結帳在右欄。設定存在這台（每台接自己的刷卡機）；IP 打字、數字在右側鍵盤打（和出單機一樣）
struct CardTerminalSettingsSection: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        @Bindable var hub = model.cardTerminal
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "刷卡機（銀行 EDC）",
                            detail: "金額直接送到銀行的刷卡機，客人在刷卡機上刷卡、感應；成功了自動記到單子上（授權碼、調閱編號、末四碼），不用再打。退款也從刷卡機退。設定存在這台。")
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $hub.config.enabled) {
                    SettingsToggleLabel(title: "用刷卡機收款", detail: "關著時照舊：刷完卡手動輸入末四碼")
                }
                if model.isDemo {
                    StatusBadge("示範：模擬的刷卡機，不連網路、兩秒後核准", tone: .gold)
                }
            }
            .panel(padding: 22)
            if hub.config.enabled {
                formatPanel
                connectionPanel
                coveragePanel
            }
            statusPanel
        }
        .dockSelection(pageDock)
    }

    private var hub: CardTerminalHub { model.cardTerminal }

    // MARK: 哪一家

    private var formatPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("哪一家的刷卡機")
            HStack(spacing: 10) {
                ForEach(ECRFormat.allCases, id: \.self) { f in
                    Button {
                        hub.config.format = f
                    } label: {
                        VStack(spacing: 4) {
                            Text(f.label)
                                .font(.brand(15, .semibold))
                            Text(f.detail)
                                .font(.brand(12, .regular))
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.choice(hub.config.format == f, height: 76))
                    .disabled(!f.isSupported)
                    .opacity(f.isSupported ? 1 : 0.5)
                }
            }
            Text("聯卡中心的「8N1 標準」電文、UDP 連線。各家銀行的格式不一樣，做好了會出現在這裡。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    // MARK: 連線

    private var connectionPanel: some View {
        @Bindable var hub = model.cardTerminal
        return VStack(alignment: .leading, spacing: 16) {
            Eyebrow("連線")
            SettingsField(label: "刷卡機的 IP 位址", hint: "刷卡機的網路設定畫面看得到，或請銀行查（例如 192.168.1.60）。刷卡機和這台 iPad 要接同一個網路") {
                TextField("192.168.1.60", text: $hub.config.host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsInput()
            }
            SettingsField(label: "連接埠", hint: "聯卡中心的 UDP 收銀機連線預設 50002") {
                keypadField(String(hub.config.port), label: "連接埠") { await askPort() }
            }
            SettingsField(label: "等客人刷卡最多", hint: "超過還沒有結果：先查刷卡機的上一筆，確認有沒有扣款（不會重刷）") {
                keypadField("\(hub.config.timeoutSeconds) 秒", label: "等客人刷卡最多") { await askTimeout() }
            }
        }
        .panel(padding: 22)
    }

    /// 數字欄位：點了在右側鍵盤改
    private func keypadField(_ value: String, label: String, ask: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await ask() }
        } label: {
            HStack(spacing: 10) {
                Text(value)
                    .font(.brand(16, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text("在右側鍵盤改")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                HeroIcon("calculator", size: 16)
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityLabel("\(label) \(value)，在右側鍵盤改")
    }

    private func askPort() async {
        let spec = KeypadSpec(kind: .code(minLength: 2, maxLength: 5), title: "連接埠", subtitle: "聯卡中心的 UDP 收銀機連線預設 50002",
                              initial: String(hub.config.port), quickKeys: [.init("50002", digits: "50002", commits: true)], confirmLabel: "設定")
        guard let port = await model.keypad.askNumber(spec, validate: { (1...65_535).contains($0) ? nil : "連接埠是 1 到 65535" }) else { return }
        hub.config.port = port
    }

    private func askTimeout() async {
        let spec = KeypadSpec(kind: .count, title: "等客人刷卡最多", subtitle: "30 到 300 秒",
                              initial: String(hub.config.timeoutSeconds),
                              quickKeys: [60, 90, 120].map { .init("\($0) 秒", digits: String($0), commits: true) },
                              confirmLabel: "設定", maxValue: 300, minValue: 30)
        guard let seconds = await model.keypad.askNumber(spec, validate: { (30...300).contains($0) ? nil : "30 到 300 秒" }) else { return }
        hub.config.timeoutSeconds = seconds
    }

    // MARK: 哪些經刷卡機

    private var coveragePanel: some View {
        @Bindable var hub = model.cardTerminal
        return VStack(alignment: .leading, spacing: 16) {
            Eyebrow("哪些經刷卡機收")
            Toggle(isOn: $hub.config.cards) {
                SettingsToggleLabel(title: "信用卡", detail: "Visa、Master、JCB、銀聯、U Card、Smart Pay：刷卡、插卡、感應")
            }
            Rule(color: Theme.hair)
            Toggle(isOn: $hub.config.eTickets) {
                SettingsToggleLabel(title: "電子票證", detail: "悠遊卡、一卡通、愛金卡：付款方式選「電子票證」，客人在刷卡機上感應")
            }
            Rule(color: Theme.hair)
            Toggle(isOn: $hub.config.wallets) {
                SettingsToggleLabel(title: "電子錢包經刷卡機",
                                    detail: "LINE Pay、悠遊付、全支付（也收 icash Pay、全盈+PAY、Pi 錢包）：刷卡機掃客人的付款碼。街口照舊手動記")
            }
            Text("這些服務要先請收單銀行在刷卡機上開好；沒打開的照舊手動記。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    // MARK: 狀態

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Eyebrow("狀態")
                Spacer(minLength: 8)
                StatusBadge(statusText, tone: statusTone)
            }
            if let h = hub.health {
                Text("\(h.message)（\(h.at.clockText)）")
                    .textRole(.small)
                    .foregroundStyle(h.ok ? Theme.ink2 : Theme.dangerFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let s = hub.lastSummary {
                Text(s)
                    .textRole(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rule(color: Theme.hair)
            Text("第一次接：請收單銀行在刷卡機的 TMS 打開「收銀機連線」與 UDP（聯卡中心預設 50002）；這台 iPad 第一次連會問「區域網路」權限，要允許。等不到結果時 POS 一定先查刷卡機的上一筆，不會自動重刷。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    private var statusText: String {
        if !hub.isReady(demo: model.isDemo) { return hub.config.enabled ? "還沒設定 IP" : "沒有打開" }
        guard let h = hub.health else { return model.isDemo ? "示範" : "還沒測試" }
        return h.ok ? "連線正常" : "連不到"
    }

    private var statusTone: Tone {
        if !hub.isReady(demo: model.isDemo) { return hub.config.enabled ? .warning : .neutral }
        guard let h = hub.health else { return .neutral }
        return h.ok ? .active : .danger
    }

    // MARK: 右欄

    /// 大鍵「測試連線」；動作鍵「查上一筆」「刷卡機結帳」
    private var pageDock: DockSelection {
        let can = !hub.busy && hub.session == nil && hub.isReady(demo: model.isDemo)
        return DockSelection.page(
            "settings-card-terminal",
            primary: POSAction(hub.busy ? "連線中…" : "測試連線", icon: "signal", enabled: can) {
                Task { await model.testCardTerminal() }
            },
            actions: [
                POSAction("查上一筆", icon: "magnifying-glass", enabled: can) {
                    Task { await model.checkLastTerminalTransaction() }
                },
                POSAction("刷卡機結帳", icon: "check-circle", enabled: can) {
                    Task { await model.settleCardTerminal() }
                },
            ]
        )
    }
}
