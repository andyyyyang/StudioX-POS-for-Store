import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 設定：左邊分類、右邊內容。
///
///   ┌ Device settings ─────────────────────────────────── 示範模式 ┐
///   │ 這台裝置      │ 這台裝置                                        │
///   │ 營業模式      │ ┌名稱 櫃台 1・代號 A・收銀機──────────────┐     │
///   │ 出單機  連不到 │ ┌● 已同步・0 筆待送  [重新抓設定]─────────┐     │
///   │ 收據與出單    │ ┌區網同步 2 台連線中───────────────────────┐   │
///   │ 電子發票 剩 8 │                                                 │
///   │ 外觀與安全    │                                                 │
///   │ 資料          │                                                 │
///   │ 進階          │                                                 │
///   └──────────────────────────────────────────────────────────────┘
///
/// 出單機的新增／編輯不用 sheet：連接埠要在右側鍵盤打，sheet 會把鍵盤蓋住。
struct SettingsView: View {
    @Environment(POSModel.self) private var model
    @Environment(PrinterHub.self) private var printers

    @State private var group: SettingsGroup = .device
    /// 正在新增／編輯的出單機（存檔前只改這一份）
    @State private var draft: PrinterConfig?
    /// 最近列印的預覽（這個用 sheet：不需要鍵盤）
    @State private var preview: PrintJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rule()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                Rule(vertical: true)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $preview) { job in
            SettingsPrintPreview(job: job, paper: paper(for: job))
        }
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            PageTitle(title: "Device *settings*", subtitle: subtitle)
            Spacer(minLength: 16)
            if model.isDemo {
                StatusBadge("示範模式", tone: .gold)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var subtitle: String {
        model.device.name.isEmpty ? "設定" : "設定・\(model.device.name)"
    }

    // MARK: - 左邊

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                // 叫號：後台開了才有這一類
                ForEach(SettingsGroup.allCases.filter { $0 != .queue || model.features.queue }) { g in
                    Button {
                        group = g
                        draft = nil
                    } label: {
                        HStack(spacing: 12) {
                            HeroIcon(g.icon, size: 18)
                            Text(g.label)
                            Spacer(minLength: 4)
                            if let badge = badge(for: g) {
                                StatusBadge(badge.text, tone: badge.tone)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                    }
                    .buttonStyle(SettingsNavStyle(selected: group == g))
                    .accessibilityAddTraits(group == g ? .isSelected : [])
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
    }

    /// 左邊分類旁的小提示（要處理的事）
    private func badge(for g: SettingsGroup) -> (text: String, tone: Tone)? {
        switch g {
        case .device:
            if model.isDemo { return nil }
            switch model.syncStatus.health {
            case .attention: return ("要處理", .danger)
            case .offline: return ("離線", .warning)
            case .synced, .syncing, .paused: return nil
            }
        case .printers:
            let failing = printers.printers.contains(where: { printers.status[$0.id]?.ok == false })
            if failing { return ("連不到", .danger) }
            return nil
        case .invoice:
            guard model.features.invoice && model.invoiceSettings.enabled else { return nil }
            let left = model.invoiceNumbersLeft
            if left == 0 { return ("剩 0", .danger) }
            if left < 10 { return ("剩 \(left)", .warning) }
            return nil
        case .workstation:
            // 換過崗位（不是後台配對時設的）：提醒一下
            return model.role != model.device.role ? ("已改", .info) : nil
        case .queue:
            // 這台取號要印：沒有號碼牌出單機就提醒
            return model.features.queue && !model.hasQueuePrinter ? ("沒出單機", .warning) : nil
        case .mode, .store, .receipts, .appearance, .data, .advanced:
            return nil
        }
    }

    // MARK: - 右邊

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch group {
                case .device: SettingsDeviceSection()
                case .workstation: SettingsWorkstationSection()
                case .mode: SettingsModeSection()
                case .store: SettingsStoreSection()
                case .printers: printersSection
                case .receipts: SettingsReceiptsSection()
                case .invoice: SettingsInvoiceSection()
                case .queue: SettingsQueueSection(openPrinters: { group = .printers; draft = nil })
                case .appearance: SettingsAppearanceSection()
                case .data: SettingsDataSection()
                case .advanced: SettingsAdvancedSection()
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .id(group)
    }

    // MARK: 出單機

    @ViewBuilder
    private var printersSection: some View {
        if let current = draft {
            SettingsPrinterEditor(
                config: Binding(get: { draft ?? current }, set: { draft = $0 }),
                isNew: !printers.printers.contains(where: { $0.id == current.id }),
                stations: stations,
                save: { savePrinter() },
                cancel: { draft = nil },
                delete: { deleteDraft() }
            )
        } else {
            SettingsPrinterList(
                edit: { draft = $0 },
                add: { draft = PrinterConfig(name: "") },
                preview: { preview = $0 }
            )
        }
    }

    /// 菜單上用到的出單站（分類的、品項自己的）
    private var stations: [String] {
        let names = model.catalog.categories.compactMap(\.station) + model.catalog.items.compactMap(\.station)
        return Array(Set(names)).sorted()
    }

    private func savePrinter() {
        guard var p = draft else { return }
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.host = p.host.trimmingCharacters(in: .whitespacesAndNewlines)
        // PrinterConfig 是 struct：整份換掉再寫回去（PrinterHub 的 didSet 才會存檔）
        var list = printers.printers
        if let i = list.firstIndex(where: { $0.id == p.id }) {
            list[i] = p
        } else {
            list.append(p)
        }
        printers.printers = list
        draft = nil
        model.show("已儲存出單機「\(p.name)」")
    }

    private func deleteDraft() {
        guard let p = draft else { return }
        printers.printers = printers.printers.filter { $0.id != p.id }
        printers.status[p.id] = nil
        draft = nil
        model.show("已刪除出單機「\(p.name)」", tone: .neutral)
    }

    private func paper(for job: PrintJob) -> PaperWidth {
        printers.printers.first(where: { $0.name == job.printer })?.paper ?? .mm80
    }
}

// MARK: - 分類

private enum SettingsGroup: String, CaseIterable, Identifiable {
    case device, workstation, mode, store, printers, receipts, invoice, queue, appearance, data, advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .device: "這台裝置"
        case .workstation: "崗位"
        case .mode: "營業模式"
        case .store: "門市設定"
        case .printers: "出單機"
        case .receipts: "收據與出單"
        case .invoice: "電子發票"
        case .queue: "叫號"
        case .appearance: "外觀與安全"
        case .data: "資料"
        case .advanced: "進階"
        }
    }

    var icon: String {
        switch self {
        case .device: "device-phone-mobile"
        case .workstation: "map-pin"
        case .mode: "rectangle-stack"
        case .store: "building-storefront"
        case .printers: "printer"
        case .receipts: "document-text"
        case .invoice: "qr-code"
        case .queue: "ticket"
        case .appearance: "swatch"
        case .data: "circle-stack"
        case .advanced: "adjustments-horizontal"
        }
    }
}

private struct SettingsNavStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(15, selected ? .semibold : .medium))
            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
            .background(selected || configuration.isPressed ? Theme.press : Color.clear,
                        in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 18)
                }
            }
            .contentShape(.rect)
            .animation(Motion.fast, value: selected)
    }
}

// MARK: - 共用的小元件

private struct SettingsHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
            if let detail {
                Text(detail)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 表單的一格：標題、欄位、下面一行說明
private struct SettingsField<Content: View>: View {
    let label: String
    let hint: String?
    let content: Content

    init(label: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.brand(13.5, .semibold))
                .foregroundStyle(Theme.ink2)
            content
            if let hint {
                Text(hint)
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsToggleLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.brand(15.5, .medium))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.brand(12.5, .regular))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 剩多少的細長條
private struct SettingsMeter: View {
    let ratio: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.press)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(ratio, 0), 1))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 設定頁的文字欄位：細框、方角
    fileprivate func settingsInput() -> some View {
        font(.brand(16, .regular))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
    }
}

// MARK: - 這台裝置

private struct SettingsDeviceSection: View {
    @Environment(POSModel.self) private var model
    @State private var refreshing = false
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "這台裝置", detail: "名稱、代號、預設崗位在後台「門市 POS → 裝置」設定；崗位也可以在左邊的「崗位」裡改。")
            identityPanel
            syncPanel
            meshPanel
        }
        .dockSelection(pageDock)
    }

    /// 右欄（這一頁的動作）：大鍵「立即同步」；動作鍵「重新抓設定」
    private var pageDock: DockSelection {
        DockSelection.page(
            "settings-device",
            primary: POSAction(syncing ? "同步中…" : "立即同步", icon: "arrow-path", enabled: !syncing && !model.isDemo) {
                Task { await syncNow() }
            },
            actions: [POSAction(refreshing ? "更新中…" : "重新抓設定", icon: "arrow-down-tray", enabled: !refreshing) {
                Task { await refresh() }
            }]
        )
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isPersonalDevice {
                // 用 StudioX 帳號登入的個人裝置：綁著這個人，不用 PIN；登出在「資料」
                Text("\(model.deviceNoun)是 \(model.personalName) 的（個人）")
                    .font(.brand(17, .semibold))
                    .foregroundStyle(Theme.ink)
                Rule(color: Theme.hair)
            }
            ValueRow(label: "名稱", value: model.device.name.isEmpty ? "—" : model.device.name, strong: true)
            ValueRow(label: "代號", value: "\(model.device.code)（單號開頭）")
            ValueRow(label: "崗位", value: roleText)
            ValueRow(label: "店家", value: model.store.name)
            ValueRow(label: "後台", value: cmsText)
            if let p = model.pairing {
                ValueRow(label: "配對時間", value: p.pairedAt.dayText)
            }
            ValueRow(label: "App 版本", value: Bundle.main.appVersion)
            if model.isDemo {
                StatusBadge("示範模式：虛構的店，資料只在這次開著的時候", tone: .gold)
                    .padding(.top, 4)
            }
        }
        .panel(padding: 22)
    }

    /// 「結帳櫃台」；在這台改過的話也寫後台設的是什麼
    private var roleText: String {
        if model.role == model.device.role { return model.role.label }
        return "\(model.role.label)（後台設定：\(model.device.role.label)）"
    }

    private var cmsText: String {
        if let p = model.pairing { return p.cmsURL.absoluteString }
        return model.isDemo ? "沒有連後台（示範）" : "—"
    }

    private var syncPanel: some View {
        let status = model.syncStatus
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SettingsHealthDot(health: status.health, demo: model.isDemo)
                Text(model.isDemo ? "示範模式：資料不會送到後台" : status.label)
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
            }
            ValueRow(label: "還沒送出", value: "\(status.pending) 筆")
            ValueRow(label: "上次同步", value: status.lastSyncAt?.relativeText ?? "還沒同步過")
            if let e = status.lastError, status.health != .synced, !model.isDemo {
                Text(e)
                    .font(.brand(13.5, .medium))
                    .foregroundStyle(Theme.dangerFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rule(color: Theme.hair)
            Text("單子每 15 秒自動同步、有新動作時馬上送；右邊的「立即同步」現在就送出、拉回別台的，「重新抓設定」重抓菜單、人員、桌位與發票號碼。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    private func syncNow() async {
        syncing = true
        let status = await model.syncNow()
        syncing = false
        guard let status else {
            model.show("還沒連上後台", tone: .warning)
            return
        }
        model.show("同步：\(status.label)", tone: status.health == .synced ? .active : .warning)
    }

    private func refresh() async {
        refreshing = true
        await model.refreshBootstrap()
        refreshing = false
        model.show("已重新抓設定", tone: .neutral)
    }

    private var meshPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if model.mesh.running {
                    LiveDot()
                } else {
                    Circle()
                        .fill(Theme.faint)
                        .frame(width: 7, height: 7)
                }
                Text("區網同步")
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                StatusBadge(meshText, tone: meshTone)
            }
            Text("同一個 Wi-Fi 的 iPad 直接互傳（加密），網路斷了也看得到別台點的單。")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !model.mesh.peers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.mesh.peers, id: \.self) { id in
                        HStack(spacing: 8) {
                            HeroIcon("device-phone-mobile", size: 15)
                                .foregroundStyle(Theme.ink2)
                            Text(String(id.prefix(8)) + "…")
                                .font(.brand(13.5, .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Text("連線中")
                                .textRole(.xs)
                                .foregroundStyle(Theme.successFG)
                        }
                    }
                }
            }
        }
        .panel(padding: 22)
    }

    private var meshText: String {
        if model.mesh.running { return model.mesh.peers.isEmpty ? "開著・找不到別台" : "\(model.mesh.peers.count) 台連線中" }
        return model.meshConfig?.enabled == true ? "沒有啟動" : "後台沒開"
    }

    private var meshTone: Tone {
        if model.mesh.running { return model.mesh.peers.isEmpty ? .neutral : .active }
        return .neutral
    }
}

private struct SettingsHealthDot: View {
    let health: SyncStatus.Health
    let demo: Bool

    var body: some View {
        if health == .synced && !demo {
            LiveDot()
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    private var color: Color {
        if demo { return Theme.xenaViolet }
        switch health {
        case .synced: return Theme.live
        case .syncing: return Theme.infoFG
        case .offline, .paused: return Theme.warningFG
        case .attention: return Theme.dangerFG
        }
    }
}

// MARK: - 營業模式

private struct SettingsModeSection: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let explicit = chosenMode
        let fallback = model.store.defaultServiceMode
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "營業模式", detail: "同一套 POS 用在不同的店、不同的時段。每台 iPad 自己選；換了之後側欄、開單、結帳的順序跟著變。")
            VStack(spacing: 10) {
                SettingsModeOption(title: "跟後台一樣", detail: "後台的預設：\(fallback.label)・\(fallback.summary)",
                                   examples: "例如：\(fallback.examples)", icon: "cloud", selected: explicit == nil) {
                    if explicit != nil { model.setMode(nil) }
                }
                ForEach(model.store.serviceModes, id: \.self) { m in
                    SettingsModeOption(title: m.label, detail: m.summary, examples: "例如：\(m.examples)", icon: icon(m), selected: explicit == m) {
                        if explicit != m { model.setMode(m) }
                    }
                }
            }
            Text("現在：\(model.mode.label)。後台可以關掉某些模式，關掉的就不會出現在這裡。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
    }

    /// 這台自己選的（後台還開著那個模式才算）；nil＝跟後台一樣
    private var chosenMode: ServiceMode? {
        guard let m = ServiceMode(rawValue: model.settings.serviceMode), model.store.serviceModes.contains(m) else { return nil }
        return m
    }

    private func icon(_ m: ServiceMode) -> String { m.icon }
}

/// 一張可以選的卡：圖示、名字（＋小標籤）、說明、例子、右邊的圓點
private struct SettingsModeOption: View {
    let title: String
    let detail: String
    var examples: String? = nil
    var tags: [String] = []
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                HeroIcon(icon, size: 22)
                    .foregroundStyle(selected ? Theme.accentText : Theme.ink2)
                    .frame(width: 42, height: 42)
                    .background(selected ? Theme.accentSoft : Theme.press, in: .rect(cornerRadius: Metric.radius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.brand(16, .semibold))
                            .foregroundStyle(Theme.ink)
                        ForEach(tags, id: \.self) { t in
                            StatusBadge(t, tone: t == "現在" ? .gold : .neutral)
                        }
                    }
                    Text(detail)
                        .font(.brand(13, .regular))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let examples {
                        Text(examples)
                            .font(.brand(12, .regular))
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: 1.5)
                    if selected {
                        Circle()
                            .fill(Theme.accent)
                            .padding(5)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(16)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 崗位

/// 這台放在店裡的哪個位置：決定側欄有哪些頁、先看哪一頁、能不能收錢開錢櫃（資料每台都一樣）
private struct SettingsWorkstationSection: View {
    @Environment(POSModel.self) private var model
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "崗位", detail: "這台 iPad 放在店裡的哪個位置。崗位決定側欄有哪些頁、先看哪一頁、能不能收錢開錢櫃；每台看到的單都一樣。換崗位要店長授權。")
            VStack(spacing: 10) {
                ForEach(DeviceRole.allCases, id: \.self) { r in
                    SettingsModeOption(title: r.label, detail: r.summary, examples: abilities(r), tags: tags(r),
                                       icon: icon(r), selected: model.role == r) {
                        choose(r)
                    }
                    .disabled(busy)
                }
            }
            Text("後台配對時設的是「\(model.device.role.label)」；在這裡改只影響這台，心跳會回報給後台。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tags(_ r: DeviceRole) -> [String] {
        var out: [String] = []
        if r == model.device.role { out.append("後台設定") }
        if r == model.role { out.append("現在") }
        return out
    }

    /// 「收錢・錢櫃・開單」：一眼看出這個崗位能做什麼
    private func abilities(_ r: DeviceRole) -> String {
        var parts: [String] = []
        if r.takesPayment { parts.append("收錢") }
        if r.hasDrawer { parts.append("錢櫃與交班") }
        if r.takesOrders { parts.append("開單") }
        if r.isKitchen { parts.append("出單進度") }
        return parts.isEmpty ? "只看" : parts.joined(separator: "・")
    }

    private func icon(_ r: DeviceRole) -> String {
        switch r {
        case .register: "banknotes"
        case .handheld: "device-phone-mobile"
        case .kitchen: "fire"
        case .reception: "user-group"
        case .expo: "bell-alert"
        }
    }

    /// 選回後台設的那個＝nil（之後後台改了也跟著）；setRole 自己會請店長授權、跳到新崗位的首頁
    private func choose(_ r: DeviceRole) {
        guard r != model.role, !busy else { return }
        busy = true
        Task {
            await model.setRole(r == model.device.role ? nil : r)
            busy = false
        }
    }
}

// MARK: - 門市設定（後台的，只能看）

private struct SettingsStoreSection: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "門市設定", detail: "在後台「門市 POS → 設定」改，改了這台會自動拿到；這裡只能看。")
            rulesPanel
            invoicingPanel
            staffPanel
        }
    }

    private var rulesPanel: some View {
        let store = model.store
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("規則")
            ValueRow(label: "換貨期限", value: store.exchangeDays > 0 ? "結帳後 \(store.exchangeDays) 天內" : "不限")
            ValueRow(label: "預約一格", value: "\(store.bookingSlotMinutes) 分鐘")
            ValueRow(label: "營業日分界", value: "凌晨 \(store.businessDayCutoffHour) 點（之前算前一天）")
            ValueRow(label: "不用授權的折扣上限", value: percentText(bps: store.discountLimitBps))
            if store.serviceChargeBps > 0 {
                ValueRow(label: "服務費", value: "\(percentText(bps: store.serviceChargeBps))（\(store.serviceChargeOn.map(\.label).joined(separator: "、"))）")
            }
        }
        .panel(padding: 22)
    }

    /// 儲值金的發票什麼時候開：兩種都列出來、標出這家店用哪一種
    private var invoicingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("儲值金發票")
            ForEach(PrepaidInvoicing.allCases, id: \.self) { p in
                let current = p == model.store.prepaidInvoicing
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HeroIcon(current ? "check-circle" : "minus", size: 16)
                        .foregroundStyle(current ? Theme.successFG : Theme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.label)
                            .font(.brand(15, current ? .semibold : .regular))
                            .foregroundStyle(current ? Theme.ink : Theme.muted)
                        Text(explain(p))
                            .font(.brand(12.5, .regular))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .panel(padding: 22)
    }

    private func explain(_ p: PrepaidInvoicing) -> String {
        switch p {
        case .atTopUp: "客人儲值（收錢）時就開發票；之後用儲值金付的部分不再開"
        case .atRedemption: "儲值時不開；客人用儲值金消費時才開（像現金禮券）"
        }
    }

    private var staffPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("人員・\(model.staff.count) 位")
            if model.staff.isEmpty {
                Text("後台還沒有設定人員")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.staff) { m in
                        SettingsStaffRow(member: m)
                        if m.id != model.staff.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .panel(padding: 22)
    }
}

/// 一位人員：名字、職稱、權限、排不排預約、抽成
private struct SettingsStaffRow: View {
    let member: StaffMember

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StaffAvatar(name: member.name, swatch: member.swatch, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if member.isBookable {
                StatusBadge("排預約", tone: .info)
            }
            if let bps = member.commissionBps, bps > 0 {
                Text("抽成 \(percentText(bps: bps))")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// 「設計師・店長」；沒有職稱就只寫權限
    private var subtitle: String {
        if let t = member.title, !t.isEmpty { return "\(t)・\(member.role.label)" }
        return member.role.label
    }
}

// MARK: - 出單機：列表

private struct SettingsPrinterList: View {
    @Environment(POSModel.self) private var model
    @Environment(PrinterHub.self) private var printers
    let edit: (PrinterConfig) -> Void
    let add: () -> Void
    let preview: (PrintJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "出單機", detail: "網路（Wi-Fi、網路線，埠 9100）或藍牙 BLE 的熱感機；每台自己選 58 或 80 mm。設定存在這台 iPad。點一台編輯；新增在右邊。")
            if printers.printers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("還沒有出單機")
                        .textRole(.h4)
                        .foregroundStyle(Theme.ink2)
                    Text("沒有出單機時照樣可以營業：要印的收據、證明聯會留在下面的「最近列印」，在畫面上看得到。")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel(padding: 22)
            } else {
                // 整列點一下＝編輯（測試列印、刪除都在編輯裡）；列上不放按鈕
                VStack(spacing: 0) {
                    ForEach(printers.printers) { p in
                        Button {
                            edit(p)
                        } label: {
                            SettingsPrinterRow(printer: p)
                        }
                        .buttonStyle(.row)
                        .accessibilityHint("編輯、測試列印")
                        if p.id != printers.printers.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: Metric.radius, style: .continuous))
                .panel(padding: 0)
            }
            // 單據樣式（後台的 printStyle）：每種單據印出來的樣子、測試列印
            PrintStyleEntry()
            recent
        }
        // 右欄（這一頁的動作）：大鍵「新增出單機」
        .dockSelection(DockSelection.page("settings-printers", primary: POSAction("新增出單機", icon: "plus") { add() }))
    }

    @ViewBuilder
    private var recent: some View {
        let jobs = Array(printers.recent.prefix(15))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("最近列印")
                Spacer(minLength: 8)
                Text("點一下看印了什麼")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            if jobs.isEmpty {
                Text("還沒有印過東西")
                    .textRole(.small)
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(jobs) { job in
                        Button {
                            preview(job)
                        } label: {
                            SettingsPrintJobRow(job: job)
                        }
                        .buttonStyle(.row)
                        if job.id != jobs.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: Metric.radius, style: .continuous))
                .panel(padding: 0)
            }
        }
    }
}

private struct SettingsPrinterRow: View {
    @Environment(PrinterHub.self) private var printers
    let printer: PrinterConfig

    var body: some View {
        let health = printers.status[printer.id]
        HStack(alignment: .center, spacing: 14) {
            HeroIcon(printer.connection == .bluetooth ? "signal" : "printer", size: 22)
                .foregroundStyle(Theme.ink2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(printer.name.isEmpty ? "未命名" : printer.name)
                        .font(.brand(16, .semibold))
                        .foregroundStyle(Theme.ink)
                    statusBadge(health)
                }
                Text(addressLine)
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                Text(rolesLine)
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
                if let h = health, !h.ok, let m = h.message {
                    Text(m)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.dangerFG)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HeroIcon("chevron-right", size: 14)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func statusBadge(_ h: PrinterHealth?) -> some View {
        if let h {
            StatusBadge(h.ok ? "正常" : "連不到", tone: h.ok ? .active : .danger)
        } else {
            StatusBadge("還沒印過", tone: .neutral)
        }
    }

    /// 「192.168.1.50・80 mm」「藍牙・58 mm・MTP-II」
    private var addressLine: String {
        switch printer.connection {
        case .network:
            let host = printer.host.isEmpty ? "沒有 IP" : printer.host
            let address = printer.port == 9100 ? host : "\(host):\(printer.port)"
            return "\(address)・\(printer.paper.label)・\(PrintMethod.label(printer.encoding, style: printers.style))"
        case .bluetooth:
            let device = printer.peripheralName.map { "・\($0)" } ?? "・還沒選裝置"
            return "藍牙・\(printer.paper.label)・\(PrintMethod.label(printer.encoding, style: printers.style))\(device)"
        }
    }

    /// 「收據、發票證明聯・錢櫃」「廚房出單（吧台）」
    private var rolesLine: String {
        var parts = PrinterRole.allCases.filter { printer.roles.contains($0) }.map(\.label)
        if printer.roles.contains(.kitchen) && !printer.stations.isEmpty {
            parts.append("只印 \(printer.stations.joined(separator: "、"))")
        }
        if printer.hasDrawer { parts.append("錢櫃") }
        return parts.isEmpty ? "還沒設定要印什麼" : parts.joined(separator: "・")
    }
}

private struct SettingsPrintJobRow: View {
    let job: PrintJob

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HeroIcon(job.image != nil ? "qr-code" : "document-text", size: 18)
                .foregroundStyle(Theme.ink2)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(job.at.clockText)・\(job.printer ?? "沒有出單機，只在畫面上")")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if let e = job.error {
                    Text(e)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.dangerFG)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            badge
            HeroIcon("chevron-right", size: 14)
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var badge: some View {
        if job.error != nil {
            StatusBadge("失敗", tone: .danger)
        } else if job.printer == nil {
            StatusBadge("預覽", tone: .neutral)
        } else {
            StatusBadge("已送出", tone: .active)
        }
    }
}

/// 印了什麼（收據照紙寬畫出來；證明聯是圖）
private struct SettingsPrintPreview: View {
    let job: PrintJob
    let paper: PaperWidth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: job.title, subtitle: "列印預覽", close: { dismiss() })
            Rule()
            ScrollView {
                VStack(spacing: 20) {
                    if let e = job.error {
                        Banner(text: e, tone: .danger)
                    }
                    Text("\(job.at.shortText)・\(job.printer ?? "沒有出單機")")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                    if let img = job.image {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: 300)
                            .padding(12)
                            // 印出來的證明聯：熱感紙是白的（單據例外，深、淺色都一樣）
                            .background(Color.white, in: .rect(cornerRadius: Metric.radius))
                            .accessibilityLabel(job.title)
                    }
                    if let r = job.receipt {
                        ReceiptPaper(receipt: r, paper: paper)
                            // 手機比 80 mm 的紙窄：最寬到那麼寬、不撐出畫面
                            .frame(maxWidth: paper == .mm58 ? 300 : 380)
                            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                            .overlay {
                                RoundedRectangle(cornerRadius: Metric.radius)
                                    .strokeBorder(Theme.line, lineWidth: 1)
                            }
                    }
                    if job.image == nil && job.receipt == nil {
                        Text("這一張沒有內容可以預覽（例如開錢櫃）")
                            .textRole(.small)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.sheet)
        .posSheet()
    }
}

// MARK: - 出單機：新增／編輯

private struct SettingsPrinterEditor: View {
    @Environment(POSModel.self) private var model
    @Environment(PrinterHub.self) private var printers
    @Binding var config: PrinterConfig
    let isNew: Bool
    let stations: [String]
    let save: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    @State private var confirmDelete = false

    private var trimmedName: String { config.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHost: String { config.host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 網路要有 IP；藍牙要選好裝置
    private var canConnect: Bool {
        switch config.connection {
        case .network: !trimmedHost.isEmpty
        case .bluetooth: config.peripheralId != nil
        }
    }

    private var canSave: Bool { !trimmedName.isEmpty && canConnect }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            connectionPanel
            paperPanel
            rolesPanel
            PrintMethodPanel(encoding: $config.encoding, style: printers.style)
            drawerPanel
        }
        .dockSelection(editorDock)
        .onDisappear { BluetoothPrinters.shared.stopScan() }
        .confirmationDialog("刪除「\(config.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive, action: delete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("之後要印的東西不會再送到這台。")
        }
    }

    /// 表單在左邊；儲存、測試列印、刪除在右欄。回列表＝右欄的 ×
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(isNew ? "出單機・新增" : "出單機・編輯")
            Text(trimmedName.isEmpty ? "未命名" : trimmedName)
                .textRole(.h3)
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: 連線

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("怎麼連")
            HStack(spacing: 10) {
                ForEach(PrinterConnection.allCases, id: \.self) { c in
                    Button {
                        config.connection = c
                    } label: {
                        VStack(spacing: 4) {
                            HeroIcon(c == .network ? "wifi" : "signal", size: 20)
                            Text(c.label)
                                .font(.brand(15, .semibold))
                            Text(connectionHint(c))
                                .font(.brand(12, .regular))
                                .opacity(0.7)
                        }
                    }
                    .buttonStyle(.choice(config.connection == c, height: 88))
                }
            }
            SettingsField(label: "名稱", hint: "畫面、錯誤訊息上用的名字") {
                TextField("例如：櫃台、廚房、吧台", text: $config.name)
                    .settingsInput()
            }
            switch config.connection {
            case .network:
                networkFields
            case .bluetooth:
                SettingsBluetoothPicker(config: $config)
            }
        }
        .panel(padding: 22)
    }

    private func connectionHint(_ c: PrinterConnection) -> String {
        switch c {
        case .network: "Wi-Fi、網路線"
        case .bluetooth: "BLE 熱感機"
        }
    }

    private var networkFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsField(label: "IP 位址", hint: "出單機自我測試頁上印的位址（例如 192.168.1.50）") {
                TextField("192.168.1.50", text: $config.host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsInput()
            }
            SettingsField(label: "連接埠", hint: "網路出單機幾乎都是 9100") {
                Button {
                    Task { await askPort() }
                } label: {
                    HStack(spacing: 10) {
                        Text(String(config.port))
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
                .accessibilityLabel("連接埠 \(config.port)，在右側鍵盤改")
            }
        }
    }

    /// 連接埠：數字一律在右側鍵盤打
    private func askPort() async {
        let spec = KeypadSpec(kind: .code(minLength: 2, maxLength: 5), title: "連接埠", subtitle: "網路出單機通常是 9100",
                              initial: String(config.port), quickKeys: [.init("9100", digits: "9100", commits: true)], confirmLabel: "設定")
        guard let port = await model.keypad.askNumber(spec, validate: { (1...65535).contains($0) ? nil : "連接埠是 1 到 65535" }) else { return }
        config.port = port
    }

    // MARK: 紙寬

    private var paperPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("紙寬")
            HStack(spacing: 10) {
                ForEach(PaperWidth.allCases, id: \.self) { w in
                    Button {
                        config.paper = w
                    } label: {
                        VStack(spacing: 4) {
                            Text(w.label)
                                .font(.brand(22, .semibold))
                                .monospacedDigit()
                            Text(paperHint(w))
                                .font(.brand(12, .regular))
                                .opacity(0.7)
                        }
                    }
                    .buttonStyle(.choice(config.paper == w, height: 92))
                }
            }
            Text("58 mm＝電子發票證明聯、小單；80 mm＝收據、廚房單、交班單（證明聯在 80 mm 機器上也會照 5.7 公分寬印）。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    private func paperHint(_ w: PaperWidth) -> String {
        switch w {
        case .mm58: "證明聯、小單"
        case .mm80: "收據、廚房單、交班單"
        }
    }

    // MARK: 印什麼

    private var rolesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("這台印什麼")
            ForEach(PrinterRole.allCases, id: \.self) { role in
                Toggle(isOn: roleBinding(role)) {
                    SettingsToggleLabel(title: role.label, detail: roleDetail(role))
                }
            }
            if config.roles.contains(.kitchen) && !stations.isEmpty {
                Rule(color: Theme.hair)
                VStack(alignment: .leading, spacing: 10) {
                    Text("只印這幾站（都不選＝全部）")
                        .font(.brand(13.5, .semibold))
                        .foregroundStyle(Theme.ink2)
                    FlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(stations, id: \.self) { s in
                            OptionChip(title: s, selected: config.stations.contains(s)) { toggleStation(s) }
                        }
                    }
                }
            }
        }
        .panel(padding: 22)
    }

    private func roleBinding(_ role: PrinterRole) -> Binding<Bool> {
        Binding(
            get: { config.roles.contains(role) },
            set: { on in
                if on {
                    config.roles.insert(role)
                } else {
                    config.roles.remove(role)
                }
            }
        )
    }

    private func roleDetail(_ role: PrinterRole) -> String {
        switch role {
        case .receipt: "交易明細、結帳單、交班單、退款單"
        case .invoice: "電子發票證明聯（一律照 5.7 公分寬印）"
        case .kitchen: "送單、催菜、作廢時的廚房、吧台出單"
        case .queue: "叫號的號碼牌：這台取號就印（照後台的版面畫成圖，和樹莓派印的一樣）"
        }
    }

    private func toggleStation(_ s: String) {
        if let i = config.stations.firstIndex(of: s) {
            config.stations.remove(at: i)
        } else {
            config.stations.append(s)
        }
    }

    // MARK: 列印方式（PrintStyleSettings.swift）、錢櫃

    private var drawerPanel: some View {
        Toggle(isOn: $config.hasDrawer) {
            SettingsToggleLabel(title: "錢櫃接在這台", detail: "收現金、開班、存入取出、只開錢櫃時打開")
        }
        .panel(padding: 22)
    }

    // MARK: 存

    /// 右欄：選起來的這台出單機。大鍵「加入／儲存」（品牌橘）；動作鍵「測試列印」、藍牙的「搜尋」、「刪除」（紅字、要確認）。× 回列表（不存）
    private var editorDock: DockSelection {
        var actions: [POSAction] = [POSAction("測試列印", icon: "printer", enabled: canConnect) { testPrint() }]
        if config.connection == .bluetooth {
            actions.append(POSAction(BluetoothPrinters.shared.scanning ? "停止搜尋" : "搜尋藍牙出單機", icon: "magnifying-glass") {
                if BluetoothPrinters.shared.scanning {
                    BluetoothPrinters.shared.stopScan()
                } else {
                    BluetoothPrinters.shared.startScan()
                }
            })
        }
        if !isNew {
            actions.append(POSAction("刪除這台", icon: "trash", destructive: true) { confirmDelete = true })
        }
        return DockSelection(
            id: "settings-printer-\(config.id)",
            kind: isNew ? "新增出單機" : "出單機",
            title: trimmedName.isEmpty ? "未命名" : trimmedName,
            detail: dockDetail,
            badge: canSave ? nil : DockBadge(trimmedName.isEmpty ? "要取名字" : "還沒設定連線", tone: .warning),
            primary: POSAction(isNew ? "加入" : "儲存", icon: "check", enabled: canSave) { save() },
            accent: true,
            actions: actions,
            clear: { cancel() }
        )
    }

    /// 「網路・192.168.1.50・80 mm」「藍牙・58 mm・MTP-II」
    private var dockDetail: String {
        switch config.connection {
        case .network:
            return "網路・\(trimmedHost.isEmpty ? "沒有 IP" : trimmedHost)・\(config.paper.label)"
        case .bluetooth:
            return "藍牙・\(config.paper.label)・\(config.peripheralName ?? "還沒選裝置")"
        }
    }

    private func testPrint() {
        var p = config
        p.host = trimmedHost
        printers.test(p, store: model.store)
        model.show("已送出測試頁", tone: .neutral)
    }
}

/// 藍牙：搜尋附近的出單機、點一台選起來
private struct SettingsBluetoothPicker: View {
    @Binding var config: PrinterConfig

    private var bluetooth: BluetoothPrinters { BluetoothPrinters.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = config.peripheralId {
                HStack(spacing: 10) {
                    HeroIcon("check-circle", size: 18)
                        .foregroundStyle(Theme.successFG)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.peripheralName ?? "藍牙出單機")
                            .font(.brand(15.5, .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(String(id.prefix(8)) + "…")
                            .textRole(.xs)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    Text("已選這台")
                        .textRole(.xs)
                        .foregroundStyle(Theme.successFG)
                }
                .padding(14)
                .background(Tone.active.background, in: .rect(cornerRadius: Metric.radius, style: .continuous))
            }
            // 「搜尋藍牙出單機」在右欄（動作鍵）；這裡只顯示狀態與找到的機器（點一台選起來）
            HStack(spacing: 12) {
                if bluetooth.scanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("搜尋中…")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                } else if bluetooth.found.isEmpty {
                    Text("按右邊的「搜尋藍牙出單機」找附近的機器")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            if let problem = bluetooth.problem {
                Banner(text: problem, tone: .warning)
            }
            if !bluetooth.found.isEmpty {
                VStack(spacing: 0) {
                    ForEach(bluetooth.found) { info in
                        Button {
                            choose(info)
                        } label: {
                            SettingsBLERow(info: info, selected: info.id == config.peripheralId)
                        }
                        .buttonStyle(.row)
                        if info.id != bluetooth.found.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: Metric.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
            } else if bluetooth.scanning {
                Text("把出單機打開、放在 iPad 旁邊")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            Text("只支援 BLE 的機器；傳統藍牙（SPP）的出單機 iPad 連不上，買機器時請選「支援 BLE」的。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose(_ info: BLEPrinterInfo) {
        config.peripheralId = info.id
        config.peripheralName = info.name
        if config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.name = info.name
        }
        bluetooth.stopScan()
    }
}

private struct SettingsBLERow: View {
    let info: BLEPrinterInfo
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < info.bars ? Theme.ink : Theme.line)
                        .frame(width: 4, height: CGFloat(6 + i * 4))
                }
            }
            .frame(width: 18, height: 16, alignment: .bottomLeading)
            .accessibilityLabel("訊號 \(info.bars) 格")
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink)
                Text("\(info.rssi) dBm")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if selected {
                HeroIcon("check", size: 16)
                    .foregroundStyle(Theme.accentText)
            } else {
                Text("選這台")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

// MARK: - 收據與出單

private enum SettingsReceiptMode: String, CaseIterable, Identifiable {
    case always, ask, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "每張都印"
        case .ask: "問客人"
        case .never: "不印"
        }
    }

    var detail: String {
        switch self {
        case .always: "結帳就印交易明細"
        case .ask: "結帳後跳出來問"
        case .never: "要的時候到訂單補印"
        }
    }
}

private struct SettingsReceiptsSection: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "收據與出單", detail: "這台 iPad 自己的習慣，換一台要另外設。")
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("交易明細")
                HStack(spacing: 10) {
                    ForEach(SettingsReceiptMode.allCases) { m in
                        Button {
                            model.settings.receiptMode = m.rawValue
                        } label: {
                            VStack(spacing: 4) {
                                Text(m.title)
                                    .font(.brand(15, .semibold))
                                Text(m.detail)
                                    .font(.brand(12, .regular))
                                    .opacity(0.7)
                            }
                        }
                        .buttonStyle(.choice(settings.receiptMode == m.rawValue, height: 76))
                    }
                }
                Text("電子發票證明聯照規定印，不受這個設定影響。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            .panel(padding: 22)
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $settings.printKitchenTickets) {
                    SettingsToggleLabel(title: "印廚房出單", detail: "送單、催菜、作廢時，印到負責那一站的出單機")
                }
                if settings.printKitchenTickets && model.takesPayment {
                    Rule(color: Theme.hair)
                    Toggle(isOn: $settings.printKitchenForOthers) {
                        SettingsToggleLabel(title: "幫手機出廚房單",
                                            detail: "前場的手機沒有出單機：它送的單由這台印到廚房。有好幾台櫃台時只留一台打開，才不會印兩張")
                    }
                }
                Rule(color: Theme.hair)
                Toggle(isOn: $settings.openDrawerOnCash) {
                    SettingsToggleLabel(title: "收現金時開錢櫃", detail: "收現金、現金退款時自動打開")
                }
            }
            .panel(padding: 22)
        }
    }
}

// MARK: - 電子發票

private struct SettingsInvoiceSection: View {
    @Environment(POSModel.self) private var model
    @State private var requesting = false

    private var enabled: Bool { model.features.invoice && model.invoiceSettings.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "電子發票", detail: "號碼段由後台配給這台；剩不到 10 張、或下一期快開始時，連上網會自動補。")
            statusPanel
            if enabled {
                rollsPanel
            }
        }
        .dockSelection(pageDock)
    }

    /// 右欄（這一頁的動作）：「向後台要號碼」（有開發票才有）
    private var pageDock: DockSelection? {
        guard enabled else { return nil }
        return DockSelection.page("settings-invoice", actions: [
            POSAction(requesting ? "要號碼中…" : "向後台要號碼", icon: "arrow-down-tray", enabled: !requesting) {
                Task { await topUp() }
            },
        ])
    }

    private var statusPanel: some View {
        let s = model.invoiceSettings
        let left = model.invoiceNumbersLeft
        let hasKey = !(s.qrKey ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(enabled ? "開立中" : "沒有開")
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                StatusBadge(statusInfo.text, tone: statusInfo.tone)
                Spacer(minLength: 8)
            }
            if !enabled {
                Text("這家店沒有開電子發票。要開請到後台「門市 POS → 電子發票」。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            } else if let p = s.problem {
                Banner(text: p, tone: .danger)
            }
            ValueRow(label: "賣方", value: s.sellerName.isEmpty ? "—" : s.sellerName)
            ValueRow(label: "統一編號", value: s.sellerTaxId.isEmpty ? "—" : s.sellerTaxId)
            if enabled {
                ValueRow(label: "本期", value: model.invoicePeriod.label)
                ValueRow(label: "這期還剩", value: "\(left) 張", strong: true, tone: leftColor(left))
                ValueRow(label: "QR Code 金鑰", value: hasKey ? "已設定" : "沒有（證明聯不會印 QR Code）", tone: hasKey ? Theme.ink : Theme.warningFG)
            }
        }
        .panel(padding: 22)
    }

    private var statusInfo: (text: String, tone: Tone) {
        guard enabled else { return ("關閉", .neutral) }
        if model.invoiceSettings.problem != nil { return ("設定不齊", .danger) }
        return ("設定齊全", .active)
    }

    private func leftColor(_ left: Int) -> Color {
        if left == 0 { return Theme.dangerFG }
        if left < 10 { return Theme.warningFG }
        return Theme.ink
    }

    private var rollsPanel: some View {
        let rolls = model.invoiceSettings.rolls.sorted { ($0.period, $0.track, $0.start) < ($1.period, $1.track, $1.start) }
        let allocator = model.allocator
        let current = model.invoicePeriod.code
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("號碼段・\(rolls.count) 本")
            if rolls.isEmpty {
                Text("這台還沒有號碼段。連上網路後按右邊的「向後台要號碼」。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(rolls) { r in
                        SettingsRollRow(roll: r, next: allocator.next(in: r), current: current)
                        if r.id != rolls.last?.id {
                            Rule(color: Theme.hair)
                        }
                    }
                }
            }
        }
        .panel(padding: 22)
    }

    private func topUp() async {
        requesting = true
        let before = model.invoiceSettings.rolls.count
        await model.topUpInvoiceRolls()
        requesting = false
        if model.invoiceSettings.rolls.count > before {
            model.show("拿到新的發票號碼段")
        } else if model.invoiceNumbersLeft >= 10 {
            model.show("號碼還夠，現在不用補", tone: .neutral)
        } else {
            model.show("沒有拿到號碼（離線，或後台沒有字軌）", tone: .warning)
        }
    }
}

private struct SettingsRollRow: View {
    let roll: InvoiceRoll
    /// 下一張是幾號（用完了是 nil）
    let next: Int?
    /// 本期的期別代碼（11510）
    let current: String

    var body: some View {
        let remaining = next.map { roll.end - $0 + 1 } ?? 0
        let used = roll.count - remaining
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(roll.label)
                    .font(.brand(14.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                StatusBadge(badge(remaining: remaining).text, tone: badge(remaining: remaining).tone)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(InvoicePeriod(code: roll.period)?.label ?? roll.period)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Text("剩 \(remaining)／\(roll.count) 張")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
            SettingsMeter(ratio: roll.count > 0 ? Double(used) / Double(roll.count) : 1, color: remaining == 0 ? Theme.faint : Theme.accent)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func badge(remaining: Int) -> (text: String, tone: Tone) {
        if remaining == 0 { return ("用完", .neutral) }
        if roll.period == current { return ("本期", .active) }
        if roll.period > current { return ("下一期", .info) }
        return ("過期", .neutral)
    }
}

// MARK: - 叫號

/// 叫號：號碼存在哪裡（後台的）、號碼牌出單機、這台要不要也印別台取的、要不要唸號碼；右邊是號碼牌的預覽。
/// 右欄：大鍵「印一張測試號碼牌」
private struct SettingsQueueSection: View {
    @Environment(POSModel.self) private var model
    @Environment(PrinterHub.self) private var printers
    /// 打開「出單機」
    let openPrinters: () -> Void

    var body: some View {
        @Bindable var settings = model.settings
        let queuePrinters = printers.targets(.queue)
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "叫號", detail: "號碼牌由這台 iPad 直接印，不用樹莓派。號碼存在哪裡、號碼牌的版面在後台設定；這裡是這台自己的習慣。")
            if !model.features.queue {
                Text("後台沒有開叫號")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        infoPanel
                        printerPanel(queuePrinters)
                        VStack(alignment: .leading, spacing: 18) {
                            Toggle(isOn: Binding(get: { model.settings.queuePrintsOthers }, set: { model.setQueuePrintsOthers($0) })) {
                                SettingsToggleLabel(
                                    title: "也印別台取的號碼（取代樹莓派）",
                                    detail: queuePrinters.isEmpty
                                        ? "要先有號碼牌出單機。"
                                        : "別台 iPad 取的號碼，這台看到就印（同一個營業日不重複，號碼從 1 重新開始時重算；打開時已經在等的不補印）。一家店只開一台。"
                                )
                            }
                            .disabled(queuePrinters.isEmpty)
                            Rule(color: Theme.hair)
                            Toggle(isOn: $settings.queueSpeaks) {
                                SettingsToggleLabel(title: "這台唸號碼", detail: "按「下一號」「再叫一次」時用 iPad 的喇叭唸出來（叫號螢幕會唸的話不用開）")
                            }
                        }
                        .panel(padding: 22)
                        HStack(alignment: .top, spacing: 10) {
                            HeroIcon("information-circle", size: 16)
                                .padding(.top, 2)
                            Text("樹莓派只要負責叫號螢幕：在它的後台把列印關掉，避免印兩張")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    preview
                }
            }
        }
        .dockSelection(DockSelection.page(
            "settings-queue",
            primary: POSAction("印一張測試號碼牌", icon: "printer", enabled: model.features.queue) { model.printTestQueueTicket() }
        ))
        .task { await model.queue.art.prefetch(model.queueConfig?.ticket.backgroundUrl) }
    }

    private var infoPanel: some View {
        let ticket = model.queueConfig?.ticket ?? .standard
        return VStack(alignment: .leading, spacing: 12) {
            ValueRow(label: "號碼存在", value: model.queueMode.label, strong: true)
            ValueRow(label: "用在", value: usageText)
            ValueRow(label: "號碼牌的 QR", value: model.queueConfig?.customerUrl == nil ? "沒有設定（不印 QR）" : "客人掃了看現在叫到幾號")
            ValueRow(label: "版面", value: layoutText(ticket))
            ValueRow(label: "一個號碼印", value: "\(ticket.copies) 張")
        }
        .panel(padding: 22)
    }

    /// 叫號用在哪裡（後台的設定，這裡只能看）：「外帶取餐（結帳完成時自動取號）」
    private var usageText: String {
        let usage = model.queueConfig?.usage ?? []
        guard !usage.isEmpty else { return "只有叫號頁（店員自己取號、叫號）" }
        return QueueUsage.allCases.filter(usage.contains).map { u -> String in
            let how = u == .takeout ? "結帳完成時自動取號" : "取號問人數、叫號入座"
            return "\(u.label)（\(how)）"
        }.joined(separator: "、")
    }

    private func layoutText(_ t: QueueTicketLayout) -> String {
        guard let url = t.backgroundUrl else { return "StudioX 預設版面" }
        return model.queue.art.image(for: url) == nil ? "後台的背景圖（下載中，先用預設版面）" : "後台的背景圖"
    }

    private func printerPanel(_ list: [PrinterConfig]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("號碼牌出單機")
            if list.isEmpty {
                Text("這台還沒有號碼牌出單機。新增或編輯一台（例如 XPrinter 58 mm：網路埠 9100 或藍牙），在「這台印什麼」勾「號碼牌」。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { p in
                        HStack(spacing: 12) {
                            HeroIcon("printer", size: 18)
                                .foregroundStyle(Theme.ink2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name.isEmpty ? "出單機" : p.name)
                                    .font(.brand(15.5, .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(address(p))
                                    .font(.brand(12.5, .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            if let h = printers.status[p.id] {
                                StatusBadge(h.ok ? "正常" : "連不到", tone: h.ok ? .active : .danger)
                            }
                        }
                        .padding(.vertical, 8)
                        if p.id != list.last?.id { Rule(color: Theme.hair) }
                    }
                }
            }
            Button(list.isEmpty ? "設定出單機" : "改出單機", action: openPrinters)
                .buttonStyle(.brand(.ghost, size: .sm, arrow: true))
        }
        .panel(padding: 22)
    }

    private func address(_ p: PrinterConfig) -> String {
        let where_ = p.connection == .network ? (p.host.isEmpty ? "沒有 IP" : "\(p.host):\(p.port)") : "藍牙 \(p.peripheralName ?? "")"
        return "\(where_)・\(p.paper.label)"
    }

    /// 號碼牌的樣子（縮小）：下一張的號碼、現在的等候人數
    private var preview: some View {
        let ticket = model.sampleQueueTicket()
        let k: CGFloat = 0.56
        let height = ticket.background != nil ? CGFloat(ticket.layout.height) : QueueTicketView.standardHeight
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("號碼牌預覽")
            QueueTicketView(ticket: ticket)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: CGFloat(QueueTicketLayout.baseWidth) * k, height: height * k, alignment: .topLeading)
                .clipShape(.rect(cornerRadius: Metric.radiusSm, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous).strokeBorder(Theme.line, lineWidth: 1) }
                .accessibilityLabel("號碼牌預覽：\(ticket.number) 號，\(ticket.waitingText)")
            Text("印出來是黑白的（熱感紙）")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
        .frame(width: CGFloat(QueueTicketLayout.baseWidth) * k, alignment: .leading)
    }
}

// MARK: - 外觀與安全

private enum SettingsAppearance: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟著 iPad"
        case .dark: "深色"
        case .light: "淺色"
        }
    }

    var icon: String {
        switch self {
        case .system: "device-phone-mobile"
        case .dark: "moon"
        case .light: "sun"
        }
    }
}

private struct SettingsAppearanceSection: View {
    @Environment(POSModel.self) private var model

    private static let lockChoices = [0, 1, 3, 5, 10, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "外觀與安全")
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("外觀")
                HStack(spacing: 10) {
                    ForEach(SettingsAppearance.allCases) { a in
                        Button {
                            model.settings.appearance = a.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                HeroIcon(a.icon, size: 20)
                                Text(a.label)
                            }
                        }
                        .buttonStyle(.choice(current == a, height: 76))
                    }
                }
                Text("深色適合晚上、燈光暗的店；淺色在戶外、陽光下比較清楚。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            .panel(padding: 22)
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("菜單的字")
                MenuTextSizePicker(height: 76)
                Text("點餐頁卡片上的品名、價錢多大；字大了一排放少一點。只改這台，點餐頁上面的「Aa」也能換。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            .panel(padding: 22)
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("閒置自動鎖定")
                HStack(spacing: 8) {
                    ForEach(Self.lockChoices, id: \.self) { m in
                        Button(lockLabel(m)) {
                            model.settings.autoLockMinutes = m
                        }
                        .buttonStyle(.choice(model.settings.autoLockMinutes == m, height: 48))
                    }
                }
                Text("沒有人碰幾分鐘就回到 PIN 畫面；結帳中、右側鍵盤在問數字時不會鎖。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            .panel(padding: 22)
        }
    }

    private var current: SettingsAppearance {
        SettingsAppearance(rawValue: model.settings.appearance) ?? .system
    }

    private func lockLabel(_ m: Int) -> String {
        m == 0 ? "不自動" : "\(m) 分"
    }
}

// MARK: - 資料

/// 「檢查這台的資料」的結果
private struct SettingsChainCheck {
    let ok: Bool
    let message: String
    let own: Int
    let remote: Int
    let pending: Int
    let quarantined: Int
    let at: Date
}

private struct SettingsDataSection: View {
    @Environment(POSModel.self) private var model
    @State private var check: SettingsChainCheck?
    @State private var confirmUnpair = false
    @State private var confirmEndDemo = false
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "資料", detail: "每個動作先寫進這台 iPad 的日誌（一筆接一筆、有雜湊鏈），再送到後台；當機、沒電也不會掉。")
            checkPanel
        }
        // 右欄（這一頁的動作）：大鍵「檢查這台的資料」；解除配對／結束示範是紅字的動作鍵（要確認；解除配對還要店長授權）
        .dockSelection(DockSelection.page("settings-data", primary: POSAction("檢查這台的資料", icon: "shield-check") { runCheck() },
                                          actions: leaveActions))
        .confirmationDialog("解除配對？", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("解除配對並清掉這台的資料", role: .destructive) {
                Task { await model.unpair() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(unpairMessage)
        }
        .confirmationDialog("結束示範？", isPresented: $confirmEndDemo, titleVisibility: .visible) {
            Button("結束示範", role: .destructive) {
                model.reset()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("示範的單、班、打卡都會清掉，回到配對畫面。")
        }
        .confirmationDialog("登出\(model.deviceNoun)？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("登出\(model.deviceNoun)", role: .destructive) {
                Task { await model.signOutPersonalDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(unpairMessage)
        }
    }

    private var checkPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("檢查資料")
            if let check {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusBadge(check.ok ? "完整" : "有問題", tone: check.ok ? .active : .danger)
                    Text(check.message)
                        .textRole(.small)
                        .foregroundStyle(check.ok ? Theme.ink2 : Theme.dangerFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ValueRow(label: "這台記的", value: "\(check.own) 筆")
                ValueRow(label: "別台同步進來的", value: "\(check.remote) 筆")
                ValueRow(label: "還沒送到後台", value: "\(check.pending) 筆")
                if check.quarantined > 0 {
                    ValueRow(label: "後台拒收、隔離中", value: "\(check.quarantined) 筆", tone: Theme.dangerFG)
                }
                Text("檢查時間 \(check.at.clockText)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            } else {
                Text("確認這台的事件一筆接一筆、沒有被改過或少掉。只是讀，不會改到任何資料。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = leaveNote {
                Rule(color: Theme.hair)
                Text(note)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel(padding: 22)
    }

    /// 右欄的紅字動作鍵：示範模式是「結束示範」；配對了的是「解除配對」
    private var leaveActions: [POSAction] {
        if model.isDemo {
            return [POSAction("結束示範", icon: "x-circle", destructive: true) { confirmEndDemo = true }]
        }
        // 個人的裝置：是他自己的，登出不用授權（網站停用這台、StudioX 帳號也登出）
        if model.isPersonalDevice {
            return [POSAction("登出\(model.deviceNoun)", icon: "arrow-right-start-on-rectangle", destructive: true) { confirmSignOut = true }]
        }
        if model.pairing != nil {
            return [POSAction("解除配對", icon: "arrow-right-start-on-rectangle", destructive: true) { Task { await askUnpair() } }]
        }
        return []
    }

    private var leaveNote: String? {
        if model.isDemo { return "現在是虛構的「晨麥手作」，資料只在這次開著的時候；要結束示範、回到配對畫面，按右邊的「結束示範」。" }
        if model.isPersonalDevice { return "\(model.deviceNoun)是 \(model.personalName) 的（個人）。不用了或要換店：按右邊的「登出\(model.deviceNoun)」，會清掉這台的單、班、設定與登入資訊，StudioX 帳號也會登出。" }
        if model.pairing != nil { return "這台不用了或要換店：按右邊的「解除配對」（要店長以上授權），會清掉這台的單、班、設定與登入資訊。" }
        return nil
    }

    private func runCheck() {
        guard let ledger = model.ledger else {
            check = SettingsChainCheck(ok: false, message: "這台還沒有本機資料", own: 0, remote: 0, pending: 0, quarantined: 0, at: Date())
            return
        }
        let journal = ledger.journal
        let result = journal.verifyChain()
        let own = journal.ownEvents.count
        let all = journal.allEvents.count
        let message: String
        switch result {
        case .none:
            message = "雜湊鏈完整：沒有被改過、沒有少掉"
        case .some(.badHash(let id)):
            message = "有一筆事件的內容被改過（\(id.prefix(8))），請聯絡 StudioX"
        case .some(.brokenChain(_, let seq)):
            message = "第 \(seq) 筆接不上：少了一筆或順序錯了，請聯絡 StudioX"
        case .some(.unknownType(let type)):
            message = "有看不懂的事件種類（\(type)），請更新 App"
        }
        check = SettingsChainCheck(ok: result == nil, message: message, own: own, remote: max(all - own, 0),
                                   pending: journal.pendingCount, quarantined: journal.cursor.quarantined.count, at: Date())
    }

    /// 解除配對要「裝置設定」的權限（店長以上）
    private func askUnpair() async {
        guard await model.authorize(.manageDevice, detail: "解除配對") != nil else { return }
        confirmUnpair = true
    }

    private var unpairMessage: String {
        var parts: [String] = []
        let pending = model.syncStatus.pending
        if pending > 0 { parts.append("還有 \(pending) 筆沒送到後台，會先試著送；送不出去的會跟著清掉。") }
        if model.openShift != nil { parts.append("這台還有開著的班，建議先交班。") }
        if model.isPersonalDevice {
            parts.append("\(model.deviceNoun)不再是你在這家店的裝置：本機的單、班、設定與登入資訊會清掉，StudioX 帳號也會登出。要再用，重新用 StudioX 帳號登入。")
        } else {
            parts.append("這台不再接這家店：本機的單、班、設定與登入資訊會清掉，回到配對畫面。要再用，請在後台產生新的配對碼。")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 進階

private struct SettingsAdvancedSection: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let paired = model.pairing != nil
        VStack(alignment: .leading, spacing: 24) {
            SettingsHeading(title: "進階", detail: "通常不用動。")
            VStack(alignment: .leading, spacing: 16) {
                SettingsField(label: "StudioX Console 網址", hint: paired ? "已經配對了；要換請先解除配對" : "打配對碼時，先到這裡查是哪一家店") {
                    TextField("https://console.studiox.tw", text: $settings.consoleURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .settingsInput()
                        .disabled(paired)
                        .opacity(paired ? 0.55 : 1)
                }
                Rule(color: Theme.hair)
                ValueRow(label: "後台網址", value: model.pairing?.cmsURL.absoluteString ?? "—")
                ValueRow(label: "裝置 ID", value: model.device.id.isEmpty ? "—" : model.device.id)
                ValueRow(label: "設定版本", value: model.configVersion ?? "—")
            }
            .panel(padding: 22)
        }
    }
}
