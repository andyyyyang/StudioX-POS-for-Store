import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 收銀台：側欄｜工作區｜單子｜右側固定鍵盤
///
///   ┌────┬──────────────────────┬────────────┬──────────┐
///   │ 點餐│  分類大方塊             │ A2・4 位    │ 數量・品號 │
///   │ 桌位│  品項（點一下＝加一份）   │ 拿鐵 ×2  …  │   × 3    │
///   │ 訂單│                        │            │ 1  2  3  │
///   │ …  │                        │ 總計 NT$…  │ 4  5  6  │
///   │ 人員│                        │ [送單][結帳]│ …        │
///   └────┴──────────────────────┴────────────┴──────────┘
///
/// 直的 iPad（寬度不夠四欄）：單子收進右上角的按鈕，點了用面板打開；右側鍵盤照樣固定在最右邊。
struct MainShell: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @FocusState private var focused: Bool
    @State private var scan = ""
    @State private var showTicketSheet = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1180
            let roomy = geo.size.width >= 1000
            HStack(spacing: 0) {
                SidebarRail()
                VStack(spacing: 0) {
                    StatusBanners()
                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                if roomy && showsTicket {
                    TicketColumn()
                        .frame(width: wide ? Metric.ticketColumn : Metric.ticketColumnNarrow)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                KeypadDock(idleActions: idleActions)
                    .frame(width: wide ? Metric.dock : Metric.dockNarrow)
            }
            .overlay(alignment: .topTrailing) {
                if !roomy && showsTicket {
                    Button {
                        showTicketSheet = true
                    } label: {
                        Label("單子 \(model.selectedTicket?.itemCount ?? 0)", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.brand(.primary, size: .md))
                    .padding(.trailing, Metric.dockNarrow + 16)
                    .padding(.top, 12)
                }
            }
        }
        .background(Theme.page.ignoresSafeArea())
        .animation(Motion.ease, value: showsTicket)
        .sheet(isPresented: $showTicketSheet) {
            TicketColumn()
                .presentationDetents([.large])
        }
        .confirmationDialog(
            "開不了發票", isPresented: Binding(get: { model.pendingInvoiceFailure != nil }, set: { if !$0 { model.pendingInvoiceFailure = nil } }),
            presenting: model.pendingInvoiceFailure
        ) { f in
            Button("先結帳，之後補開") {
                if let t = model.state.tickets[f.ticketId] { Task { await model.complete(t, skipInvoice: true) } }
            }
            Button("取消", role: .cancel) {}
        } message: { f in
            Text(f.message)
        }
        .confirmationDialog(
            "要印交易明細嗎？", isPresented: Binding(get: { model.receiptOffer != nil }, set: { if !$0 { model.receiptOffer = nil } }),
            presenting: model.receiptOffer
        ) { sale in
            Button("印交易明細") { model.printReceipt(sale) }
            Button("不用", role: .cancel) {}
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        // 右側鍵盤一開始問數字，外接鍵盤、掃描器打的字就回到鍵盤（剛剛在搜尋框打字也一樣）
        .onChange(of: keypad.request?.id) { _, _ in focused = true }
        .onKeyPress(phases: .down) { press in handle(press) }
        .simultaneousGesture(TapGesture().onEnded { model.touch() })
    }

    /// 點餐畫面的鍵盤待機時可以打品號
    private var idleActions: KeypadDock.IdleActions? {
        guard model.section == .order, model.checkoutTicketId == nil else { return nil }
        return KeypadDock.IdleActions(lookup: { model.lookup(code: $0) })
    }

    private var showsTicket: Bool {
        switch model.section {
        case .order: true
        case .floor, .orders, .appointments, .checkIn, .members: model.selectedTicket != nil || model.checkoutTicket != nil
        default: false
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch model.section {
        case .order:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                MenuView()
            }
        case .floor:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                FloorView()
            }
        case .orders:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                OrdersView()
            }
        case .appointments:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                AppointmentsView()
            }
        case .checkIn:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                CheckInView()
            }
        case .members:
            if let t = model.checkoutTicket, t.isOpen {
                PaymentView(ticketId: t.id)
            } else {
                MembersView()
            }
        case .reservations: ReservationsView()
        case .kitchen: KitchenView()
        case .dashboard: DashboardView()
        case .shift: ShiftView()
        case .settings: SettingsView()
        }
    }

    // MARK: 外接鍵盤、條碼掃描器

    /// 數字直接打進右側鍵盤；Enter＝確認。掃描器（像鍵盤一樣打字、最後按 Enter）：
    /// 掃到手機條碼（/ 開頭）在結帳時當載具；掃到數字在點餐時當品號／條碼
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        model.touch()
        switch press.key {
        case .return:
            let code = scan
            scan = ""
            if keypad.isAsking {
                keypad.commit()
            } else if code.hasPrefix("/"), let t = model.checkoutTicket {
                keypad.clearIdle()
                if !model.setCarrier(code, for: t) { model.show("載具 \(code) 格式不對", tone: .warning) }
            } else if model.section == .order, let c = keypad.takeCode() {
                model.lookup(code: c)
            }
            return .handled
        case .delete:
            keypad.press(.backspace)
            return .handled
        case .escape:
            scan = ""
            keypad.cancel()
            return .handled
        default:
            let s = press.characters
            guard !s.isEmpty else { return .ignored }
            scan += s
            if s.count == 1, let n = Int(s) { keypad.press(.digit(n)) }
            return .handled
        }
    }
}

/// 最左邊的側欄
struct SidebarRail: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            BrandMark()
                .frame(width: 26, height: 26)
                .foregroundStyle(Theme.ink)
                .padding(.top, 18)
                .padding(.bottom, 8)
                .accessibilityLabel("StudioX POS")

            // 營業模式（後台開了兩種以上才能切）
            if model.store.serviceModes.count > 1 && model.device.role != .kitchen {
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
                    Text(model.mode.label)
                        .font(.brand(10.5, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Theme.accentSoft, in: .capsule)
                }
                .accessibilityLabel("營業模式：\(model.mode.label)")
                .padding(.bottom, 10)
            }

            ForEach(model.visibleSections) { s in
                RailButton(section: s, selected: model.section == s, badge: badge(for: s)) {
                    model.go(s)
                }
            }

            Spacer(minLength: 12)

            // 上班中的人（點了換人＝鎖定、讓下一位打 PIN）
            VStack(spacing: 8) {
                Text("上班")
                    .font(.brand(10.5, .medium))
                    .foregroundStyle(Theme.faint)
                ForEach(model.staff.filter { model.isClockedIn($0) }.prefix(5)) { s in
                    StaffAvatar(name: s.name, swatch: s.swatch, size: 30, active: s.id == model.currentStaff?.id)
                }
            }
            .padding(.bottom, 8)

            SyncDot(status: model.syncStatus, demo: model.isDemo)
                .padding(.bottom, 6)

            Button {
                model.lock()
            } label: {
                VStack(spacing: 4) {
                    HeroIcon("lock-closed", size: 18)
                    Text(model.currentStaff.map { String($0.name.prefix(6)) } ?? "鎖定")
                        .font(.brand(10.5, .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.ink2)
                .frame(width: 70, height: 52)
            }
            .buttonStyle(.row)
            .padding(.bottom, 14)
            .accessibilityLabel("鎖定（換人）")
        }
        .frame(width: Metric.rail)
        .frame(maxHeight: .infinity)
        .background(Theme.pageAlt.opacity(0.6))
        .overlay(alignment: .trailing) { Rule(vertical: true) }
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .kitchen: model.state.openTickets.reduce(0) { $0 + $1.lines.filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) }.count }
        case .reservations: model.reservations.filter { $0.kind == .waitlist && $0.status.isActive }.count
        case .appointments:
            // 已到店、等著開始的預約
            model.reservations.filter { $0.kind == .appointment && $0.status == .arrived }.count
        default: 0
        }
    }
}

struct RailButton: View {
    let section: AppSection
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HeroIcon(section.icon, size: 22)
                Text(section.label)
                    .font(.brand(11.5, selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Theme.page : Theme.ink2)
            .frame(width: 70, height: 60)
            .background(selected ? Theme.ink : Color.clear, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.brand(10.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: .capsule)
                        .offset(x: -4, y: 4)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .animation(Motion.fast, value: selected)
        .accessibilityLabel(section.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 同步狀態的小點（綠：同步了、橘：離線照常營業、紅：要處理）
struct SyncDot: View {
    let status: SyncStatus
    var demo = false

    var body: some View {
        VStack(spacing: 4) {
            if status.health == .synced && !demo {
                LiveDot()
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(demo ? "示範" : short)
                .font(.brand(10, .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(demo ? "示範模式" : status.label)
    }

    private var color: Color {
        if demo { return Theme.xenaViolet }
        switch status.health {
        case .synced: return Theme.live
        case .syncing: return Theme.infoFG
        case .offline, .paused: return Theme.warningFG
        case .attention: return Theme.dangerFG
        }
    }

    private var short: String {
        switch status.health {
        case .synced: status.pending > 0 ? "\(status.pending) 待送" : "已同步"
        case .syncing: "同步中"
        case .offline: status.pending > 0 ? "離線 \(status.pending)" : "離線"
        case .paused: "暫停"
        case .attention: "要處理"
        }
    }
}

/// 工作區上方的提示：衝突、離線、發票號碼快用完、別台剛做的事
struct StatusBanners: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let conflicts = model.state.unresolvedConflicts
        let numbersLeft = model.invoiceNumbersLeft
        let showInvoice = model.features.invoice && model.invoiceSettings.enabled && model.device.role != .kitchen && numbersLeft < 10
        VStack(spacing: 8) {
            if let c = conflicts.last {
                Banner(text: c.message + (conflicts.count > 1 ? "（還有 \(conflicts.count - 1) 件）" : ""), tone: .danger)
            }
            if model.syncStatus.health == .attention, let e = model.syncStatus.lastError, !model.isDemo {
                Banner(text: e, tone: .danger)
            } else if model.syncStatus.health == .offline, model.syncStatus.pending > 20 {
                Banner(text: "離線中，\(model.syncStatus.pending) 筆資料存在這台，連上網路後自動補送", tone: .warning)
            }
            if showInvoice {
                Banner(text: numbersLeft == 0 ? "這一期的發票號碼用完了：結帳時會問要不要先結、之後補開" : "發票號碼只剩 \(numbersLeft) 張，連上網路會自動補", tone: numbersLeft == 0 ? .danger : .warning)
            }
            if let activity = model.remoteActivity {
                Banner(text: activity, tone: .info)
                    .task(id: activity) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.remoteActivity == activity { model.remoteActivity = nil }
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, conflicts.isEmpty && !showInvoice && model.remoteActivity == nil && model.syncStatus.health != .attention ? 0 : 12)
        .animation(Motion.ease, value: model.remoteActivity)
    }
}
