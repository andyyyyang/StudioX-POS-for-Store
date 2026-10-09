import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 訂單：兩個分頁
///
/// 進行中（看板：點餐中 → 出餐中 → 用餐中 → 待結帳）
///   ┌ Open tickets ─────────────────────────── [進行中 5][全部 23] ┐
///   │ ● 點餐中 1   │ ● 出餐中 2        │ ● 用餐中 1   │ ● 待結帳 1  │
///   │ ┌─────────┐  │ ┌──────────────┐  │              │ ┌─────────┐ │
///   │ │A5   A021│  │ │A2 4位・34分 ●●○│  │              │ │A7   A019│ │
///   │ │NT$ 320  │  │ │NT$ 1,320     │  │              │ │NT$ 860  │ │
///   │ └─────────┘  │ └──────────────┘  │              │ └─────────┘ │
///   └──────────────────────────────────────────────────────────────┘
///   卡片上沒有按鈕：點一下選起來（橘框），右欄出現這張單：大鍵「結帳」（不能收錢的崗位是「點餐」），
///   動作鍵「點餐」「印結帳單」「作廢」。再點一下或右欄的 × 取消選取。
///
/// 全部（左邊一天的清單、右邊明細）
///   ┌ ‹ 今天・10月4日 ›   ┬───────────────────────────────────────┐
///   │ [搜尋……][⌨]       │ NT$ 1,320                               │
///   │▌NT$1,320   14:05  │ 已付款・經手 Cameron W.                  │
///   │ A2・4 位   已結帳  │ [林小涵 金卡會員]                        │
///   │  NT$2,680  13:40  │ 品項（規格、設計師、卡抵）…  金額          │
///   │ 王小美     已換貨  │ 付款・發票・換貨・退款                    │
///   └───────────────────┴────────────────────────────────────────┘
///   點一筆選起來、明細在中間；動作都在右欄：大鍵「補印收據」，動作鍵「換貨」「補印證明聯」「改統編／載具」「補開發票」「退款」。
///
/// 左邊選、右邊做（docs/DESIGN.md）：退款、換貨、改統編的選項（品項、退回方式、原因、規格）是不用打數字的選擇，
/// 用 .dockPanel 蓋住右欄；件數、金額、統編、愛心碼、主管 PIN 在右欄的鍵盤問，問的時候面板讓開、問完回來。
///
/// 「全部」一次看一天：今天、昨天直接讀這台的狀態；更早的跟後台要（`model.history`），只能看、補印收據。
struct OrdersView: View {
    @Environment(POSModel.self) private var model

    @State private var tab: OrdersTab = .open
    @State private var query = ""
    /// 「全部」選中的那一張（ticketId）。沒選就不開明細（再點一下或右欄的 × 取消）
    @State private var selectedId: String?
    /// 「全部」看哪一天（nil＝今天：過了營業日的分界會自己換到新的一天）
    @State private var day: String?
    /// 跟後台要不到的日子（離線）：畫面上給「重試」
    @State private var offlineDays: Set<String> = []
    /// 按了「已處理」的衝突：只在這個畫面藏起來、不記事件（不發明新的事件種類；真正結案在後台）
    @State private var dismissedConflicts: Set<String> = []
    /// 選起來的衝突（右欄：大鍵「已處理」、動作「看單」）
    @State private var selectedConflictId: String?
    /// 要作廢的那張進行中的單（右欄蓋上「作廢的原因」）
    @State private var voidingTicketId: String?
    /// 外送單要拒單／取消（右欄蓋上原因）
    @State private var deliveryReasonFor: DeliveryReasonTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            conflictList
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dockSelection(dockItem)
        // 選了一般的單就不是在看外送單（反過來外送那一排自己清）
        .onChange(of: model.selectedTicketId) { _, id in if id != nil { model.deliveryFocusId = nil } }
        // 結帳櫃台：手機送來結帳的單（沒選單子時在右欄）
        .dockPanel(isPresented: Binding(get: { voidingTicketId != nil }, set: { if !$0 { voidingTicketId = nil } }),
                   title: "作廢整張單", subtitle: voidSubtitle) {
            voidChoices
        }
        .dockPanel(isPresented: Binding(get: { deliveryReasonFor != nil }, set: { if !$0 { deliveryReasonFor = nil } }),
                   title: deliveryReasonFor?.title ?? "", subtitle: "平台要知道原因") {
            DeliveryReasonChoices { reason in
                guard let target = deliveryReasonFor, let t = model.state.tickets[target.ticketId] else { return }
                deliveryReasonFor = nil
                Task {
                    switch target {
                    case .reject: await model.rejectDelivery(t, reason: reason)
                    case .cancel: await model.cancelDelivery(t, reason: reason)
                    }
                }
            }
        }
        .onAppear {
            if LaunchArguments.preselect { preselectLatestSale() }
        }
    }

    // MARK: - 右欄：選起來的那一筆

    /// 衝突 → 看板選的單（進行中）→「全部」選的進行中的單。已結帳的那一筆由明細自己交上去（裡面的優先）
    private var dockItem: DockSelection? {
        if let c = selectedConflict { return conflictDock(c) }
        if let id = model.deliveryFocusId, let t = model.state.tickets[id] {
            return deliveryDock(t, model: model, reject: { deliveryReasonFor = .reject(id) }, cancel: { deliveryReasonFor = .cancel(id) }) {
                model.deliveryFocusId = nil
            }
        }
        switch tab {
        case .open:
            guard let t = model.selectedTicket else { return nil }
            return ticketDock(t) { model.selectedTicketId = nil }
        case .all:
            guard let id = selectedId, let t = model.state.tickets[id], t.isOpen else { return nil }
            return ticketDock(t) { selectedId = nil }
        }
    }

    /// 這台有點餐頁、這個崗位能開單（報到接待、只收錢的櫃台沒有「點餐」）
    private var canOrderHere: Bool {
        model.role.takesOrders && model.visibleSections.contains(.order)
    }

    /// 進行中的單：大鍵「結帳」（不能收錢的崗位是「點餐」）；動作「點餐」「印結帳單」「作廢」
    private func ticketDock(_ t: Ticket, clear: @escaping @MainActor () -> Void) -> DockSelection {
        let orderAction: POSAction? = canOrderHere
            ? POSAction(t.exchange != nil ? "加要換的商品" : "點餐", icon: "plus-circle") {
                model.selectedTicketId = t.id
                model.go(.order)
            }
            : nil
        let checkout: POSAction? = model.takesPayment
            ? POSAction("結帳", icon: "credit-card", enabled: !t.activeLines.isEmpty) { model.beginCheckout(t) }
            : nil
        var actions: [POSAction] = []
        if checkout != nil, let orderAction { actions.append(orderAction) }
        actions.append(POSAction("印結帳單", icon: "printer", enabled: !t.activeLines.isEmpty) {
            model.printBill(t)
            model.show("已送出 \(t.title(floor: model.floor)) 的結帳單")
        })
        actions.append(POSAction("作廢整張單", icon: "trash", destructive: true) { voidingTicketId = t.id })
        let lane = OrdersLane.of(t, kitchen: boardKitchen)
        var detail = [t.number]
        if t.guests > 0 { detail.append("\(t.guests) 位") }
        detail.append("\(t.itemCount) 項")
        detail.append(t.totals.total.formatted)
        return DockSelection(
            id: "orders-ticket-\(t.id)",
            kind: t.exchange != nil ? "換貨單" : "單子",
            title: t.title(floor: model.floor),
            detail: detail.joined(separator: "・"),
            badge: DockBadge(lane.title(kitchen: boardKitchen, tables: boardTables), tone: lane.tone),
            primary: checkout ?? orderAction,
            accent: checkout != nil,
            actions: actions,
            clear: { clear() }
        )
    }

    private var selectedConflict: Conflict? {
        guard let id = selectedConflictId else { return nil }
        return model.state.visibleConflicts(hiding: dismissedConflicts).first(where: { $0.id == id })
    }

    /// 衝突：大鍵「已處理」（只在這個畫面藏起來）；有那張單的話動作「看單」
    private func conflictDock(_ c: Conflict) -> DockSelection {
        var actions: [POSAction] = []
        if canOpen(c) {
            actions.append(POSAction("看單", icon: "eye") {
                selectedConflictId = nil
                open(c)
            })
        }
        return DockSelection(
            id: "orders-conflict-\(c.id)",
            kind: "兩台不一致",
            title: c.ordersKindLabel,
            detail: "\(c.message)・\(c.at.shortText)",
            badge: DockBadge("要處理", tone: .danger),
            primary: POSAction("已處理", icon: "check") {
                _ = dismissedConflicts.insert(c.id)
                selectedConflictId = nil
            },
            accent: false,
            actions: actions,
            clear: { selectedConflictId = nil }
        )
    }

    // MARK: 作廢整張單（右欄的面板選原因；已送廚房、收了錢的要主管授權，在 model 裡問）

    private var voidingTicket: Ticket? { voidingTicketId.flatMap { model.state.tickets[$0] } }

    private var voidSubtitle: String {
        guard let t = voidingTicket else { return "" }
        return "\(t.number)・\(t.title(floor: model.floor))・選一個原因就作廢"
    }

    private var voidChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["客人離開", "開錯單", "測試"], id: \.self) { reason in
                DockChoice(title: reason) { voidTicket(reason: reason) }
            }
            Text("已經送廚房或收了錢的單要主管授權；收了錢的請先退回付款。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func voidTicket(reason: String) {
        guard let t = voidingTicket else {
            voidingTicketId = nil
            return
        }
        voidingTicketId = nil
        if model.selectedTicketId == t.id { model.selectedTicketId = nil }
        if selectedId == t.id { selectedId = nil }
        Task { await model.voidTicket(t, reason: reason) }
    }

    // MARK: 截圖用（只在 Debug 帶 -preselect）：打開「全部」、選起最近結帳的一筆

    private func preselectLatestSale() {
        guard let s = model.state.closedSales().last else { return }
        select(tab: .all)
        day = s.businessDate == model.businessDate ? nil : s.businessDate
        selectedId = s.ticketId
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            PageTitle(title: headerTitle, subtitle: headerSubtitle)
            Spacer(minLength: 16)
            OrdersSegment(selection: tab, openCount: model.state.openTickets.count, allCount: todayCount) { t in
                select(tab: t)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var headerTitle: String {
        switch tab {
        case .open: "Open *tickets*"
        case .all: "All *orders*"
        }
    }

    private var headerSubtitle: String {
        switch tab {
        case .open: "訂單・進行中"
        case .all: "訂單・這台看得到的全部"
        }
    }

    private var todayCount: Int {
        model.state.openTickets.count + model.state.closedSales(businessDate: model.businessDate).count
    }

    private func select(tab t: OrdersTab) {
        // 「全部」要左右兩欄的寬度：收起右邊的單子欄
        if t == .all && model.checkoutTicketId == nil { model.selectedTicketId = nil }
        selectedId = nil
        selectedConflictId = nil
        withAnimation(Motion.fast) { tab = t }
    }

    // MARK: - 衝突（兩台斷線各做各的）

    @ViewBuilder
    private var conflictList: some View {
        let list = model.state.visibleConflicts(hiding: dismissedConflicts)
        if !list.isEmpty {
            VStack(spacing: 8) {
                ForEach(list) { c in
                    OrdersConflictRow(conflict: c, selected: selectedConflictId == c.id) {
                        selectConflict(c)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }

    /// 點一下選起來（同時只選一筆：取消選起來的單）；再點一下取消
    private func selectConflict(_ c: Conflict) {
        if selectedConflictId == c.id {
            selectedConflictId = nil
        } else {
            selectedConflictId = c.id
            selectedId = nil
            if tab == .open && model.checkoutTicketId == nil { model.selectedTicketId = nil }
        }
        model.touch()
    }

    private func canOpen(_ c: Conflict) -> Bool {
        guard let id = c.ticketId else { return false }
        return model.state.sales[id] != nil || model.state.tickets[id]?.isOpen == true
    }

    private func open(_ c: Conflict) {
        guard let id = c.ticketId else { return }
        if model.state.sales[id] != nil {
            select(tab: .all)
            show(ticketId: id)
        } else if model.state.tickets[id]?.isOpen == true {
            select(tab: .open)
            model.selectedTicketId = id
        }
    }

    /// 跳到某一張（換貨的原單、新單）：切到它那一天、選起來
    private func show(ticketId id: String) {
        query = ""
        if let s = model.state.sales[id] {
            day = s.businessDate == model.businessDate ? nil : s.businessDate
        } else if let archived = model.historyCache.values.first(where: { $0.sales.contains(where: { s in s.ticketId == id }) }) {
            day = archived.businessDate
        } else {
            // 還開著的單（換貨單還沒結帳）只在今天
            day = nil
        }
        selectedId = id
    }

    // MARK: - 內容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .open: board
        case .all: masterDetail
        }
    }

    // MARK: 進行中：看板

    /// 看板分不分「出餐中」：有開廚房、這個營業模式會送廚房（服飾、美業、健身沒有）
    private var boardKitchen: Bool { model.features.kitchen && model.mode.usesKitchen }
    /// 有桌位（內用）：出餐後是「用餐中」；全外帶是「出餐好了」
    private var boardTables: Bool { model.visibleSections.contains(.floor) }

    /// 外送平台的單（待接單、製作中、等取餐）：看板最上面一排，不放進下面的欄（接了就結帳了，但外送員還沒拿走）
    private var deliveryTickets: [Ticket] { model.deliveryPending + model.deliveryActive }

    @ViewBuilder
    private var board: some View {
        let openTickets = model.state.openTickets.filter { $0.delivery == nil }
        let deliveries = deliveryTickets
        if openTickets.isEmpty && deliveries.isEmpty {
            EmptyState(icon: "queue-list", title: "沒有進行中的單", message: "從「點餐」或「桌位」開單，就會出現在這裡")
        } else {
            let kitchen = boardKitchen
            VStack(alignment: .leading, spacing: 0) {
                if !deliveries.isEmpty { deliveryStrip(deliveries) }
                GeometryReader { geo in
                    // 四欄排在工作區裡（11 吋 iPad 也看得到「待結帳」那一欄）：沒有單的那一欄窄一點（只有標題與虛線框），
                    // 有單的平分剩下的；一欄至少 188，再放不下才左右滑
                    let lanes = OrdersLane.lanes(kitchen: kitchen)
                    let groups = lanes.map { lane in openTickets.filter { OrdersLane.of($0, kitchen: kitchen) == lane } }
                    let empties = CGFloat(groups.filter(\.isEmpty).count)
                    let filled = CGFloat(lanes.count) - empties
                    let avail = geo.size.width - 56 - 16 * CGFloat(lanes.count - 1)
                    let emptyWidth: CGFloat = filled > 0 ? 148 : avail / CGFloat(lanes.count)
                    let width = filled > 0 ? max(188, (avail - empties * emptyWidth) / filled) : emptyWidth
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(lanes.enumerated()), id: \.element) { i, lane in
                                OrdersLaneColumn(lane: lane, tickets: groups[i], kitchen: kitchen, tables: boardTables)
                                    .frame(width: groups[i].isEmpty ? emptyWidth : width)
                            }
                        }
                        .padding(.horizontal, 28)
                        .frame(height: geo.size.height, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .animation(Motion.fast, value: model.selectedTicketId)
        }
    }

    /// 外送平台那一排：待接單（倒數）在前、製作中、等取餐；點一下選起來，右欄接單、出餐好了
    private func deliveryStrip(_ tickets: [Ticket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("外送平台").font(.brand(15, .semibold)).foregroundStyle(Theme.ink)
                let pending = tickets.filter { $0.delivery?.status == .pending }.count
                if pending > 0 { StatusBadge("待接 \(pending)", tone: .warning) }
                Text("\(tickets.count)").font(.brand(13, .medium)).monospacedDigit().foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                ForEach(model.deliveryPaused) { p in
                    StatusBadge("\(p.platform.label) 暫停", tone: .warning)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(tickets) { t in
                        Button {
                            withAnimation(Motion.fast) {
                                model.selectedTicketId = nil
                                model.deliveryFocusId = model.deliveryFocusId == t.id ? nil : t.id
                            }
                        } label: {
                            DeliveryOrderCard(ticket: t, selected: model.deliveryFocusId == t.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    // MARK: 全部：一天的清單＋明細

    private var currentDay: String { day ?? model.businessDate }
    private var isToday: Bool { currentDay == model.businessDate }

    /// 這一天的單在哪裡：今天、昨天在這台；更早的跟後台要（model.history 會快取）
    private func phase(of date: String) -> OrdersDayPhase {
        if model.isLocal(date: date) { return .local }
        if model.historyCache[date] != nil { return .archived }
        if offlineDays.contains(date) { return .offline }
        return .loading
    }

    /// 後台那一天的資料（今天、昨天是 nil：直接讀這台的狀態）
    private func archive(of date: String) -> DayHistory? {
        model.isLocal(date: date) ? nil : model.historyCache[date]
    }

    /// 這一天的單：今天把還開著的單排最上面；其他照結帳時間新到舊
    private func entries(on date: String, archive: DayHistory?) -> [OrdersEntry] {
        if let archive {
            return archive.sales.sorted { $0.closedAt > $1.closedAt }.map { OrdersEntry.closed($0) }
        }
        let openEntries = date == model.businessDate ? model.state.openTickets.map { OrdersEntry.open($0) } : []
        let closedEntries = model.state.closedSales(businessDate: date).reversed().map { OrdersEntry.closed($0) }
        return openEntries.sorted { $0.sortDate > $1.sortDate } + closedEntries
    }

    private func filtered(_ list: [OrdersEntry]) -> [OrdersEntry] {
        list.filter { e in
            switch e {
            case .open(let t): return t.ordersMatches(query, floor: model.floor)
            case .closed(let s): return s.ordersMatches(query, invoiceNumber: invoiceNumber(s))
            }
        }
    }

    /// 現在的發票號碼（結帳後改過統編、補開的在 tickets 上，sales 只存結帳那一刻）
    private func invoiceNumber(_ s: SaleRecord) -> String? {
        (model.state.tickets[s.ticketId]?.invoice ?? s.invoice)?.number
    }

    /// 這張單的退款：這台還有的看狀態，後台的看那天的資料
    private func refunds(of s: SaleRecord, archive: DayHistory?) -> [Refund] {
        if let t = model.state.tickets[s.ticketId] { return t.refunds }
        return archive?.refunds(of: s.ticketId) ?? []
    }

    private func current(in list: [OrdersEntry], autoSelect: Bool) -> OrdersEntry? {
        if let id = selectedId, let e = list.first(where: { $0.id == id }) { return e }
        return autoSelect ? list.first : nil
    }

    @ViewBuilder
    private var masterDetail: some View {
        let date = currentDay
        let dayArchive = archive(of: date)
        let list = filtered(entries(on: date, archive: dayArchive))
        GeometryReader { geo in
            if geo.size.width >= 680 {
                HStack(spacing: 0) {
                    master(list, date: date, archive: dayArchive, currentId: selectedId)
                        .frame(width: min(340, max(300, geo.size.width * 0.36)))
                    Rule(vertical: true)
                    detailPane(current(in: list, autoSelect: false), archive: dayArchive, close: nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.surface)
                }
                .overlay(alignment: .top) { Rule() }
            } else {
                // 直的 iPad：清單滿版，明細從右邊滑進來
                ZStack(alignment: .trailing) {
                    master(list, date: date, archive: dayArchive, currentId: selectedId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let e = current(in: list, autoSelect: false) {
                        // 蓋住清單的暗幕（深、淺色都用黑的半透明）
                        Color.black.opacity(0.22)
                            .contentShape(.rect)
                            .onTapGesture { selectedId = nil }
                            .transition(.opacity)
                        detailPane(e, archive: dayArchive, close: { selectedId = nil })
                            .frame(maxWidth: 520, maxHeight: .infinity)
                            .background(Theme.sheet)
                            .overlay(alignment: .leading) { Rule(vertical: true) }
                            .shadow(color: .black.opacity(0.16), radius: 28, x: -6, y: 0)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
                .overlay(alignment: .top) { Rule() }
                .animation(Motion.ease, value: selectedId)
            }
        }
        .task(id: date) { await loadIfNeeded(date) }
    }

    /// 更早的日子：跟後台要一次（之後在記憶體快取）；拿不到記下來，畫面上給「重試」
    private func loadIfNeeded(_ date: String) async {
        guard !model.isLocal(date: date), model.historyCache[date] == nil else { return }
        offlineDays.remove(date)
        let h = await model.history(date: date)
        if h == nil { offlineDays.insert(date) }
    }

    /// 左邊的清單；currentId＝右邊正在看的那一張（標橘色邊）
    private func master(_ list: [OrdersEntry], date: String, archive: DayHistory?, currentId: String?) -> some View {
        let dayPhase = phase(of: date)
        return VStack(spacing: 0) {
            OrdersDayBar(title: OrdersDays.title(date, today: model.businessDate), summary: daySummary(list, phase: dayPhase),
                         isToday: date == model.businessDate, step: { stepDay($0) }, today: { goToday() })
                .padding(.horizontal, 16)
                .padding(.top, 12)
            searchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Rule(color: Theme.hair)
            switch dayPhase {
            case .loading:
                OrdersRemoteState(loading: true, title: "向後台拿這天的單…", message: "這台 iPad 只留最近兩天；更早的在後台", retry: nil)
            case .offline:
                OrdersRemoteState(loading: false, title: "連不到後台", message: "更早的單存在後台；連上網路後再試一次",
                                  retry: { Task { await loadIfNeeded(date) } })
            case .local, .archived:
                if list.isEmpty {
                    if query.isEmpty {
                        EmptyState(icon: "receipt-refund", title: date == model.businessDate ? "今天還沒有單" : "這天沒有單",
                                   message: dayPhase == .archived ? "後台這一天沒有結帳紀錄" : "開單、結帳之後會出現在這裡")
                    } else {
                        EmptyState(icon: "magnifying-glass", title: "找不到「\(query)」", message: "可以搜單號、桌號、客人、發票號碼或金額")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { e in
                                Button {
                                    // 點一下選起來、再點一下取消；同時只選一筆
                                    selectedId = selectedId == e.id ? nil : e.id
                                    selectedConflictId = nil
                                    model.touch()
                                } label: {
                                    OrdersEntryRow(entry: e, selected: e.id == currentId, refunds: entryRefunds(e, archive: archive))
                                }
                                .buttonStyle(.row)
                                Rule(color: Theme.hair)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .background(Theme.page)
    }

    private func entryRefunds(_ e: OrdersEntry, archive: DayHistory?) -> [Refund] {
        switch e {
        case .open: return []
        case .closed(let s): return refunds(of: s, archive: archive)
        }
    }

    /// 「12 張・已結 $8,640」
    private func daySummary(_ list: [OrdersEntry], phase: OrdersDayPhase) -> String {
        switch phase {
        case .loading: return "向後台拿…"
        case .offline: return "在後台"
        case .local, .archived:
            var closed = Money.zero
            for e in list {
                if case .closed(let s) = e { closed += s.total }
            }
            let tail = phase == .archived ? "・後台" : ""
            return "\(list.count) 張・已結 \(closed.short)\(tail)"
        }
    }

    private func stepDay(_ delta: Int) {
        guard let next = OrdersDays.shift(currentDay, by: delta) else { return }
        // 不往未來走；回到今天就交給 nil（跟著營業日換日）
        day = next >= model.businessDate ? nil : next
        selectedId = nil
        model.touch()
    }

    private func goToday() {
        day = nil
        selectedId = nil
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            OrdersSearchField(text: $query)
            Button {
                Task { await askSearchDigits() }
            } label: {
                HeroIcon("calculator", size: 18)
            }
            .buttonStyle(SquareIconButtonStyle(size: 42))
            .accessibilityLabel("用右側鍵盤打數字搜尋")
        }
    }

    /// 金額、發票號碼都是數字：從右側鍵盤打（不叫出系統鍵盤）
    private func askSearchDigits() async {
        let spec = KeypadSpec(kind: .code(minLength: 1, maxLength: 10), title: "搜尋", subtitle: "金額、單號或發票號碼裡的數字", confirmLabel: "搜尋")
        guard let e = await model.keypad.ask(spec) else { return }
        query = e.digits
        selectedId = nil
    }

    @ViewBuilder
    private func detailPane(_ entry: OrdersEntry?, archive: DayHistory?, close: (() -> Void)?) -> some View {
        switch entry {
        case .none:
            EmptyState(icon: "queue-list", title: "選一張單", message: "左邊點一下，明細出現在這裡、動作在右邊")
        case .some(.open(let t)):
            OrdersOpenDetail(ticket: t, close: close, openTicket: { show(ticketId: $0) })
                .id(t.id)
        case .some(.closed(let s)):
            OrdersSaleDetail(sale: s, archive: archive, close: close, deselect: { selectedId = nil }, openTicket: { show(ticketId: $0) })
                .id(s.ticketId)
        }
    }
}

// MARK: - 分頁

private enum OrdersTab: String, CaseIterable, Identifiable {
    case open, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "進行中"
        case .all: "全部"
        }
    }
}

private struct OrdersSegment: View {
    let selection: OrdersTab
    let openCount: Int
    let allCount: Int
    let select: (OrdersTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(OrdersTab.allCases) { t in
                Button {
                    select(t)
                } label: {
                    HStack(spacing: 7) {
                        Text(t.label)
                        Text(String(t == .open ? openCount : allCount))
                            .monospacedDigit()
                            .opacity(0.6)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                }
                .buttonStyle(OrdersSegmentStyle(selected: selection == t))
                .accessibilityAddTraits(selection == t ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }
}

private struct OrdersSegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(14.5, .medium))
            .foregroundStyle(selected ? Theme.page : Theme.ink2)
            .background(selected ? Theme.ink : (configuration.isPressed ? Theme.press : Color.clear),
                        in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .contentShape(.rect)
            .animation(Motion.fast, value: selected)
    }
}

// MARK: - 看板

/// 單子在哪一欄：印了結帳單 → 待結帳；沒點東西或有還沒送的 → 點餐中；廚房還在做 → 出餐中；都上了 → 用餐中
private enum OrdersLane: String, CaseIterable, Identifiable {
    case ordering, cooking, dining, billing

    var id: String { rawValue }

    /// 這家店的看板有哪幾欄：會送廚房的店四欄；沒有廚房的店（服飾、美業、健身…）只有「進行中」「待結帳」
    static func lanes(kitchen: Bool) -> [OrdersLane] {
        kitchen ? allCases : [.ordering, .billing]
    }

    func title(kitchen: Bool, tables: Bool) -> String {
        switch self {
        case .ordering: kitchen ? "點餐中" : "進行中"
        case .cooking: "出餐中"
        case .dining: tables ? "用餐中" : "出餐好了"
        case .billing: "待結帳"
        }
    }

    func emptyText(kitchen: Bool, tables: Bool) -> String {
        switch self {
        case .ordering: kitchen ? "沒有在點餐的" : "沒有進行中的單"
        case .cooking: "廚房沒有在做的"
        case .dining: tables ? "沒有用餐中的" : "沒有等取餐的"
        case .billing: "沒有等結帳的"
        }
    }

    var tone: Tone {
        switch self {
        case .ordering: .gold
        case .cooking: .info
        case .dining: .active
        case .billing: .warning
        }
    }

    static func of(_ t: Ticket, kitchen: Bool) -> OrdersLane {
        if t.billPrintedAt != nil { return .billing }
        let lines = t.activeLines
        if lines.isEmpty { return .ordering }
        // 沒有廚房的店：還沒印結帳單的都是「進行中」
        guard kitchen else { return .ordering }
        if lines.contains(where: { $0.kitchen == .new }) { return .ordering }
        if lines.contains(where: { $0.kitchen != .served }) { return .cooking }
        return .dining
    }
}

private struct OrdersLaneColumn: View {
    let lane: OrdersLane
    let tickets: [Ticket]
    let kitchen: Bool
    let tables: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Rule()
            if tickets.isEmpty {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 88)
                    .overlay {
                        Text(lane.emptyText(kitchen: kitchen, tables: tables))
                            .textRole(.small)
                            .foregroundStyle(Theme.faint)
                    }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(tickets) { t in
                            OrdersTicketCard(ticket: t)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(lane.tone.dot)
                .frame(width: 7, height: 7)
            Text(lane.title(kitchen: kitchen, tables: tables))
                .font(.brand(15, .semibold))
                .foregroundStyle(Theme.ink)
            Text(String(tickets.count))
                .font(.brand(14, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(laneTotal.short)
                .font(.brand(13.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }

    private var laneTotal: Money { Money.sum(tickets.map { $0.totals.total }) }
}

/// 看板上的一張單：整張點一下＝選起來（橘框；右欄出現這張單的動作），再點一下取消。卡片上沒有按鈕
private struct OrdersTicketCard: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket

    private var selected: Bool { model.selectedTicketId == ticket.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            metaRow
            Rule(color: Theme.hair)
            amountRow
        }
        .padding(16)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { toggleSelection() }
        .animation(Motion.fast, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggleSelection() {
        model.selectedTicketId = selected ? nil : ticket.id
        model.touch()
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ticket.title(floor: model.floor))
                .textRole(.h4)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(ticket.number)
                .font(.brand(13, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            TimelineView(.everyMinute) { context in
                OrdersElapsed(minutes: minutes(at: context.date), limit: timeLimit)
            }
            if ticket.guests > 0 {
                metaText("\(ticket.guests) 位")
            }
            metaText("\(ticket.itemCount) 項")
            Spacer(minLength: 0)
            if model.features.kitchen && !ticket.activeLines.isEmpty {
                // 欄窄（直的 iPad）放不下就不畫出餐的點，時間、人數、項數不換行
                ViewThatFits(in: .horizontal) {
                    OrdersKitchenDots(lines: ticket.activeLines)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func metaText(_ s: String) -> some View {
        Text(s)
            .font(.brand(13, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .fixedSize()
    }

    private func minutes(at date: Date) -> Int {
        max(Int(date.timeIntervalSince(ticket.openedAt) / 60), 0)
    }

    /// 只有內用算用餐時間限制
    private var timeLimit: Int {
        ticket.orderType == .dineIn ? model.store.tableTimeLimitMinutes : 0
    }

    private var amountRow: some View {
        let totals = ticket.totals
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            MoneyText(money: totals.total, role: .number)
            if totals.paid.cents > 0 {
                Text("已收 \(totals.paid.short)")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.successFG)
            }
            Spacer(minLength: 4)
            if ticket.billPrintedAt != nil {
                StatusBadge(ticket.billSentFrom.map { "\($0)送來結帳" } ?? "已印結帳單", tone: .warning)
            }
        }
    }
}

/// 坐了多久（有用餐時間限制的店：快到了黃、超過了紅）
private struct OrdersElapsed: View {
    let minutes: Int
    let limit: Int

    var body: some View {
        HStack(spacing: 4) {
            HeroIcon("clock", size: 13)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .font(.brand(13, .medium))
        .foregroundStyle(color)
    }

    private var text: String {
        // 超過一小時寫短一點（「1時34分」）：欄窄的時候也不會斷成兩行
        minutes < 60 ? "\(minutes) 分" : "\(minutes / 60)時\(minutes % 60)分"
    }

    private var color: Color {
        guard limit > 0 else { return Theme.muted }
        if minutes >= limit { return Theme.dangerFG }
        if minutes >= limit - 10 { return Theme.warningFG }
        return Theme.muted
    }
}

/// 出餐進度：一個品項一個點（灰＝還沒送、藍＝已送單、黃＝製作中、橘＝可出餐、綠＝已上菜）
private struct OrdersKitchenDots: View {
    let lines: [TicketLine]

    private static let maxDots = 10

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(lines.prefix(Self.maxDots))) { l in
                Circle()
                    .fill(color(l.kitchen))
                    .frame(width: 7, height: 7)
            }
            if lines.count > Self.maxDots {
                Text("+\(lines.count - Self.maxDots)")
                    .font(.brand(11, .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已上菜 \(served)／\(lines.count)")
    }

    private var served: Int { lines.filter { $0.kitchen == .served }.count }

    private func color(_ s: KitchenStatus) -> Color {
        switch s {
        case .new: Theme.faint
        case .sent: Theme.infoFG
        case .preparing: Theme.warningFG
        case .ready: Theme.accent
        case .served: Theme.live
        }
    }
}

// MARK: - 全部：清單

/// 一天的單在哪裡：這台（今天、昨天）、後台已經拿到、正在拿、拿不到（離線）
private enum OrdersDayPhase: Equatable {
    case local
    case archived
    case loading
    case offline
}

/// 向後台拿資料時的安靜狀態：小轉圈或「連不到」＋重試
private struct OrdersRemoteState: View {
    let loading: Bool
    let title: String
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                    .controlSize(.regular)
            } else {
                HeroIcon("cloud", size: 28)
                    .foregroundStyle(Theme.faint)
            }
            Text(title)
                .textRole(.h4)
                .foregroundStyle(Theme.ink2)
            Text(message)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if let retry {
                Button("重試", action: retry)
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 營業日（YYYY-MM-DD）的換算：往前往後一天、畫面上的標題
private enum OrdersDays {
    /// 那天中午（台北）：避開凌晨的營業日分界
    static func noon(_ date: String) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = 12
        return TaipeiTime.calendar.date(from: c)
    }

    static func shift(_ date: String, by days: Int) -> String? {
        guard let d = noon(date), let moved = TaipeiTime.calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return TaipeiTime.dayString(moved)
    }

    /// 「今天・10月4日」「昨天・10月3日」「10月1日・星期四」
    static func title(_ date: String, today: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        let md = "\(parts[1])月\(parts[2])日"
        if date == today { return "今天・\(md)" }
        if shift(date, by: 1) == today { return "昨天・\(md)" }
        guard let d = noon(date) else { return md }
        return "\(md)・\(d.weekdayText)"
    }
}

/// 清單上的一張：還開著的單，或已結帳的那一筆
private enum OrdersEntry: Identifiable {
    case open(Ticket)
    case closed(SaleRecord)

    var id: String {
        switch self {
        case .open(let t): t.id
        case .closed(let s): s.ticketId
        }
    }

    var sortDate: Date {
        switch self {
        case .open(let t): t.openedAt
        case .closed(let s): s.closedAt
        }
    }
}

/// 「‹ 今天・10月4日 ›」：一次看一天
private struct OrdersDayBar: View {
    let title: String
    let summary: String
    let isToday: Bool
    let step: (Int) -> Void
    let today: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                step(-1)
            } label: {
                HeroIcon("chevron-right", size: 14)
                    .rotationEffect(.degrees(180))
            }
            .buttonStyle(SquareIconButtonStyle(size: 34))
            .accessibilityLabel("前一天")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(summary)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isToday {
                Button("今天", action: today)
                    .buttonStyle(.brand(.quiet, size: .sm))
            }
            Button {
                step(1)
            } label: {
                HeroIcon("chevron-right", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle(size: 34))
            .disabled(isToday)
            .opacity(isToday ? 0.35 : 1)
            .accessibilityLabel("後一天")
        }
    }
}

private struct OrdersEntryRow: View {
    @Environment(POSModel.self) private var model
    let entry: OrdersEntry
    let selected: Bool
    /// 這張單的退款（這台的或後台那天的）
    let refunds: [Refund]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(amount.formatted)
                    .font(.brand(17, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(timeLine)
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(place)
                    .font(.brand(14, .regular))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(status.text)
                    .font(.brand(13, .semibold))
                    .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(selected ? Theme.press : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var amount: Money {
        switch entry {
        case .open(let t): t.totals.total
        case .closed(let s): s.total
        }
    }

    /// 「A023・14:05」
    private var timeLine: String {
        switch entry {
        case .open(let t): "\(t.number)・\(t.openedAt.clockText)"
        case .closed(let s): "\(s.number)・\(s.closedAt.clockText)"
        }
    }

    /// 「A2・4 位」「外帶」「王小美」
    private var place: String {
        switch entry {
        case .open(let t):
            let title = t.title(floor: model.floor)
            return t.guests > 0 ? "\(title)・\(t.guests) 位" : title
        case .closed(let s):
            return s.guests > 0 ? "\(s.ordersTitle)・\(s.guests) 位" : s.ordersTitle
        }
    }

    /// 進行中用品牌橘，其他淡色
    private var status: (text: String, color: Color) {
        switch entry {
        case .open(let t):
            return (t.exchange != nil ? "換貨中" : "進行中", Theme.accentText)
        case .closed(let s):
            // 換貨退回的不是真的退錢：寫「已換貨」
            if refunds.contains(where: { $0.tender == .exchange }) { return ("已換貨", Theme.muted) }
            let refunded = Money.sum(refunds.map(\.amount))
            if refunded.cents > 0 {
                return (refunded >= s.total + s.tip ? "已退款" : "部分退款", Theme.muted)
            }
            if s.exchange != nil { return ("換貨單", Theme.muted) }
            return ("已結帳", Theme.muted)
        }
    }
}

private struct OrdersSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            HeroIcon("magnifying-glass", size: 16)
                .foregroundStyle(Theme.muted)
            TextField("單號、桌號、客人、發票、金額", text: $text)
                .font(.brand(15, .regular))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    HeroIcon("x-mark", size: 14)
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }
}

// MARK: - 明細的共用元件

/// 窄的時候（明細從右邊滑進來）才有的關閉列
private struct OrdersDetailTopBar: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Eyebrow(title)
            Spacer(minLength: 8)
            Button(action: close) {
                HeroIcon("x-mark", size: 16)
            }
            .buttonStyle(SquareIconButtonStyle(size: 38))
            .accessibilityLabel("關閉")
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// 大金額＋「已付款・經手 Cameron W.」＋單號、桌號、時間
private struct OrdersDetailHero: View {
    let amount: Money
    let status: String
    let tone: Tone
    let byline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MoneyText(money: amount, role: .stat)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(status)
                    .font(.brand(16, .semibold))
                    .foregroundStyle(tone.foreground)
                Text("・\(byline)")
                    .font(.brand(16, .regular))
                    .foregroundStyle(Theme.ink2)
            }
            Text(detail)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// 會員／客人的小卡（名字、等級、電話）
private struct OrdersCustomerCard: View {
    let name: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            StaffAvatar(name: name, swatch: .lavender, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(.brand(13, .regular))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }

    /// 會員：名字（沒有名字就用遮起來的電話）＋等級・電話；外帶稱呼：名字＋「客人稱呼」
    static func info(member: MemberRef?, customerName: String?) -> (name: String, detail: String?)? {
        if let m = member {
            let parts = [m.tierName, m.name == nil ? nil : m.maskedPhone].compactMap { $0 }
            return (m.name ?? m.maskedPhone, parts.isEmpty ? "會員" : parts.joined(separator: "・"))
        }
        if let n = customerName, !n.isEmpty { return (n, "客人稱呼") }
        return nil
    }
}

/// 一個品項：名字（含規格）×數量、種類標籤、加料／設計師／換規格的小字、金額（有折扣時原價劃掉；課程卡抵的寫「卡抵」）
private struct OrdersItemRow: View {
    let name: String
    let quantity: Int
    let notes: [String]
    let badge: String?
    let redeemName: String?
    let amount: Money
    let original: Money

    init(name: String, quantity: Int, notes: [String] = [], badge: String? = nil, redeemName: String? = nil, amount: Money, original: Money) {
        self.name = name
        self.quantity = quantity
        self.notes = notes
        self.badge = badge
        self.redeemName = redeemName
        self.amount = amount
        self.original = original
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(Theme.ink)
                    Text("×\(quantity)")
                        .font(.brand(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    if let badge {
                        StatusBadge(badge, tone: .info)
                    }
                }
                if let redeemName {
                    Text("卡抵・\(redeemName)")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.accentText)
                }
                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                    Text(n)
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 12)
            if redeemName != nil {
                Text("卡抵")
                    .font(.brand(15.5, .medium))
                    .foregroundStyle(Theme.accentText)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(amount.formatted)
                        .font(.brand(15.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    if original != amount {
                        Text(original.formatted)
                            .strikethrough()
                            .font(.brand(12.5, .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 儲值、課程卡賣出時標出來（記在會員身上，不是一般商品）
    static func badge(for kind: ItemKind?) -> String? {
        switch kind ?? .goods {
        case .storedValue: return "儲值"
        case .pass: return "課程卡"
        case .goods, .service: return nil
        }
    }
}

/// 「現金」「信用卡 ****4021」＋金額；下面一行小字是時間、收找、序號
private struct OrdersPaymentRow: View {
    let payment: Payment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.brand(15.5, .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            Text(payment.amount.formatted)
                .font(.brand(15.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
    }

    private var title: String {
        if let last4 = payment.cardLast4, !last4.isEmpty { return "\(payment.tender.label) ****\(last4)" }
        return payment.tender.label
    }

    private var detail: String {
        var parts = [payment.at.clockText]
        if payment.tender == .cash, let t = payment.tendered {
            parts.append("收 \(t.formatted)")
            if payment.change.cents > 0 { parts.append("找 \(payment.change.formatted)") }
        } else if payment.change.cents > 0 {
            // 換貨：退回的比新買的多，差額從錢櫃退現金
            parts.append("退差額 \(payment.change.formatted)（現金）")
        }
        if payment.tender == .exchange, let ref = payment.reference, !ref.isEmpty {
            parts.append("原單 \(ref)")
        } else if let ref = payment.reference, !ref.isEmpty {
            parts.append("序號 \(ref)")
        }
        return parts.joined(separator: "・")
    }
}

/// 「換貨單：抵原單 A012 NT$1,280      看原單」
private struct OrdersLinkRow: View {
    let icon: String
    let text: String
    let linkTitle: String
    let run: () -> Void

    /// 整列是連結（跳到那一張、選起來），不是按鈕
    var body: some View {
        Button(action: run) {
            HStack(alignment: .center, spacing: 10) {
                HeroIcon(icon, size: 16)
                    .foregroundStyle(Theme.ink2)
                Text(text)
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(linkTitle)
                    .font(.brand(13.5, .medium))
                    .foregroundStyle(Theme.accentText)
                HeroIcon("chevron-right", size: 13)
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}

// MARK: - 明細：進行中的單

private struct OrdersOpenDetail: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket
    let close: (() -> Void)?
    let openTicket: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                OrdersDetailTopBar(title: ticket.exchange != nil ? "換貨單" : "進行中的單", close: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    OrdersDetailHero(amount: ticket.totals.total, status: ticket.exchange != nil ? "換貨中" : "進行中", tone: .gold,
                                     byline: "開單 \(model.staffName(ticket.openedBy))", detail: heroDetail)
                    if let c = OrdersCustomerCard.info(member: ticket.member, customerName: ticket.customerName) {
                        OrdersCustomerCard(name: c.name, detail: c.detail)
                    }
                    if let x = ticket.exchange {
                        OrdersLinkRow(icon: "arrows-right-left", text: "換貨單：抵原單 \(x.number) \(x.amount.formatted)", linkTitle: "看原單") {
                            openTicket(x.ticketId)
                        }
                    }
                    items
                    totals
                    if !ticket.approvedPayments.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("已收")
                            ForEach(ticket.approvedPayments) { p in
                                OrdersPaymentRow(payment: p)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            // 動作（結帳、點餐、印結帳單、作廢）在右欄：OrdersView 交上去
        }
    }

    private var heroDetail: String {
        var parts = [ticket.number, ticket.title(floor: model.floor)]
        if ticket.guests > 0 { parts.append("\(ticket.guests) 位") }
        if let s = ticket.salespersonId { parts.append("銷售 \(model.staffName(s))") }
        parts.append("\(ticket.openedAt.clockText) 開單")
        return parts.joined(separator: "・")
    }

    /// 每一行指定服務人員的模式（美業、課程）：寫出設計師／教練與助理
    private var perLineStaff: Bool { ticket.serviceMode?.staffPerLine == true }

    private func notes(for l: TicketLine) -> [String] {
        var out: [String] = []
        if !l.modifierText.isEmpty { out.append(l.modifierText) }
        if perLineStaff || l.staffId != nil || l.assistantId != nil {
            let title = (ticket.serviceMode ?? model.mode).staffTitle
            var who = "\(title) \(model.staffName(ticket.performer(of: l)))"
            if let a = l.assistantId { who += "・助理 \(model.staffName(a))" }
            out.append(who)
        }
        if !l.note.isEmpty { out.append("備註：\(l.note)") }
        return out
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("品項・\(ticket.itemCount) 項")
            if ticket.activeLines.isEmpty {
                Text("還沒點東西")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(ticket.activeLines) { l in
                OrdersItemRow(name: l.displayName, quantity: l.quantity, notes: notes(for: l), badge: OrdersItemRow.badge(for: l.kind),
                              redeemName: l.redeem?.name, amount: l.gross - l.lineDiscount, original: l.gross)
            }
        }
    }

    private var totals: some View {
        let t = ticket.totals
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("金額")
            ValueRow(label: "小計", value: t.itemsGross.formatted)
            if t.discountTotal.cents > 0 {
                ValueRow(label: "折扣", value: "−\(t.discountTotal.formatted)", tone: Theme.accentText)
            }
            if t.serviceCharge.cents > 0 {
                ValueRow(label: "服務費", value: t.serviceCharge.formatted)
            }
            Rule(color: Theme.hair)
                .padding(.vertical, 2)
            ValueRow(label: "總計", value: t.total.formatted, strong: true)
            if let x = ticket.exchange {
                ValueRow(label: "退回的商品抵", value: "−\(x.amount.formatted)", tone: Theme.accentText)
            }
            if t.paid.cents > 0 {
                ValueRow(label: "已收", value: t.paid.formatted, tone: Theme.successFG)
                ValueRow(label: "還要收", value: t.balance.formatted, strong: true)
            }
        }
    }
}

// MARK: - 明細：已結帳的那一筆

private enum OrdersDetailForm: Equatable {
    case buyer, refund, exchange
}

/// 退款怎麼算：照品項（金額照原單實收，庫存、課程卡、儲值跟著退）或照金額（右側鍵盤打）
private enum OrdersRefundMode: Equatable {
    case items, amount
}

private enum OrdersRefundReason: String, CaseIterable, Identifiable {
    case cancelled = "客人取消"
    case quality = "商品／服務問題"
    case mistake = "點錯"
    case other = "其他"

    var id: String { rawValue }
}

/// 發票現在的買方是哪一種（改統編／載具時標出目前的選項）
private enum OrdersBuyerKind {
    case paper, carrier, business, donation

    init(_ buyer: InvoiceBuyer?) {
        switch buyer {
        case .none: self = .paper
        case .some(.consumer(let carrier)): self = carrier == nil ? .paper : .carrier
        case .some(.business): self = .business
        case .some(.donation): self = .donation
        }
    }
}

/// 結帳後同款換規格的紀錄：每一行現在是哪個規格、換了哪些（「白・M → 白・L」）
private struct OrdersSwapState {
    var names: [String: String] = [:]
    var skus: [String: String] = [:]
    var texts: [String] = []

    init(sale: SaleRecord, swaps: [VariantSwap]) {
        for s in swaps {
            let line = sale.lines.first(where: { $0.lineId == s.lineId })
            let from = names[s.lineId] ?? line?.variantName ?? "原規格"
            texts.append("\(line?.name ?? "品項") \(from) → \(s.toVariantName)・\(s.quantity) 件")
            names[s.lineId] = s.toVariantName
            skus[s.lineId] = s.toSkuId
        }
    }
}

private struct OrdersSaleDetail: View {
    @Environment(POSModel.self) private var model
    let sale: SaleRecord
    /// 後台那一天的資料（超過兩天的單：只能看、補印收據）；這台還有的是 nil
    let archive: DayHistory?
    let close: (() -> Void)?
    /// 取消選取（右欄的 ×）
    let deselect: () -> Void
    let openTicket: (String) -> Void

    /// 右欄蓋著的面板：退款、換貨、改統編／載具
    @State private var form: OrdersDetailForm?
    @State private var showCarrier = false
    @State private var carrier = ""
    @State private var carrierError: String?
    @State private var refundTender: Tender?
    @State private var showAllTenders = false
    @State private var refundReason: OrdersRefundReason = .cancelled
    @State private var otherReason = ""
    /// 照品項退／照金額退（nil＝照這張單決定：服飾、課程卡、儲值照品項；餐廳照金額）
    @State private var refundMode: OrdersRefundMode?
    /// 照品項退：每一行退幾件（lineId → 件數）
    @State private var refundPicked: [String: Int] = [:]
    /// 換貨：每一行退回幾件（lineId → 件數）。放在這裡、不放在面板裡：鍵盤問件數時面板會先拿掉
    @State private var exchangePicked: [String: Int] = [:]
    /// 換貨面板正在選「同款換規格」的那一行
    @State private var swapLineId: String?

    // 讀最新的：結帳後改統編、補開、退款、換規格都記在 tickets 上（sales 只存結帳那一刻）
    private var ticket: Ticket? { model.state.tickets[sale.ticketId] }
    private var stamp: InvoiceStamp? { ticket?.invoice ?? sale.invoice }
    private var invoice: EInvoice? { stamp.flatMap { model.state.invoices[$0.number] } }
    private var voidInfo: VoidInfo? { stamp.flatMap { model.state.voidedInvoices[$0.number] } }
    private var isVoided: Bool {
        guard let s = stamp else { return false }
        return s.isVoided || voidInfo != nil || archive?.voidedInvoiceNumbers.contains(s.number) == true
    }
    private var refunds: [Refund] { ticket?.refunds ?? archive?.refunds(of: sale.ticketId) ?? [] }
    private var refunded: Money { Money.sum(refunds.map(\.amount)) }
    /// 這台還有這張單（最近兩天）：可以退款、換貨、改發票；更早的只在後台
    private var isEditable: Bool { model.state.sales[sale.ticketId] != nil }
    private var issuesInvoices: Bool { isEditable && model.issuesInvoices }
    private var refundable: Money { sale.total + sale.tip - refunded }
    private var invoiceEnabled: Bool { model.features.invoice && model.invoiceSettings.enabled }
    private var buyerKind: OrdersBuyerKind { OrdersBuyerKind(stamp?.buyer) }
    private var itemCount: Int { sale.lines.reduce(0) { $0 + $1.quantity } }
    private var swapState: OrdersSwapState { OrdersSwapState(sale: sale, swaps: ticket?.swaps ?? []) }
    /// 這張換出去的換貨單（原單上寫「已換貨 →A015」）
    private var exchangeTickets: [Ticket] {
        model.state.tickets.values
            .filter { $0.exchange?.ticketId == sale.ticketId && $0.status != .voided }
            .sorted { $0.openedAt < $1.openedAt }
    }
    private var exchangedByExchange: Bool { refunds.contains(where: { $0.tender == .exchange }) }

    /// 存載具、捐贈的發票不印證明聯，也就不能「補印」
    private var canReprintProof: Bool {
        guard issuesInvoices, let s = stamp, !isVoided, invoice != nil else { return false }
        return invoice?.printed ?? s.buyer.printsProof
    }

    private var canChangeBuyer: Bool { issuesInvoices && stamp != nil && !isVoided }

    private var canIssueLate: Bool {
        issuesInvoices && stamp == nil && invoiceEnabled && sale.total.cents > 0 && refunds.isEmpty
    }

    /// 退款要能收錢的崗位，而且這台還有這張單
    private var canRefund: Bool { isEditable && model.takesPayment }

    /// 還有可以退回的商品、還在換貨期限內（換貨單會開在這台，要能開單）
    private var canExchangeNow: Bool {
        guard isEditable, model.role.takesOrders, model.canExchange(sale) else { return false }
        return model.returnableQuantities(sale).values.contains(where: { $0 > 0 })
    }

    /// 每一行指定服務人員的單（美業、課程）：寫出設計師／教練與助理
    private var perLineStaff: Bool {
        sale.serviceMode?.staffPerLine == true || sale.lines.contains(where: { $0.assistantId != nil })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                OrdersDetailTopBar(title: "交易明細", close: close)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if let f = form {
                            Banner(text: "\(formTitle(f))：在右邊選，件數、金額在右邊的鍵盤打", tone: .info)
                        }
                        OrdersDetailHero(amount: sale.total, status: statusText, tone: statusTone,
                                         byline: "經手 \(sale.staffName)", detail: heroDetail)
                        if let c = OrdersCustomerCard.info(member: sale.member, customerName: sale.customerName) {
                            OrdersCustomerCard(name: c.name, detail: c.detail)
                        }
                        if showCarrier {
                            carrierCard
                                .id("orders-form")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        lineList
                        totalsBlock
                        paymentsBlock
                        exchangeBlock
                        invoiceBlock
                        if !refunds.isEmpty {
                            refundList
                        }
                        if !isEditable {
                            Text("超過兩天的單請到後台處理（退款、換貨、發票）；這裡可以補印收據。")
                                .textRole(.xs)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .animation(Motion.fast, value: showCarrier)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: showCarrier) { _, on in
                    guard on else { return }
                    withAnimation(Motion.ease) { proxy.scrollTo("orders-form", anchor: .top) }
                }
            }
        }
        .dockSelection(saleDock)
        .dockPanel(isPresented: formBinding(.refund), title: "退款", subtitle: "\(sale.number)・最多可退 \(refundable.formatted)") {
            refundPanel
        }
        .dockPanel(isPresented: formBinding(.exchange), title: "換貨", subtitle: exchangeSubtitle) {
            exchangePanel
        }
        .dockPanel(isPresented: formBinding(.buyer), title: "改統編／載具",
                   subtitle: "會作廢 \(stamp?.display ?? "原發票")、用同一筆交易重開一張（同一期才行，要店長授權）") {
            buyerPanel
        }
    }

    private func formTitle(_ f: OrdersDetailForm) -> String {
        switch f {
        case .buyer: "改統編／載具"
        case .refund: "退款"
        case .exchange: "換貨"
        }
    }

    private func formBinding(_ f: OrdersDetailForm) -> Binding<Bool> {
        Binding(get: { form == f }, set: { on in
            if on { form = f } else if form == f { form = nil }
        })
    }

    // MARK: 上面

    private var statusText: String {
        if exchangedByExchange { return refundable.cents <= 0 ? "已換貨" : "部分換貨" }
        if refunded.cents > 0 { return refundable.cents <= 0 ? "已退款" : "部分退款 \(refunded.formatted)" }
        return "已付款"
    }

    private var statusTone: Tone {
        if exchangedByExchange { return .info }
        if refunded.cents > 0 { return refundable.cents <= 0 ? .danger : .warning }
        return .active
    }

    private var heroDetail: String {
        var parts = [sale.number, sale.ordersTitle]
        if sale.guests > 0 { parts.append("\(sale.guests) 位") }
        if let s = sale.salespersonId { parts.append("銷售 \(model.staffName(s))") }
        parts.append("\(sale.closedAt.dayText) \(sale.closedAt.clockText)")
        return parts.joined(separator: "・")
    }

    // MARK: 品項、金額、付款

    private func notes(for l: SaleLine) -> [String] {
        var out: [String] = []
        if !l.modifiers.isEmpty { out.append(l.modifiers) }
        if perLineStaff, let s = l.staffId {
            let title = (sale.serviceMode ?? model.mode).staffTitle
            var who = "\(title) \(model.staffName(s))"
            if let a = l.assistantId { who += "・助理 \(model.staffName(a))" }
            out.append(who)
        }
        if let now = swapState.names[l.lineId] { out.append("已換成 \(now)") }
        return out
    }

    private var lineList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("品項・\(itemCount) 項")
            ForEach(sale.lines, id: \.lineId) { l in
                OrdersItemRow(name: l.displayName, quantity: l.quantity, notes: notes(for: l), badge: OrdersItemRow.badge(for: l.kind),
                              redeemName: l.redeem?.name, amount: l.net, original: l.gross)
            }
            if sale.voidedItems > 0 {
                Text("另有作廢 \(sale.voidedItems) 項（\(sale.voidedAmount.formatted)），不算錢")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            if !sale.note.isEmpty {
                Text("備註：\(sale.note)")
                    .textRole(.small)
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var totalsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("金額")
            ValueRow(label: "小計", value: sale.itemsGross.formatted)
            if sale.discount.cents > 0 {
                ValueRow(label: discountLabel, value: "−\(sale.discount.formatted)", tone: Theme.accentText)
            }
            if sale.serviceCharge.cents > 0 {
                ValueRow(label: "服務費", value: sale.serviceCharge.formatted)
            }
            Rule(color: Theme.hair)
                .padding(.vertical, 2)
            ValueRow(label: "總計", value: sale.total.formatted, strong: true)
            if sale.tip.cents > 0 {
                ValueRow(label: "小費（不開發票）", value: sale.tip.formatted)
            }
            ValueRow(label: "含營業稅", value: sale.tax.formatted, tone: Theme.muted)
        }
    }

    private var discountLabel: String {
        if let r = sale.discountReason, !r.isEmpty { return "折扣・\(r)" }
        return "折扣"
    }

    private var paymentsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("付款")
            if sale.payments.isEmpty {
                Text(sale.total.cents == 0 ? "不用收錢（課程卡抵、招待）" : "沒有收款紀錄")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(sale.payments) { p in
                OrdersPaymentRow(payment: p)
            }
        }
    }

    // MARK: 換貨

    @ViewBuilder
    private var exchangeBlock: some View {
        let followUps = exchangeTickets
        let swaps = swapState.texts
        if sale.exchange != nil || !followUps.isEmpty || !swaps.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("換貨")
                if let x = sale.exchange {
                    OrdersLinkRow(icon: "arrows-right-left", text: "換貨單：抵原單 \(x.number) \(x.amount.formatted)", linkTitle: "看原單") {
                        openTicket(x.ticketId)
                    }
                }
                ForEach(followUps) { t in
                    OrdersLinkRow(icon: "arrows-right-left", text: t.isOpen ? "換貨中 →\(t.number)（還沒結帳）" : "已換貨 →\(t.number)", linkTitle: "看新單") {
                        openTicket(t.id)
                    }
                }
                ForEach(Array(swaps.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HeroIcon("arrows-up-down", size: 15)
                            .foregroundStyle(Theme.ink2)
                        Text("\(s)・換規格")
                            .font(.brand(14, .regular))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
    }

    // MARK: 發票

    private var invoiceBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("電子發票")
            if let s = stamp {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(s.display)
                        .strikethrough(isVoided)
                        .font(.brand(20, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isVoided ? Theme.muted : Theme.ink)
                    Text(s.buyer.summary)
                        .font(.brand(13.5, .regular))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    StatusBadge(isVoided ? "已作廢" : "已開立", tone: isVoided ? .danger : .active)
                }
                Text(invoiceDetail(s))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                if let v = voidInfo {
                    Text("作廢：\(v.reason)・\(v.at.shortText)")
                        .font(.brand(13.5, .medium))
                        .foregroundStyle(Theme.dangerFG)
                } else if isVoided, let r = s.voidReason {
                    Text("作廢：\(r)")
                        .font(.brand(13.5, .medium))
                        .foregroundStyle(Theme.dangerFG)
                }
            } else {
                Text(noInvoiceText)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noInvoiceText: String {
        if !invoiceEnabled { return "這家店沒有開電子發票。" }
        if sale.total.cents == 0 { return "金額是 0（課程卡抵、儲值金付清），不用開發票。" }
        return "這筆還沒開發票（結帳時號碼用完或斷網），可以從「⋯」補開。"
    }

    /// 「115年09-10月・隨機碼 1234・10/4 14:05 開立・不印證明聯」
    private func invoiceDetail(_ s: InvoiceStamp) -> String {
        var parts = [InvoicePeriod(code: s.period)?.label ?? s.period, "隨機碼 \(s.randomCode)", "\(s.issuedAt.shortText) 開立"]
        if !s.buyer.printsProof { parts.append("不印證明聯") }
        return parts.joined(separator: "・")
    }

    // MARK: 退款紀錄

    private var refundList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("退款・\(refunds.count) 筆")
            ForEach(refunds) { r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(r.tender.label)・\(r.reason)")
                            .font(.brand(15.5, .medium))
                            .foregroundStyle(Theme.ink)
                        Text(refundDetail(r))
                            .textRole(.xs)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    Text("−\(r.amount.formatted)")
                        .font(.brand(15.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(r.tender == .exchange ? Theme.ink2 : Theme.dangerFG)
                }
            }
        }
    }

    private func refundDetail(_ r: Refund) -> String {
        var parts = [r.at.shortText, model.staffName(r.by)]
        if let a = r.authorizedBy { parts.append("\(model.staffName(a)) 授權") }
        if !r.lines.isEmpty {
            let count = r.lines.reduce(0) { $0 + $1.quantity }
            parts.append("\(count) 件")
        }
        switch r.invoiceAction {
        case .void: parts.append("發票已作廢")
        case .allowance: parts.append("折讓單 \(r.allowanceNumber ?? "")")
        case .none: break
        }
        return parts.joined(separator: "・")
    }

    // MARK: 右欄：大鍵「補印收據」；動作鍵：換貨、補印證明聯、改統編／載具、補開發票、退款（紅字、最後）

    private var saleDock: DockSelection {
        let reprint = POSAction("補印收據", icon: "printer") {
            model.printReceipt(sale, reprint: true)
            model.show("已送出補印 \(sale.number)", tone: .neutral)
        }
        var actions: [POSAction] = []
        if canExchangeNow {
            actions.append(POSAction("換貨", icon: "arrows-right-left") { open(.exchange) })
        }
        if canReprintProof {
            actions.append(POSAction("補印證明聯", icon: "document-duplicate") {
                Task { await model.reprintInvoice(for: sale) }
            })
        }
        if canChangeBuyer {
            actions.append(POSAction("改統編／載具", icon: "pencil-square") { open(.buyer) })
        }
        if canIssueLate {
            actions.append(POSAction("補開發票", icon: "document-text") {
                Task { await model.issueLateInvoice(for: sale) }
            })
        }
        // 外帶結帳時叫號連不上：補拿號碼（印號碼牌、掛在單子上）
        if isEditable && model.canRetakeQueueNumber(sale) {
            actions.append(POSAction("補取號", icon: "ticket", enabled: !model.queueCooling(.take)) {
                Task { await model.retakeQueueNumber(for: sale) }
            })
        }
        // 退款：打開右欄的退款面板（送出前選方式、原因；要授權的在鍵盤問主管 PIN）
        if canRefund && refundable.cents > 0 {
            actions.append(POSAction("退款", icon: "receipt-refund", destructive: true) { open(.refund) })
        }
        var primary = reprint
        var accent = false
        if showCarrier {
            // 正在打手機條碼：大鍵變成「使用這個載具」，補印收據移到動作鍵
            primary = POSAction("使用這個載具", icon: "check", enabled: !carrier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                applyCarrier()
            }
            accent = true
            actions.insert(reprint, at: 0)
            actions.append(POSAction("不改載具", icon: "x-mark") {
                showCarrier = false
                carrier = ""
                carrierError = nil
            })
        }
        return DockSelection(
            id: "orders-sale-\(sale.ticketId)",
            kind: isEditable ? "交易" : "交易・後台的資料",
            title: "\(sale.number)・\(sale.ordersTitle)",
            detail: "\(sale.total.formatted)・\(sale.closedAt.dayText) \(sale.closedAt.clockText)・經手 \(sale.staffName)",
            badge: DockBadge(statusText, tone: statusTone),
            primary: primary,
            accent: accent,
            actions: actions,
            clear: { deselect() }
        )
    }

    /// 從右欄的動作鍵打開面板（一次一個；改載具的欄位收起來）
    private func open(_ f: OrdersDetailForm) {
        showCarrier = false
        carrierError = nil
        showAllTenders = false
        if f == .exchange { swapLineId = nil }
        form = f
    }

    // MARK: 改統編／載具（右欄的面板選種類；統編、愛心碼在鍵盤打；手機條碼在左邊打字或掃）

    private var buyerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            DockChoice(title: "統編", detail: "在鍵盤打 8 碼", selected: buyerKind == .business) {
                Task { await askTaxId() }
            }
            DockChoice(title: "手機條碼／自然人憑證", detail: "在左邊打或掃", selected: buyerKind == .carrier) {
                form = nil
                showCarrier = true
                carrierError = nil
            }
            DockChoice(title: "捐贈", detail: "在鍵盤打愛心碼", selected: buyerKind == .donation) {
                Task { await askLoveCode() }
            }
            DockChoice(title: "紙本", detail: "印證明聯", selected: buyerKind == .paper, enabled: buyerKind != .paper) {
                Task { await change(to: .paper) }
            }
        }
    }

    /// 手機條碼：文字欄位留在左邊（右欄的大鍵是「使用這個載具」）
    private var carrierCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("改成手機條碼／自然人憑證")
            TextField("/ABC+123（或自然人憑證）", text: $carrier)
                .font(.brand(17, .medium))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { applyCarrier() }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
            if let carrierError {
                Text(carrierError)
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.dangerFG)
            } else {
                Text("會作廢 \(stamp?.display ?? "原發票")、重開一張存到這個載具；打好按右邊的「使用這個載具」。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }

    private func applyCarrier() {
        let code = carrier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let buyer: InvoiceBuyer
        if InvoiceValidation.isMobileBarcode(code) {
            buyer = .consumer(carrier: .mobileBarcode(code))
        } else if InvoiceValidation.isCitizenCertificate(code) {
            buyer = .consumer(carrier: .citizenCertificate(code))
        } else {
            carrierError = "手機條碼是 / 開頭共 8 碼；自然人憑證是 2 碼英文＋14 碼數字"
            return
        }
        carrierError = nil
        Task { await change(to: buyer) }
    }

    private func askTaxId() async {
        var spec = KeypadSpec.taxId
        spec.subtitle = "\(sale.number)・作廢原發票後重開"
        if case .business(let id, _)? = stamp?.buyer { spec.initial = id }
        guard let e = await model.keypad.ask(spec) else { return }
        await change(to: .business(taxId: e.digits, title: nil))
    }

    private func askLoveCode() async {
        var spec = KeypadSpec.loveCode
        spec.subtitle = "\(sale.number)・作廢原發票後改捐贈"
        guard let e = await model.keypad.ask(spec) else { return }
        await change(to: .donation(loveCode: e.digits))
    }

    private func change(to buyer: InvoiceBuyer) async {
        let before = stamp?.number
        await model.changeBuyer(of: sale, to: buyer)
        // 號碼換了＝重開成功；不同期、取消授權時號碼不變，面板留著
        if stamp?.number != before {
            form = nil
            showCarrier = false
            carrier = ""
            carrierError = nil
        }
    }

    // MARK: 退款

    /// 可以選的退款方式：一般的付款方式；有會員時多一個「退回儲值金」。換貨抵用是自動的，不能手選
    private var allowedTenders: [Tender] {
        // 沒有錢櫃的崗位（前場）不能退現金
        var list = Tender.selectable.filter { $0 != .cash || model.role.hasDrawer }
        if sale.member?.id != nil { list.append(.prepaid) }
        return list
    }

    /// 先列這張單用過的付款方式（通常照原路退），有會員再加儲值金
    private var suggestedTenders: [Tender] {
        let allowed = allowedTenders
        var out: [Tender] = []
        for p in sale.payments where allowed.contains(p.tender) && !out.contains(p.tender) { out.append(p.tender) }
        if allowed.contains(.prepaid) && !out.contains(.prepaid) { out.append(.prepaid) }
        if out.isEmpty, let first = allowed.first { out.append(first) }
        return out
    }

    private var shownTenders: [Tender] {
        guard showAllTenders else { return suggestedTenders }
        let suggested = suggestedTenders
        return suggested + allowedTenders.filter { !suggested.contains($0) }
    }

    private var selectedTender: Tender { refundTender ?? suggestedTenders.first ?? .card }

    /// 右欄的退款面板：怎麼退、退哪些、退回哪裡、原因，最下面送出（金額照品項算；照金額退的在鍵盤打）
    private var refundPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                DockChoice(title: "照品項退", selected: currentRefundMode == .items) { refundMode = .items }
                DockChoice(title: "照金額退", selected: currentRefundMode == .amount) { refundMode = .amount }
            }
            if currentRefundMode == .items {
                refundItems
            }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("退回")
                ForEach(shownTenders, id: \.self) { t in
                    DockChoice(title: t.label, detail: t == .prepaid ? "存回會員的儲值金" : nil, selected: selectedTender == t) {
                        refundTender = t
                    }
                }
                if !showAllTenders && allowedTenders.count > suggestedTenders.count {
                    DockChoice(title: "其他方式…") { showAllTenders = true }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("原因")
                ForEach(OrdersRefundReason.allCases) { r in
                    DockChoice(title: r.rawValue, selected: refundReason == r) { refundReason = r }
                }
                if refundReason == .other {
                    TextField("說明（選填）", text: $otherReason)
                        .font(.brand(15.5, .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 1)
                        }
                }
            }
            if stamp != nil && !isVoided {
                Text("同一期整張退：發票作廢；部分退款或跨期：開折讓單（印在退款單上）。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canExchangeNow {
                Text("客人只是要換尺寸、換別件？用「換貨」，不用先退款。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            refundSubmit
        }
    }

    /// 送出：照品項＝直接退算好的金額；照金額＝下一步在鍵盤打。要授權的在鍵盤問主管 PIN（model.refund 裡）
    @ViewBuilder
    private var refundSubmit: some View {
        switch currentRefundMode {
        case .items:
            Button {
                Task { await runRefund(lines: effectiveRefundPicks.filter { $0.value > 0 }) }
            } label: {
                Text(itemRefundTotal.cents > 0 ? "退 \(itemRefundTotal.formatted)・\(selectedTender.label)" : "先選要退的品項")
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.danger, size: .lg, fullWidth: true))
            .disabled(itemRefundTotal.cents <= 0)
        case .amount:
            Button {
                Task { await runRefund(lines: [:]) }
            } label: {
                Text("下一步・在鍵盤打金額")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.danger, size: .lg, fullWidth: true))
        }
    }

    // MARK: 照品項退

    /// 服飾的商品、規格，課程卡、儲值：照品項退（庫存、次數、儲值金跟著退）；只有餐點的（餐廳）照金額
    private var defaultRefundMode: OrdersRefundMode {
        let itemised = sale.lines.contains { l in
            if l.variantName != nil || l.skuId != nil { return true }
            switch l.kind {
            case .some(.goods), .some(.pass), .some(.storedValue): return true
            case .some(.service), .none: return false
            }
        }
        return itemised ? .items : .amount
    }

    private var currentRefundMode: OrdersRefundMode { refundMode ?? defaultRefundMode }

    /// 每一行還能退幾件：商品照換貨的規則（扣掉退過、換過的）；其他是買的減掉退過的
    private var refundLimits: [String: Int] {
        let goods = model.returnableQuantities(sale)
        let already = sale.refundedQuantities(refunds)
        var out: [String: Int] = [:]
        for l in sale.lines {
            out[l.lineId] = goods[l.lineId] ?? max(l.quantity - (already[l.lineId] ?? 0), 0)
        }
        return out
    }

    /// 這次選的退完之後，收錢的品項每一件都退了（卡抵的這時才能一起取消、還回次數）
    private var completesPaidLines: Bool {
        let limits = refundLimits
        return sale.lines
            .filter { $0.redeem == nil }
            .allSatisfy { (refundPicked[$0.lineId] ?? 0) >= (limits[$0.lineId] ?? 0) }
    }

    /// 連卡抵的也選滿＝這張單全部退完：後台規則會把剩下的服務費、小費一起退
    private var completesSale: Bool {
        guard completesPaidLines, !effectiveRefundPicks.isEmpty else { return false }
        let limits = refundLimits
        return sale.lines.allSatisfy { (refundPicked[$0.lineId] ?? 0) >= (limits[$0.lineId] ?? 0) }
    }

    /// 真的要送出的：卡抵的只有收錢的都選滿時才算
    private var effectiveRefundPicks: [String: Int] {
        let paidDone = completesPaidLines
        var out: [String: Int] = [:]
        for l in sale.lines {
            guard let q = refundPicked[l.lineId], q > 0 else { continue }
            if l.redeem != nil && !paidDone { continue }
            out[l.lineId] = q
        }
        return out
    }

    /// 和送出去算的一樣：照原單實收；全部退完時是剩下能退的全部（含服務費、小費）
    private var itemRefundTotal: Money {
        if completesSale { return refundable }
        let already = sale.refundedQuantities(refunds)
        var sum = Money.zero
        for (lineId, q) in effectiveRefundPicks {
            sum += sale.refundAmount(lineId: lineId, quantity: q, alreadyRefunded: already[lineId] ?? 0)
        }
        return min(sum, refundable)
    }

    @ViewBuilder
    private var refundItems: some View {
        let limits = refundLimits
        let lines = sale.lines.filter { (limits[$0.lineId] ?? 0) > 0 }
        let paidDone = completesPaidLines
        let whole = completesSale
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("退哪些・點一下選；多件的在鍵盤打件數")
            if lines.isEmpty {
                Text("每一件都退過了；還有金額可以退的話用「照金額退」")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(lines, id: \.lineId) { l in
                    refundChoice(l, limit: limits[l.lineId] ?? 0, unlocked: paidDone)
                }
                HStack(spacing: 8) {
                    DockChoice(title: "全部選") { pickAll(limits) }
                    DockChoice(title: "清除", enabled: refundPicked.values.contains(where: { $0 > 0 })) { refundPicked = [:] }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(itemRefundTotal.cents > 0 ? "退 \(itemRefundTotal.formatted)" : "還沒選")
                        .font(.brand(16, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(itemRefundTotal.cents > 0 ? Theme.ink : Theme.muted)
                    if whole {
                        StatusBadge("全部退完", tone: .warning)
                    }
                }
                .padding(.top, 4)
                if whole && (sale.serviceCharge.cents > 0 || sale.tip.cents > 0) {
                    Text("全部退完：服務費、小費也一起退。")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// 一行：收錢的照原單實收；卡抵的不退錢，收錢的都選滿時才能一起取消（還回次數）。
    /// 只能退一件的點一下選／取消；多件的在鍵盤打件數
    private func refundChoice(_ l: SaleLine, limit: Int, unlocked: Bool) -> some View {
        let locked = l.redeem != nil && !unlocked
        let count = locked ? 0 : (refundPicked[l.lineId] ?? 0)
        let name = swapState.names[l.lineId].map { "\(l.name) \($0)" } ?? l.displayName
        return DockChoice(title: name, detail: refundRowDetail(l, limit: limit, count: count, locked: locked),
                          trailing: "\(count)／\(limit)", selected: count > 0, enabled: !locked) {
            if limit <= 1 {
                refundPicked[l.lineId] = count > 0 ? nil : 1
            } else {
                Task { await askRefundCount(l, limit: limit) }
            }
        }
    }

    private func refundRowDetail(_ l: SaleLine, limit: Int, count: Int, locked: Bool) -> String {
        if l.redeem != nil {
            return locked ? "卡抵的不退錢，取消會還回次數・其他品項選滿才能選" : "卡抵的不退錢，取消會還回次數"
        }
        let already = sale.refundedQuantities(refunds)[l.lineId] ?? 0
        let amount = sale.refundAmount(lineId: l.lineId, quantity: max(count, 1), alreadyRefunded: already)
        let each = count > 0 ? "退 \(amount.formatted)" : "一件約 \(amount.formatted)"
        var parts = ["可退 \(limit) 件", each]
        if let badge = OrdersItemRow.badge(for: l.kind) { parts.insert(badge, at: 0) }
        return parts.joined(separator: "・")
    }

    /// 「全部選」：每一行選滿（卡抵的也取消、還回次數）；這樣剩下的服務費、小費也一起退
    private func pickAll(_ limits: [String: Int]) {
        var picks: [String: Int] = [:]
        for l in sale.lines {
            let limit = limits[l.lineId] ?? 0
            if limit > 0 { picks[l.lineId] = limit }
        }
        refundPicked = picks
    }

    /// 件數多的時候在右側鍵盤打
    private func askRefundCount(_ l: SaleLine, limit: Int) async {
        let current = refundPicked[l.lineId] ?? 0
        let spec = KeypadSpec(kind: .count, title: "退幾件", subtitle: "\(l.displayName)・最多 \(limit) 件",
                              initial: current > 0 ? String(current) : "", confirmLabel: "好", maxValue: limit, minValue: 0)
        guard let n = await model.keypad.askNumber(spec) else { return }
        refundPicked[l.lineId] = min(n, limit)
    }

    /// lines 空的＝照金額退（右側鍵盤打金額）；有的話照品項算、不問金額
    private func runRefund(lines: [String: Int]) async {
        let reason: String
        switch refundReason {
        case .other:
            let text = otherReason.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = text.isEmpty ? OrdersRefundReason.other.rawValue : text
        case .cancelled, .quality, .mistake:
            reason = refundReason.rawValue
        }
        let before = refunds.count
        await model.refund(sale, tender: selectedTender, reason: reason, lines: lines)
        if refunds.count > before {
            form = nil
            otherReason = ""
            refundPicked = [:]
        }
    }

    // MARK: 換貨（右欄的面板：選要退回的件數、同款換規格；件數多的在鍵盤打）

    private var exchangeSubtitle: String {
        let deadline = model.store.exchangeDays > 0 ? "結帳 \(model.store.exchangeDays) 天內可以換・" : ""
        return "\(deadline)\(sale.number)"
    }

    @ViewBuilder
    private var exchangePanel: some View {
        let returnable = model.returnableQuantities(sale)
        let lines = sale.lines.filter { (returnable[$0.lineId] ?? 0) > 0 }
        if let id = swapLineId, let l = lines.first(where: { $0.lineId == id }), let item = l.itemId.flatMap({ model.catalog.item($0) }) {
            variantChoices(l, item: item, limit: returnable[l.lineId] ?? 0)
        } else if lines.isEmpty {
            Text("這張單沒有可以換的商品了（服務、課程卡、儲值不能換）")
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("退回哪些・點一下選；多件的在鍵盤打件數")
                    ForEach(lines, id: \.lineId) { l in
                        exchangeChoice(l, limit: returnable[l.lineId] ?? 0)
                    }
                }
                let swappable = lines.filter { l in l.itemId.flatMap { model.catalog.item($0) }?.hasVariants == true }
                if !swappable.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("同款同價換尺寸、顏色（當場換，不用結帳）")
                        ForEach(swappable, id: \.lineId) { l in
                            DockChoice(title: "換規格：\(l.name)", detail: "現在 \(swapState.names[l.lineId] ?? l.variantName ?? "原規格")") {
                                swapLineId = l.lineId
                            }
                        }
                    }
                }
                exchangeFooter
            }
        }
    }

    private func exchangeChoice(_ l: SaleLine, limit: Int) -> some View {
        let count = exchangePicked[l.lineId] ?? 0
        let variant = swapState.names[l.lineId] ?? l.variantName
        return DockChoice(title: variant.map { "\(l.name) \($0)" } ?? l.name,
                          detail: "買 \(l.quantity) 件・可換 \(limit) 件・每件 \(l.unitPrice.formatted)",
                          trailing: "\(count)／\(limit)", selected: count > 0) {
            if limit <= 1 {
                exchangePicked[l.lineId] = count > 0 ? nil : 1
            } else {
                Task { await askExchangeCount(l, limit: limit) }
            }
        }
    }

    /// 新的比較貴補差額、比較便宜退現金，都在結帳時算
    private var exchangeFooter: some View {
        let count = exchangePicked.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            Text(count > 0 ? "退回 \(count) 件，抵 \(exchangeCredit.formatted)（照原單實收）" : "還沒選要退回的件數")
                .font(.brand(14.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Theme.ink : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("新的比較貴補差額、比較便宜退現金，都在結帳時算。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                startExchange()
            } label: {
                Text("換別的商品・到點餐加新的")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
            .disabled(count == 0)
        }
    }

    /// 同款換規格：每個規格一列；價格不同、停售、沒貨、現在這個都按不了
    private func variantChoices(_ l: SaleLine, item: MenuItem, limit: Int) -> some View {
        let current = swapState.skus[l.lineId] ?? l.skuId
        let qty = min(max(exchangePicked[l.lineId] ?? 0, 1), limit)
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow("\(l.name)・換成哪個規格（\(qty) 件）")
            ForEach(item.activeVariants) { v in
                let state = OrdersSwapAvailability(item: item, variant: v, unitPrice: l.unitPrice, currentSkuId: current)
                DockChoice(title: v.label, detail: state.detail, selected: v.id == current, enabled: state.enabled) {
                    swap(l, to: v, limit: limit)
                }
            }
            DockChoice(title: "回到換貨") { swapLineId = nil }
            Text("價格不同的請用「換別的商品」補差價。件數照上一頁選的（沒選就是 1 件）。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 退回的這些值多少（和換貨單結帳時算的一樣：照原單實收、扣掉已經退過的）
    private var exchangeCredit: Money {
        let already = sale.refundedQuantities(refunds)
        var sum = Money.zero
        for (lineId, q) in exchangePicked where q > 0 {
            sum += sale.refundAmount(lineId: lineId, quantity: q, alreadyRefunded: already[lineId] ?? 0)
        }
        return sum
    }

    private func askExchangeCount(_ l: SaleLine, limit: Int) async {
        let current = exchangePicked[l.lineId] ?? 0
        let spec = KeypadSpec(kind: .count, title: "退回幾件", subtitle: "\(l.displayName)・最多 \(limit) 件",
                              initial: current > 0 ? String(current) : "", confirmLabel: "好", maxValue: limit, minValue: 0)
        guard let n = await model.keypad.askNumber(spec) else { return }
        exchangePicked[l.lineId] = n > 0 ? min(n, limit) : nil
    }

    private func swap(_ l: SaleLine, to v: ItemVariant, limit: Int) {
        let qty = min(max(exchangePicked[l.lineId] ?? 0, 1), limit)
        model.swapVariant(in: sale, lineId: l.lineId, quantity: qty, to: v, reason: "換規格")
        exchangePicked[l.lineId] = nil
        swapLineId = nil
    }

    private func startExchange() {
        let returning = exchangePicked.filter { $0.value > 0 }
        guard !returning.isEmpty else { return }
        form = nil
        model.startExchange(from: sale, returning: returning)
    }
}

/// 同款換規格：這個規格能不能換、旁邊的小字
private struct OrdersSwapAvailability {
    let enabled: Bool
    let detail: String

    init(item: MenuItem, variant v: ItemVariant, unitPrice: Money, currentSkuId: String?) {
        var ok = false
        var text = "可換"
        if v.id == currentSkuId {
            text = "現在這個"
        } else if !v.isAvailable {
            text = "停售"
        } else if item.price(of: v) != unitPrice {
            text = "價格不同 \(item.price(of: v).short)"
        } else if let stock = v.stock {
            ok = stock > 0
            text = stock > 0 ? "剩 \(stock)" : "沒貨"
        } else {
            ok = true
        }
        enabled = ok
        detail = text
    }
}

// MARK: - 衝突

/// 一則衝突：整條點一下選起來（橘框），右欄大鍵「已處理」、動作「看單」；再點一下取消
private struct OrdersConflictRow: View {
    let conflict: Conflict
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                HeroIcon("exclamation-triangle", size: 18)
                    .foregroundStyle(Theme.dangerFG)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.message)
                        .font(.brand(14.5, .medium))
                        .foregroundStyle(Theme.dangerFG)
                        .lineLimit(2)
                    Text("\(conflict.ordersKindLabel)・\(conflict.at.shortText)")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tone.danger.background, in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Conflict {
    /// 「兩台都結帳」「結帳後又收款」…
    fileprivate var ordersKindLabel: String {
        switch kind {
        case .doubleClose: "兩台都結帳"
        case .paymentAfterClose: "結帳後又收款"
        case .linesAfterClose: "結帳後又加點"
        case .duplicateInvoice: "發票號碼重複"
        }
    }
}

// MARK: - 小工具

extension StoreState {
    /// 還沒處理、這個畫面也還沒按「已處理」的衝突（最新的在上面）。只在畫面上藏起來，不記任何事件
    fileprivate func visibleConflicts(hiding dismissed: Set<String>) -> [Conflict] {
        unresolvedConflicts
            .filter { !dismissed.contains($0.id) }
            .sorted { $0.at > $1.at }
    }
}

extension Ticket {
    /// 搜尋進行中的單：單號、桌號／客人、金額
    fileprivate func ordersMatches(_ raw: String, floor: FloorPlan) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return true }
        if number.uppercased().contains(q) || title(floor: floor).uppercased().contains(q) { return true }
        let digits = q.filter(\.isNumber)
        return !digits.isEmpty && digits.count == q.count && String(totals.total.dollars).hasPrefix(digits)
    }
}

extension SaleRecord {
    /// 「A1+A2」「外帶 王先生」「外帶」；服飾、美業、課程沒有內用外帶：「王小美」「現場客人」
    fileprivate var ordersTitle: String {
        if orderType == .dineIn && !tableNames.isEmpty { return tableNames }
        if serviceMode?.showsOrderType == false {
            if let name = customerName, !name.isEmpty { return name }
            if let m = member { return m.name ?? m.maskedPhone }
            return "現場客人"
        }
        if let name = customerName, !name.isEmpty { return "\(orderType.label) \(name)" }
        if let q = queueNumber { return "\(orderType.label) \(q) 號" }
        return orderType.label
    }

    /// 用了哪些付款方式（照收款順序、不重複）
    fileprivate var ordersTenders: [Tender] {
        var out: [Tender] = []
        for p in payments where !out.contains(p.tender) { out.append(p.tender) }
        return out
    }

    /// 搜尋：單號、桌號、客人、會員、經手人、品項規格、發票號碼（AB-12345678 打不打橫線都行）、金額（數字從頭比）
    fileprivate func ordersMatches(_ raw: String, invoiceNumber: String?) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "")
        guard !q.isEmpty else { return true }
        if number.uppercased().contains(q) || tableNames.uppercased().contains(q) { return true }
        if let name = customerName, name.uppercased().contains(q) { return true }
        if let m = member, (m.name ?? "").uppercased().contains(q) || (q.count >= 3 && m.phone.hasSuffix(q)) { return true }
        if staffName.uppercased().contains(q) { return true }
        if let inv = invoiceNumber, inv.uppercased().contains(q) { return true }
        if lines.contains(where: { $0.displayName.uppercased().contains(q) }) { return true }
        let digits = q.filter(\.isNumber)
        return !digits.isEmpty && digits.count == q.count && String(total.dollars).hasPrefix(digits)
    }
}
