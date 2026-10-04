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
///   │ ┌─────────┐  │ ┌──────────────┐  │              │             │
///   │ │A5   A021│  │ │A2 4位・34分 ●●○│  │              │             │
///   │ │[點餐][結帳]│ │ │[點餐][結帳 →] │  │              │             │
///   └──────────────────────────────────────────────────────────────┘
///
/// 全部（左邊清單、右邊明細）
///   ┌ [搜尋……][⌨]   ┬───────────────────────────────────────────┐
///   │ 今天・10月4日   │ NT$ 1,320                                 │
///   │▌NT$1,320 14:05 │ 已付款・經手 Cameron W.                    │
///   │ A2・4 位 已結帳 │ [林小涵 金卡會員]                          │
///   │  NT$260  13:40 │ 品項…  小計／折扣／服務費／總計             │
///   │ 外帶     已退款 │ 現金 NT$1,320・發票 XD-12345601            │
///   │ 昨天・10月3日   │ [   補印收據   ][    退款    ][…]           │
///   └────────────────┴───────────────────────────────────────────┘
///
/// 明細不用系統的 sheet：sheet 會蓋住右側鍵盤，而退款金額、統編、愛心碼、主管 PIN 都要在鍵盤上打，
/// 所以明細、退款、改統編都在工作區裡，鍵盤一直按得到。
struct OrdersView: View {
    @Environment(POSModel.self) private var model

    @State private var tab: OrdersTab = .open
    @State private var query = ""
    /// 「全部」選中的那一張（ticketId）。寬的時候沒選就看最新的一張；窄的時候沒選就不開明細
    @State private var selectedId: String?
    /// 按了「已處理」的衝突：只在這個畫面藏起來、不記事件（不發明新的事件種類；真正結案在後台）
    @State private var dismissedConflicts: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            conflictList
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        entries.filter { $0.businessDate == model.businessDate }.count
    }

    private func select(tab t: OrdersTab) {
        // 「全部」要左右兩欄的寬度：收起右邊的單子欄
        if t == .all && model.checkoutTicketId == nil { model.selectedTicketId = nil }
        selectedId = nil
        withAnimation(Motion.fast) { tab = t }
    }

    // MARK: - 衝突（兩台斷線各做各的）

    @ViewBuilder
    private var conflictList: some View {
        let list = model.state.visibleConflicts(hiding: dismissedConflicts)
        if !list.isEmpty {
            VStack(spacing: 8) {
                ForEach(list) { c in
                    OrdersConflictRow(
                        conflict: c,
                        canOpen: canOpen(c),
                        open: { open(c) },
                        dismiss: { _ = dismissedConflicts.insert(c.id) }
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }

    private func canOpen(_ c: Conflict) -> Bool {
        guard let id = c.ticketId else { return false }
        return model.state.sales[id] != nil || model.state.tickets[id]?.isOpen == true
    }

    private func open(_ c: Conflict) {
        guard let id = c.ticketId else { return }
        if model.state.sales[id] != nil {
            select(tab: .all)
            selectedId = id
        } else if model.state.tickets[id]?.isOpen == true {
            select(tab: .open)
            model.selectedTicketId = id
        }
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

    @ViewBuilder
    private var board: some View {
        let openTickets = model.state.openTickets
        if openTickets.isEmpty {
            EmptyState(icon: "queue-list", title: "沒有進行中的單", message: "從「點餐」或「桌位」開單，就會出現在這裡")
        } else {
            let kitchen = model.features.kitchen
            GeometryReader { geo in
                // 一欄至少 264 寬；工作區夠寬就四欄排滿，不夠就左右滑
                let width = max(264, (geo.size.width - 56 - 48) / 4)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(OrdersLane.allCases) { lane in
                            OrdersLaneColumn(lane: lane, tickets: openTickets.filter { OrdersLane.of($0, kitchen: kitchen) == lane })
                                .frame(width: width)
                        }
                    }
                    .padding(.horizontal, 28)
                    .frame(height: geo.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: 全部：清單＋明細

    /// 進行中的排最上面，其他照結帳時間新到舊
    private var entries: [OrdersEntry] {
        let openEntries = model.state.openTickets.map { OrdersEntry.open($0) }
        let closedEntries = model.state.closedSales().map { OrdersEntry.closed($0) }
        return (openEntries + closedEntries).sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            return a.sortDate > b.sortDate
        }
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

    private func current(in list: [OrdersEntry], autoSelect: Bool) -> OrdersEntry? {
        if let id = selectedId, let e = list.first(where: { $0.id == id }) { return e }
        return autoSelect ? list.first : nil
    }

    @ViewBuilder
    private var masterDetail: some View {
        let list = filtered(entries)
        GeometryReader { geo in
            if geo.size.width >= 680 {
                HStack(spacing: 0) {
                    master(list, currentId: current(in: list, autoSelect: true)?.id)
                        .frame(width: min(340, max(300, geo.size.width * 0.36)))
                    Rule(vertical: true)
                    detailPane(current(in: list, autoSelect: true), close: nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.surface)
                }
                .overlay(alignment: .top) { Rule() }
            } else {
                // 直的 iPad：清單滿版，明細從右邊滑進來
                ZStack(alignment: .trailing) {
                    master(list, currentId: selectedId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let e = current(in: list, autoSelect: false) {
                        Color.black.opacity(0.22)
                            .contentShape(.rect)
                            .onTapGesture { selectedId = nil }
                            .transition(.opacity)
                        detailPane(e, close: { selectedId = nil })
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
    }

    /// 左邊的清單；currentId＝右邊正在看的那一張（標橘色邊）
    private func master(_ list: [OrdersEntry], currentId: String?) -> some View {
        let days = OrdersDay.group(list)
        return VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Rule(color: Theme.hair)
            if entries.isEmpty {
                EmptyState(icon: "receipt-refund", title: "還沒有單", message: "開單、結帳之後會出現在這裡")
            } else if list.isEmpty {
                EmptyState(icon: "magnifying-glass", title: "找不到「\(query)」", message: "可以搜單號、桌號、發票號碼或金額")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.entries) { e in
                                    Button {
                                        selectedId = e.id
                                        model.touch()
                                    } label: {
                                        OrdersEntryRow(entry: e, selected: e.id == currentId)
                                    }
                                    .buttonStyle(.row)
                                    Rule(color: Theme.hair)
                                }
                            } header: {
                                OrdersDayHeader(title: dayTitle(day.date), day: day)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Theme.page)
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
    private func detailPane(_ entry: OrdersEntry?, close: (() -> Void)?) -> some View {
        switch entry {
        case .none:
            EmptyState(icon: "queue-list", title: "選一張單", message: "左邊點一下，明細出現在這裡")
        case .some(.open(let t)):
            OrdersOpenDetail(ticket: t, close: close)
                .id(t.id)
        case .some(.closed(let s)):
            OrdersSaleDetail(sale: s, close: close)
                .id(s.ticketId)
        }
    }

    /// 「今天・10月4日」「昨天・10月3日」「10月1日・星期四」
    private func dayTitle(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return date }
        let md = "\(parts[1])月\(parts[2])日"
        if date == model.businessDate { return "今天・\(md)" }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = 12
        let cal = TaipeiTime.calendar
        guard let noon = cal.date(from: c) else { return md }
        if let next = cal.date(byAdding: .day, value: 1, to: noon), TaipeiTime.dayString(next) == model.businessDate {
            return "昨天・\(md)"
        }
        return "\(md)・\(noon.weekdayText)"
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

    var title: String {
        switch self {
        case .ordering: "點餐中"
        case .cooking: "出餐中"
        case .dining: "用餐中"
        case .billing: "待結帳"
        }
    }

    var emptyText: String {
        switch self {
        case .ordering: "沒有在點餐的"
        case .cooking: "廚房沒有在做的"
        case .dining: "沒有用餐中的"
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
        // 沒開廚房功能：品項不會有「已送單」，點了就算用餐中
        guard kitchen else { return .dining }
        if lines.contains(where: { $0.kitchen == .new }) { return .ordering }
        if lines.contains(where: { $0.kitchen != .served }) { return .cooking }
        return .dining
    }
}

private struct OrdersLaneColumn: View {
    let lane: OrdersLane
    let tickets: [Ticket]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Rule()
            if tickets.isEmpty {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 88)
                    .overlay {
                        Text(lane.emptyText)
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
            Text(lane.title)
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

/// 看板上的一張單：點一下＝選起來（右邊出現單子）；兩個按鈕直接去點餐、結帳
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
            if model.device.role != .kitchen {
                actionRow
            }
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
        HStack(spacing: 10) {
            TimelineView(.everyMinute) { context in
                OrdersElapsed(minutes: minutes(at: context.date), limit: timeLimit)
            }
            if ticket.guests > 0 {
                metaText("\(ticket.guests) 位")
            }
            metaText("\(ticket.itemCount) 項")
            Spacer(minLength: 4)
            if model.features.kitchen && !ticket.activeLines.isEmpty {
                OrdersKitchenDots(lines: ticket.activeLines)
            }
        }
    }

    private func metaText(_ s: String) -> some View {
        Text(s)
            .font(.brand(13, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
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
                StatusBadge("已印結帳單", tone: .warning)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                model.selectedTicketId = ticket.id
                model.go(.order)
            } label: {
                Text("點餐")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.ghost, size: .sm, fullWidth: true))

            Button {
                model.beginCheckout(ticket)
            } label: {
                Text("結帳")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.primary, size: .sm, fullWidth: true, arrow: true))
            .disabled(ticket.activeLines.isEmpty)
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
        }
        .font(.brand(13, .medium))
        .foregroundStyle(color)
    }

    private var text: String {
        minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 時 \(minutes % 60) 分"
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

    var isOpen: Bool {
        switch self {
        case .open: true
        case .closed: false
        }
    }

    var businessDate: String {
        switch self {
        case .open(let t): t.businessDate
        case .closed(let s): s.businessDate
        }
    }

    var sortDate: Date {
        switch self {
        case .open(let t): t.openedAt
        case .closed(let s): s.closedAt
        }
    }
}

/// 同一個營業日的那一段（日期標題＋那天的單）
private struct OrdersDay: Identifiable {
    let date: String
    let entries: [OrdersEntry]

    var id: String { date }

    /// 照營業日分段（新的日期在上面；段內保持原本的順序）
    static func group(_ list: [OrdersEntry]) -> [OrdersDay] {
        var order: [String] = []
        var map: [String: [OrdersEntry]] = [:]
        for e in list {
            if map[e.businessDate] == nil { order.append(e.businessDate) }
            map[e.businessDate, default: []].append(e)
        }
        return order.sorted(by: >).map { OrdersDay(date: $0, entries: map[$0] ?? []) }
    }
}

private struct OrdersDayHeader: View {
    let title: String
    let day: OrdersDay

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.brand(13, .semibold))
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            Text(summary)
                .font(.brand(12.5, .regular))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.page)
    }

    /// 「12 張・已結 $8,640」
    private var summary: String {
        var closed = Money.zero
        for e in day.entries {
            if case .closed(let s) = e { closed += s.total }
        }
        return "\(day.entries.count) 張・已結 \(closed.short)"
    }
}

private struct OrdersEntryRow: View {
    @Environment(POSModel.self) private var model
    let entry: OrdersEntry
    let selected: Bool

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

    /// 「A2・4 位」「外帶」
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
        case .open:
            return ("進行中", Theme.accentText)
        case .closed(let s):
            let refunded = model.state.tickets[s.ticketId]?.refundedAmount ?? .zero
            if refunded.cents > 0 {
                return (refunded >= s.total + s.tip ? "已退款" : "部分退款", Theme.muted)
            }
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
            TextField("單號、桌號、發票、金額", text: $text)
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

/// 一個品項：名字 ×數量、加料、金額（有折扣時原價劃掉）
private struct OrdersItemRow: View {
    let name: String
    let quantity: Int
    let modifiers: String
    let amount: Money
    let original: Money

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
                }
                if !modifiers.isEmpty {
                    Text(modifiers)
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 12)
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
        }
        if let ref = payment.reference, !ref.isEmpty { parts.append("序號 \(ref)") }
        return parts.joined(separator: "・")
    }
}

/// 明細最下面那一條（按鈕、展開的退款／改統編表單）
private struct OrdersDetailBottomBar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rule() }
    }
}

// MARK: - 明細：進行中的單

private struct OrdersOpenDetail: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket
    let close: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                OrdersDetailTopBar(title: "進行中的單", close: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    OrdersDetailHero(amount: ticket.totals.total, status: "進行中", tone: .gold,
                                     byline: "開單 \(model.staffName(ticket.openedBy))", detail: heroDetail)
                    if let c = OrdersCustomerCard.info(member: ticket.member, customerName: ticket.customerName) {
                        OrdersCustomerCard(name: c.name, detail: c.detail)
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
            if model.device.role != .kitchen {
                OrdersDetailBottomBar {
                    HStack(spacing: 10) {
                        Button {
                            model.selectedTicketId = ticket.id
                            model.go(.order)
                        } label: {
                            Text("點餐")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))

                        Button {
                            model.beginCheckout(ticket)
                        } label: {
                            Text("結帳")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.brand(.primary, size: .lg, fullWidth: true, arrow: true))
                        .disabled(ticket.activeLines.isEmpty)
                    }
                }
            }
        }
    }

    private var heroDetail: String {
        var parts = [ticket.number, ticket.title(floor: model.floor)]
        if ticket.guests > 0 { parts.append("\(ticket.guests) 位") }
        parts.append("\(ticket.openedAt.clockText) 開單")
        return parts.joined(separator: "・")
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
                OrdersItemRow(name: l.name, quantity: l.quantity, modifiers: l.modifierText,
                              amount: l.gross - l.lineDiscount, original: l.gross)
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
            if t.paid.cents > 0 {
                ValueRow(label: "已收", value: t.paid.formatted, tone: Theme.successFG)
                ValueRow(label: "還要收", value: t.balance.formatted, strong: true)
            }
        }
    }
}

// MARK: - 明細：已結帳的那一筆

private enum OrdersDetailForm: Equatable {
    case buyer, refund
}

private enum OrdersRefundReason: String, CaseIterable, Identifiable {
    case cancelled = "客人取消"
    case quality = "餐點問題"
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

private struct OrdersSaleDetail: View {
    @Environment(POSModel.self) private var model
    let sale: SaleRecord
    let close: (() -> Void)?

    @State private var form: OrdersDetailForm?
    @State private var showCarrier = false
    @State private var carrier = ""
    @State private var carrierError: String?
    @State private var refundTender: Tender?
    @State private var refundReason: OrdersRefundReason = .cancelled
    @State private var otherReason = ""

    // 讀最新的：結帳後改統編、補開、退款都記在 tickets 上（sales 只存結帳那一刻）
    private var ticket: Ticket? { model.state.tickets[sale.ticketId] }
    private var stamp: InvoiceStamp? { ticket?.invoice ?? sale.invoice }
    private var invoice: EInvoice? { stamp.flatMap { model.state.invoices[$0.number] } }
    private var voidInfo: VoidInfo? { stamp.flatMap { model.state.voidedInvoices[$0.number] } }
    private var isVoided: Bool { stamp?.isVoided == true || voidInfo != nil }
    private var refunds: [Refund] { ticket?.refunds ?? [] }
    private var refunded: Money { ticket?.refundedAmount ?? .zero }
    private var refundable: Money { sale.total + sale.tip - refunded }
    private var invoiceEnabled: Bool { model.features.invoice && model.invoiceSettings.enabled }
    private var buyerKind: OrdersBuyerKind { OrdersBuyerKind(stamp?.buyer) }
    private var itemCount: Int { sale.lines.reduce(0) { $0 + $1.quantity } }

    /// 存載具、捐贈的發票不印證明聯，也就不能「補印」
    private var canReprintProof: Bool {
        guard let s = stamp, !isVoided else { return false }
        return invoice?.printed ?? s.buyer.printsProof
    }

    private var canChangeBuyer: Bool { stamp != nil && !isVoided }

    private var canIssueLate: Bool {
        stamp == nil && invoiceEnabled && sale.total.cents > 0 && refunds.isEmpty
    }

    private var hasMoreActions: Bool { canReprintProof || canChangeBuyer || canIssueLate }

    private var tenders: [Tender] {
        let list = sale.ordersTenders
        return list.isEmpty ? [.cash] : list
    }

    private var selectedTender: Tender { refundTender ?? tenders.first ?? .cash }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                OrdersDetailTopBar(title: "交易明細", close: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    OrdersDetailHero(amount: sale.total, status: statusText, tone: statusTone,
                                     byline: "經手 \(sale.staffName)", detail: heroDetail)
                    if let c = OrdersCustomerCard.info(member: sale.member, customerName: sale.customerName) {
                        OrdersCustomerCard(name: c.name, detail: c.detail)
                    }
                    lineList
                    totalsBlock
                    paymentsBlock
                    invoiceBlock
                    if !refunds.isEmpty {
                        refundList
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
    }

    // MARK: 上面

    private var statusText: String {
        if refunded.cents > 0 { return refundable.cents <= 0 ? "已退款" : "部分退款 \(refunded.formatted)" }
        return "已付款"
    }

    private var statusTone: Tone {
        if refunded.cents > 0 { return refundable.cents <= 0 ? .danger : .warning }
        return .active
    }

    private var heroDetail: String {
        var parts = [sale.number, sale.ordersTitle]
        if sale.guests > 0 { parts.append("\(sale.guests) 位") }
        parts.append("\(sale.closedAt.dayText) \(sale.closedAt.clockText)")
        return parts.joined(separator: "・")
    }

    // MARK: 品項、金額、付款

    private var lineList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("品項・\(itemCount) 項")
            ForEach(sale.lines, id: \.lineId) { l in
                OrdersItemRow(name: l.name, quantity: l.quantity, modifiers: l.modifiers, amount: l.net, original: l.gross)
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
                Text("沒有收款紀錄")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(sale.payments) { p in
                OrdersPaymentRow(payment: p)
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
                Text(invoiceEnabled ? "這筆還沒開發票（結帳時號碼用完或斷網），可以從「…」補開。" : "這家店沒有開電子發票。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                        .foregroundStyle(Theme.dangerFG)
                }
            }
        }
    }

    private func refundDetail(_ r: Refund) -> String {
        var parts = [r.at.shortText, model.staffName(r.by)]
        if let a = r.authorizedBy { parts.append("\(model.staffName(a)) 授權") }
        switch r.invoiceAction {
        case .void: parts.append("發票已作廢")
        case .allowance: parts.append("折讓單 \(r.allowanceNumber ?? "")")
        case .none: break
        }
        return parts.joined(separator: "・")
    }

    // MARK: 下面：補印收據、退款、「…」

    private var bottomBar: some View {
        OrdersDetailBottomBar {
            if form == .buyer {
                buyerForm
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if form == .refund {
                refundForm
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 10) {
                Button {
                    model.printReceipt(sale, reprint: true)
                    model.show("已送出補印 \(sale.number)", tone: .neutral)
                } label: {
                    actionLabel("補印收據", icon: "printer")
                }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))

                Button {
                    toggle(.refund)
                } label: {
                    actionLabel(refundable.cents > 0 ? "退款" : "已全部退款", icon: "receipt-refund")
                }
                .buttonStyle(.brand(form == .refund ? .primary : .danger, size: .lg, fullWidth: true))
                .disabled(refundable.cents <= 0)

                if hasMoreActions {
                    moreMenu
                }
            }
        }
        .animation(Motion.fast, value: form)
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            HeroIcon(icon, size: 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// 少用的動作收在「…」：補印證明聯、改統編／載具、補開發票
    private var moreMenu: some View {
        Menu {
            if canReprintProof {
                Button("補印證明聯") {
                    Task { await model.reprintInvoice(for: sale) }
                }
            }
            if canChangeBuyer {
                Button("改統編／載具") {
                    toggle(.buyer)
                }
            }
            if canIssueLate {
                Button("補開發票") {
                    Task { await model.issueLateInvoice(for: sale) }
                }
            }
        } label: {
            HeroIcon("ellipsis-horizontal", size: 20)
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
                .contentShape(.rect)
        }
        .tint(Theme.ink)
        .accessibilityLabel("更多動作")
    }

    private func toggle(_ f: OrdersDetailForm) {
        form = form == f ? nil : f
        showCarrier = false
        carrierError = nil
    }

    // MARK: 改統編／載具

    private var buyerForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("改統編／載具")
                Spacer(minLength: 8)
                Button("收起") { toggle(.buyer) }
                    .buttonStyle(.brand(.quiet, size: .sm))
            }
            Text("會作廢 \(stamp?.display ?? "原發票")、用同一筆交易重開一張（同一期才行，要店長授權）。")
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("統編") {
                    Task { await askTaxId() }
                }
                .buttonStyle(.choice(buyerKind == .business, height: 48))

                Button("手機條碼") {
                    showCarrier.toggle()
                    carrierError = nil
                }
                .buttonStyle(.choice(showCarrier || buyerKind == .carrier, height: 48))

                Button("捐贈") {
                    Task { await askLoveCode() }
                }
                .buttonStyle(.choice(buyerKind == .donation, height: 48))

                Button("紙本") {
                    Task { await change(to: .paper) }
                }
                .buttonStyle(.choice(buyerKind == .paper, height: 48))
                .disabled(buyerKind == .paper)
            }
            if showCarrier {
                carrierField
            }
            Text("統編、愛心碼在右側鍵盤打；手機條碼可以掃或手打。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }

    private var carrierField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
                Button("使用") { applyCarrier() }
                    .buttonStyle(.brand(.primary, size: .md))
                    .disabled(carrier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let carrierError {
                Text(carrierError)
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.dangerFG)
            }
        }
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
        // 號碼換了＝重開成功；不同期、取消授權時號碼不變，表單留著
        if stamp?.number != before {
            form = nil
            showCarrier = false
            carrier = ""
        }
    }

    // MARK: 退款

    private var refundForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("退款")
                Spacer(minLength: 8)
                Text("最多可退 \(refundable.formatted)")
                    .font(.brand(14, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("退回")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, alignment: .leading)
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(tenders, id: \.self) { t in
                        OptionChip(title: t.label, selected: selectedTender == t) { refundTender = t }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("原因")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, alignment: .leading)
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(OrdersRefundReason.allCases) { r in
                        OptionChip(title: r.rawValue, selected: refundReason == r) { refundReason = r }
                    }
                }
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
            if stamp != nil && !isVoided {
                Text("同一期整張退：發票作廢；部分退款或跨期：開折讓單（印在退款單上）。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await runRefund() }
            } label: {
                Text("下一步・在右側鍵盤打金額")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.danger, size: .md, fullWidth: true, arrow: true))
        }
        .padding(18)
        .background(Theme.press, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
    }

    private func runRefund() async {
        let reason: String
        switch refundReason {
        case .other:
            let text = otherReason.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = text.isEmpty ? OrdersRefundReason.other.rawValue : text
        case .cancelled, .quality, .mistake:
            reason = refundReason.rawValue
        }
        let before = refunds.count
        await model.refund(sale, tender: selectedTender, reason: reason)
        if refunds.count > before {
            form = nil
            otherReason = ""
        }
    }
}

// MARK: - 衝突

private struct OrdersConflictRow: View {
    let conflict: Conflict
    let canOpen: Bool
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HeroIcon("exclamation-triangle", size: 18)
                .foregroundStyle(Theme.dangerFG)
            VStack(alignment: .leading, spacing: 2) {
                Text(conflict.message)
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(Theme.dangerFG)
                    .lineLimit(2)
                Text("\(kindLabel)・\(conflict.at.shortText)")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            if canOpen {
                Button("看單", action: open)
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
            Button("已處理", action: dismiss)
                .buttonStyle(.brand(.primary, size: .sm))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tone.danger.background, in: .rect(cornerRadius: Metric.radius, style: .continuous))
    }

    private var kindLabel: String {
        switch conflict.kind {
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
    /// 搜尋進行中的單：單號、桌號／稱呼、金額
    fileprivate func ordersMatches(_ raw: String, floor: FloorPlan) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return true }
        if number.uppercased().contains(q) || title(floor: floor).uppercased().contains(q) { return true }
        let digits = q.filter(\.isNumber)
        return !digits.isEmpty && digits.count == q.count && String(totals.total.dollars).hasPrefix(digits)
    }
}

extension SaleRecord {
    /// 「A1+A2」「外帶 王先生」「外帶」
    fileprivate var ordersTitle: String {
        if orderType == .dineIn && !tableNames.isEmpty { return tableNames }
        if let name = customerName, !name.isEmpty { return "\(orderType.label) \(name)" }
        return orderType.label
    }

    /// 用了哪些付款方式（照收款順序、不重複）
    fileprivate var ordersTenders: [Tender] {
        var out: [Tender] = []
        for p in payments where !out.contains(p.tender) { out.append(p.tender) }
        return out
    }

    /// 搜尋：單號、桌號、稱呼、經手人、發票號碼（AB-12345678 打不打橫線都行）、金額（數字從頭比）
    fileprivate func ordersMatches(_ raw: String, invoiceNumber: String?) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "")
        guard !q.isEmpty else { return true }
        if number.uppercased().contains(q) || tableNames.uppercased().contains(q) { return true }
        if let name = customerName, name.uppercased().contains(q) { return true }
        if staffName.uppercased().contains(q) { return true }
        if let inv = invoiceNumber, inv.uppercased().contains(q) { return true }
        let digits = q.filter(\.isNumber)
        return !digits.isEmpty && digits.count == q.count && String(total.dollars).hasPrefix(digits)
    }
}
