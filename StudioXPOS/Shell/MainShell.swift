import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 收銀台：側欄｜工作區｜單子｜右側固定鍵盤
///
///   ┌────┬──────────────────────┬────────────┬──────────┐
///   │ 點餐│  分類大方塊             │ A2・4 位    │ 這張單的  │
///   │ 桌位│  品項（點一下＝加一份）   │ 拿鐵 ×2  …  │ 動作      │
///   │ 訂單│                        │            │ 1  2  3  │
///   │ …  │                        │ 總計 NT$…  │ 4  5  6  │
///   │ 人員│                        │ [送單][結帳]│ …        │
///   └────┴──────────────────────┴────────────┴──────────┘
///
/// 直的 iPad（寬度不夠四欄）：單子收進右下角的按鈕，點了用面板打開；右側鍵盤照樣固定在最右邊。
/// 左邊選、右邊做：選起來的那一筆（`.dockSelection`）的動作都在右欄，和數字鍵在一起；
/// 不用打數字的選擇（`.dockPanel`）蓋住右欄，要打數字時自動讓開。
struct MainShell: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @FocusState private var focused: Bool
    @State private var scan = ""
    /// 外接鍵盤一個一個打的數字：停 90 毫秒沒有下一個才放進右側鍵盤（條碼機打得很快、最後有 Enter：整串當掃到的，不會灌進鍵盤）
    @State private var flush: Task<Void, Never>?
    @State private var showTicketSheet = false

    var body: some View {
        GeometryReader { geo in
            // 四欄並排要的寬度：側欄 88＋工作區至少 460＋單子 320＋鍵盤 296 ≈ 1164。
            // 橫的 11 吋（1180 以上）四欄；直的 13 吋（1032）單子改成從右邊滑出，點餐區才不會被擠成一字一行
            let wide = geo.size.width >= 1360
            let roomy = geo.size.width >= 1164
            HStack(spacing: 0) {
                SidebarRail()
                VStack(spacing: 0) {
                    StatusBanners()
                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 別台（手機、報到接待）送來結帳的單：每一頁都在右欄等著「去結帳」（這一頁自己選了東西時讓開）
                        .checkoutHandoffDock()
                        // 叫號：右欄最上面那張叫號卡點開的面板、叫到號之後選桌入座（Queue/QueuePanels.swift）
                        .queueDockPanels()
                        // 要確認的事（套折價券會換掉原本的整單折扣）：蓋住右欄的面板
                        .confirmDockPanel()
                }
                // 直的 iPad 單子收起來時，單子欄照樣在（看不到）：整張單的動作（送單、結帳…）才會出現在右欄
                .background {
                    if !roomy && showsTicket && !showTicketSheet {
                        TicketColumn()
                            .frame(width: Metric.ticketColumnNarrow)
                            .hidden()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // 工作區可以縮、超出的地方切掉：裡面的頁面再寬，也不會把單子與右側鍵盤擠出畫面
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                .layoutPriority(-1)
                if roomy && showsTicket {
                    TicketColumn()
                        .frame(width: wide ? Metric.ticketColumn : Metric.ticketColumnNarrow)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                // 右欄的位置；真正的右欄畫在下面的 overlayPreferenceValue 裡（才拿得到各畫面交上來的選取與面板）
                Theme.dock
                    .ignoresSafeArea()
                    .frame(width: wide ? Metric.dock : Metric.dockNarrow)
            }
            // 直的 iPad：單子收在工作區右下角（放右上會擋到頁首的切換）
            .overlay(alignment: .bottomTrailing) {
                if !roomy && showsTicket && !showTicketSheet {
                    Button {
                        showTicketSheet = true
                    } label: {
                        Label("單子 \(model.selectedTicket?.itemCount ?? 0)", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.brand(.primary, size: .lg))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
                    .padding(.trailing, Metric.dockNarrow + 20)
                    // 結帳畫面最下面有「尚欠／選付款方式…」那一條：鈕放在它上面，不蓋住字
                    .padding(.bottom, model.checkoutTicket != nil ? 84 : 20)
                }
            }
            // 直的 iPad：單子從右邊滑出來、停在右側鍵盤的左邊（不用 sheet：sheet 會蓋住鍵盤，單子裡的數量、改價就打不了）
            .overlay(alignment: .trailing) {
                if !roomy && showsTicket && showTicketSheet {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.32)
                            .contentShape(.rect)
                            .onTapGesture { showTicketSheet = false }
                        TicketColumn()
                            .frame(width: Metric.ticketColumnNarrow)
                            .background(Theme.page)
                            .overlay(alignment: .leading) { Rule(vertical: true) }
                            .overlay(alignment: .topLeading) {
                                Button {
                                    showTicketSheet = false
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 30, height: 30)
                                        .background(Theme.surface, in: .circle)
                                        .overlay { Circle().strokeBorder(Theme.line) }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink2)
                                .accessibilityLabel("收起單子")
                                .offset(x: -15, y: 14)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 24, x: -6)
                        // 右側鍵盤那一格留空、不擋手指
                        Color.clear
                            .frame(width: Metric.dockNarrow)
                            .allowsHitTesting(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // 右欄：左邊選起來的那一筆＋它的動作、數字鍵、蓋住整欄的面板（見 Keypad/Dock.swift）。
            // 放在兩個 overlay 後面：直的 iPad 滑出來的單子交上來的選取也收得到
            .overlayPreferenceValue(DockKey.self, alignment: .trailing) { content in
                KeypadDock(idleActions: idleActions, content: content, showsPinned: true,
                           describeIdle: { model.describeTyped($0) })
                    .frame(width: wide ? Metric.dock : Metric.dockNarrow)
                    // 待機打的數字：會員電話、統編、對到的品號，停一下就自動做（不用再按鍵）
                    .background { TypedDigitsAutoAction() }
            }
            .onChange(of: showsTicket) { _, v in if !v { showTicketSheet = false } }
            .onChange(of: roomy) { _, v in if v { showTicketSheet = false } }
        }
        .background(Theme.page.ignoresSafeArea())
        .animation(Motion.ease, value: showsTicket)
        .animation(Motion.spring, value: showTicketSheet)
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
        // 相機掃碼（掃碼、掃會員條碼、掃折價券…）：Components/ScanSheets.swift
        .scanPresenter()
    }

    /// 點餐畫面的鍵盤待機時可以打品號
    private var idleActions: KeypadDock.IdleActions? {
        guard model.section == .order, model.checkoutTicketId == nil else { return nil }
        return KeypadDock.IdleActions(commit: { model.commitTyped($0) }, title: { model.typedConfirmTitle($0) })
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
        case .queue: QueueView()
        case .kitchen: KitchenView()
        case .dashboard: DashboardView()
        case .shift: ShiftView()
        case .settings: SettingsView()
        }
    }

    // MARK: 外接鍵盤、條碼掃描器

    /// 數字直接打進右側鍵盤；Enter＝確認。掃描器（像鍵盤一樣打字、最後按 Enter）和手機的相機走同一條路（POSModel.handleScan）：
    /// 載具（/ 開頭）掛到這張單、會員卡掛會員、品號／條碼加品項、其他的當折價券查
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        model.touch()
        switch press.key {
        case .return:
            flush?.cancel()
            flush = nil
            let code = scan
            scan = ""
            if code.count >= 4 {
                // 條碼機（一口氣打進來、最後 Enter）：照內容判斷，不用再按任何鍵
                scanned(code)
                return .handled
            }
            // 人打的、還沒放進鍵盤的幾個數字：先放進去，再照平常的 Enter（確認／查品號）
            for ch in code { if let n = ch.wholeNumberValue { keypad.press(.digit(n)) } }
            if keypad.isAsking {
                keypad.commit()
            } else if let typed = keypad.takeCode() {
                // 待機：右側鍵盤打的數字。點餐頁和右側鍵盤的大鍵一樣（品號、沒有這個品號就是多少錢）；
                // 點餐頁以外，短的數字多半是不小心打的
                if idleActions != nil {
                    model.commitTyped(typed)
                    return .handled
                }
                guard model.section == .order || model.checkoutTicket != nil || typed.count >= 4 else { return .handled }
                Task { await model.handleScan(typed) }
            }
            return .handled
        case .delete:
            // 還沒放進鍵盤的先刪掉（人打得很快又按刪除）
            if !scan.isEmpty {
                scan.removeLast()
                return .handled
            }
            keypad.press(.backspace)
            return .handled
        case .escape:
            flush?.cancel()
            flush = nil
            scan = ""
            // 沒在問數字：交給右側面板的「關掉」
            guard keypad.isAsking else { return .ignored }
            keypad.cancel()
            return .handled
        default:
            let s = press.characters
            guard !s.isEmpty else { return .ignored }
            scan += s
            // 人打的：停一下才放進鍵盤；條碼機的下一個字很快就來（取消這次），最後的 Enter 把整串當掃到的
            flush?.cancel()
            flush = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                let typed = scan
                scan = ""
                for ch in typed { if let n = ch.wholeNumberValue { keypad.press(.digit(n)) } }
            }
            return .handled
        }
    }

    /// 條碼機掃到的一整串：鍵盤在問會員電話、統編這類的就填進去；其他（在問收多少錢、數量也一樣）直接照內容做——
    /// 會員掛上、載具掛上、折價券套用、商品加入，鍵盤上打到一半的不動
    private func scanned(_ code: String) {
        if keypad.isAskingMemberPhone, let phone = ScanCode.memberPhone(in: code) {
            keypad.fill(phone)
            return
        }
        if let r = keypad.request, !r.keepsSelection, Self.scanAnswers(r.spec.kind, code) {
            // 鍵盤在問一串碼（統編、愛心碼、品號…）：掃到的就是答案
            keypad.fill(code)
            return
        }
        if keypad.keepsSelection { keypad.cancel() }
        Task { await model.handleScan(code) }
    }

    /// 掃到的這串可以直接當鍵盤問的答案嗎（PIN 不行：PIN 要人打）
    private static func scanAnswers(_ kind: KeypadSpec.Kind, _ code: String) -> Bool {
        guard code.allSatisfy(\.isNumber) else { return false }
        switch kind {
        case .taxId: return code.count == 8
        case .loveCode: return (3...7).contains(code.count)
        case .code(let lo, let hi): return (lo...hi).contains(code.count)
        default: return false
        }
    }
}

/// 最左邊的側欄：上面是做生意的頁（點餐、桌位、叫號…），下面是管理的頁（報表、交班、設定）、時間、同步、換人。
///
/// 頁多、螢幕矮（11 吋、mini 橫放）時不擠成一團、也不被切掉：先把鍵變矮，還放不下就把用得少的頁收進「更多」
struct SidebarRail: View {
    @Environment(POSModel.self) private var model
    @State private var height: CGFloat = 1000

    var body: some View {
        let plan = RailPlan(sections: model.visibleSections, height: height, hasModeMenu: showsModeMenu)
        VStack(spacing: 0) {
            BrandMark()
                .frame(width: 24, height: 24)
                .foregroundStyle(Theme.ink)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .accessibilityLabel("StudioX POS")

            // 營業模式（後台開了兩種以上才能切）
            if showsModeMenu {
                modeMenu
                    .padding(.bottom, 8)
            }

            VStack(spacing: plan.spacing) {
                ForEach(plan.main) { s in
                    RailButton(section: s, selected: model.section == s, badge: badge(for: s), compact: plan.compact) {
                        model.go(s)
                    }
                }
            }

            Spacer(minLength: 10)

            VStack(spacing: plan.spacing) {
                ForEach(plan.tools) { s in
                    RailButton(section: s, selected: model.section == s, badge: badge(for: s), compact: true) {
                        model.go(s)
                    }
                }
                if !plan.more.isEmpty {
                    RailMore(sections: plan.more, current: model.section, badge: plan.more.reduce(0) { $0 + badge(for: $1) }) { s in
                        model.go(s)
                    }
                }
            }

            Rule()
                .frame(width: 36)
                .padding(.vertical, 10)

            RailClock()

            SyncDot(status: model.syncStatus, demo: model.isDemo)
                .padding(.top, 6)

            staffControl
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .frame(width: Metric.rail)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
        .animation(Motion.fast, value: plan)
        .background(Theme.pageAlt.opacity(0.6).ignoresSafeArea())
        .overlay(alignment: .trailing) { Rule(vertical: true).ignoresSafeArea() }
    }

    private var showsModeMenu: Bool {
        model.store.serviceModes.count > 1 && !model.role.isKitchen
    }

    private var modeMenu: some View {
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
    }

    /// 個人的裝置（用 StudioX 帳號登入）：只寫是誰的，沒有鎖定／換人（鎖定是閒置時自動、用 Face ID 解開）
    @ViewBuilder
    private var staffControl: some View {
        if model.isPersonalDevice, let me = model.currentStaff {
            VStack(spacing: 5) {
                StaffAvatar(name: me.name, swatch: me.swatch, size: 28)
                Text(String(me.name.prefix(6)))
                    .font(.brand(10.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink2)
            .frame(width: 70, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("這台是 \(me.name) 的（個人）")
        } else {
            staffButton
        }
    }

    /// 現在是誰（點了＝鎖定、讓下一位打 PIN）。上班中的其他人在「交班」看
    private var staffButton: some View {
        let onDuty = model.staff.filter { model.isClockedIn($0) }.count
        return Button {
            model.lock()
        } label: {
            VStack(spacing: 5) {
                if let me = model.currentStaff {
                    StaffAvatar(name: me.name, swatch: me.swatch, size: 28)
                        .overlay(alignment: .bottomTrailing) {
                            HeroIcon("lock-closed", size: 9)
                                .foregroundStyle(Theme.ink2)
                                .frame(width: 15, height: 15)
                                .background(Theme.page, in: .circle)
                                .offset(x: 4, y: 3)
                        }
                } else {
                    HeroIcon("lock-closed", size: 18)
                }
                Text(model.currentStaff.map { String($0.name.prefix(6)) } ?? "鎖定")
                    .font(.brand(10.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.ink2)
            .frame(width: 70, height: 52)
        }
        .buttonStyle(.row)
        .accessibilityLabel("鎖定（換人）")
        .accessibilityValue(onDuty > 0 ? "\(onDuty) 人上班" : "")
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .kitchen: model.state.openTickets.reduce(0) { $0 + $1.lines.filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) }.count }
        case .reservations: model.reservations.filter { $0.kind == .waitlist && $0.status.isActive }.count
        case .appointments:
            // 已到店、等著開始的預約
            model.reservations.filter { $0.kind == .appointment && $0.status == .arrived }.count
        case .queue: model.queue.state?.waiting.count ?? 0
        // 待結帳（前場的手機、報到接待送來的）
        case .orders: model.awaitingCheckoutCount
        default: 0
        }
    }
}

/// 側欄怎麼排：做生意的頁在上、管理的頁在下；放不下時鍵變矮，再放不下就把用得少的收進「更多」
struct RailPlan: Equatable {
    var main: [AppSection] = []
    var tools: [AppSection] = []
    var more: [AppSection] = []
    var compact = false

    var spacing: CGFloat { compact ? 2 : 4 }

    /// 管理的頁（放在下面、矮一點的鍵）
    static let toolSections: Set<AppSection> = [.dashboard, .shift, .settings]

    /// 一般的鍵、矮的鍵（含間距）
    static let regular: CGFloat = 64
    static let small: CGFloat = 50

    /// 固定佔掉的高度：標誌、間隔、分隔線、時間、同步、換人（再留一點餘裕）
    static func fixed(hasModeMenu: Bool) -> CGFloat {
        48 + (hasModeMenu ? 30 : 0) + 10 + 21 + 36 + 29 + 70 + 12
    }

    init(sections: [AppSection], height: CGFloat, hasModeMenu: Bool) {
        let work = sections.filter { !Self.toolSections.contains($0) }
        let tools = sections.filter { Self.toolSections.contains($0) }
        let room = height - Self.fixed(hasModeMenu: hasModeMenu)
        if CGFloat(work.count) * Self.regular + CGFloat(tools.count) * Self.small <= room {
            main = work
            self.tools = tools
            return
        }
        compact = true
        if CGFloat(sections.count) * Self.small <= room {
            main = work
            self.tools = tools
            return
        }
        // 「更多」自己也佔一格；至少留兩頁在外面
        let slots = max(Int(room / Self.small) - 1, 2)
        let keep = Set(sections.enumerated()
            .sorted { (Self.rank($0.element), $0.offset) < (Self.rank($1.element), $1.offset) }
            .prefix(slots)
            .map(\.element))
        main = work.filter { keep.contains($0) }
        self.tools = tools.filter { keep.contains($0) }
        more = sections.filter { !keep.contains($0) }
    }

    /// 越常用越小：放不下時從大的開始收
    static func rank(_ s: AppSection) -> Int {
        switch s {
        case .order, .floor, .kitchen, .checkIn, .appointments: 0
        case .queue: 1
        case .orders: 2
        case .reservations: 3
        case .members: 4
        case .shift: 5
        case .dashboard: 6
        case .settings: 7
        }
    }
}

/// 「更多」：收起來的頁。正在看其中一頁時，這顆就換成那一頁的樣子（看得出現在在哪）
struct RailMore: View {
    let sections: [AppSection]
    let current: AppSection
    var badge: Int = 0
    let go: (AppSection) -> Void

    var body: some View {
        let showing = sections.contains(current) ? current : nil
        Menu {
            ForEach(sections) { s in
                Button {
                    go(s)
                } label: {
                    if s == current {
                        Label(s.label, systemImage: "checkmark")
                    } else {
                        Text(s.label)
                    }
                }
            }
        } label: {
            RailButtonLabel(icon: showing?.icon ?? "ellipsis-horizontal", label: showing?.label ?? "更多",
                            selected: showing != nil, badge: badge, compact: true)
        }
        .accessibilityLabel(showing.map { "更多（現在在\($0.label)）" } ?? "更多")
    }
}

/// 側欄的時鐘（系統的時間列藏起來了）：時間、星期
struct RailClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 1) {
                Text(TaipeiTime.clock(context.date))
                    .font(.brand(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Text(Self.weekday(context.date))
                    .font(.brand(10.5, .medium))
                    .foregroundStyle(Theme.faint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("現在 \(TaipeiTime.clock(context.date))")
        }
    }

    static func weekday(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let w = ((c.weekday ?? 1) - 1 + 7) % 7
        return "\(c.month ?? 0)/\(c.day ?? 0) 週\(names[w])"
    }
}

struct RailButton: View {
    let section: AppSection
    let selected: Bool
    var badge: Int = 0
    /// 矮一點的鍵（管理的頁、螢幕放不下時）
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailButtonLabel(icon: section.icon, label: section.label, selected: selected, badge: badge, compact: compact)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .animation(Motion.fast, value: selected)
        .accessibilityLabel(section.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 側欄一顆鍵的樣子（圖示＋字、選起來反白、右上角的數字）
struct RailButtonLabel: View {
    let icon: String
    let label: String
    let selected: Bool
    var badge: Int = 0
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            HeroIcon(icon, size: compact ? 19 : 22)
            Text(label)
                .font(.brand(compact ? 10.5 : 11.5, selected ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? Theme.page : Theme.ink2)
        .frame(width: 70, height: compact ? 48 : 60)
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
                    .offset(x: -4, y: compact ? 2 : 4)
            }
        }
        .contentShape(.rect)
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
        let showInvoice = model.features.invoice && model.invoiceSettings.enabled && model.role.issuesInvoices && numbersLeft < 10
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
