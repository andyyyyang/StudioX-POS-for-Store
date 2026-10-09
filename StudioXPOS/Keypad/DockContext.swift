import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側鍵盤上面的那一塊：跟著現在在做的事變。鍵位永遠固定在下面，這裡放「這一刻最需要的資訊」。
///
///   正在打數字：收現金 → 即時的找零／還差；查會員 → 打幾碼就列出熟客（點一下帶入）；統編 → 今天用過的
///   待機：桌位 → 桌況與超時、下一組訂位；預約 → 接下來的；報到 → 今天的人次、下一堂課；廚房 → 待做與最久的；
///         訂單 → 待結帳；交班 → 錢櫃應有；店長以上看得到今天的營業額。
///         點餐頁是空的：品項在左邊、單子在中間，右欄只放這張單的動作（和叫號）
struct DockContext: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad

    var body: some View {
        Group {
            if model.phase != .ready {
                Color.clear
            } else if let r = keypad.request {
                asking(r)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if model.section != .order, model.currentStaff?.can(.viewReports) == true { DockToday() }
                        idle
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.fast, value: model.section)
    }

    // MARK: 正在打數字

    @ViewBuilder
    private func asking(_ r: KeypadController.Request) -> some View {
        if r.spec.title == "收現金", let t = model.checkoutTicket {
            DockCashChange(due: t.totals.balance, typed: r.entry.money ?? .zero)
        } else if r.spec.kind == .phone || r.spec.title == "會員" {
            // 打電話，或用相機掃會員卡（掃到＝把電話打進來、按查詢）
            VStack(alignment: .leading, spacing: 16) {
                MemberScanButton()
                DockMemberMatches(digits: r.entry.isPristine ? "" : r.entry.digits)
            }
        } else if r.spec.kind == .taxId {
            DockRecentTaxIds()
        } else {
            Color.clear
        }
    }

    // MARK: 待機

    @ViewBuilder
    private var idle: some View {
        // 外送平台：點餐、訂單、廚房、叫號頁的最上面（待接單有倒數，點一下到訂單接單）
        if model.deliveryEnabled && [.order, .orders, .kitchen, .queue, .floor].contains(model.section) {
            DockDeliveryPulse()
        }
        switch model.section {
        case .floor: DockFloorPulse()
        case .orders: DockOrdersPulse()
        case .kitchen: DockKitchenPulse()
        case .appointments: DockUpcoming()
        case .checkIn: DockCheckInPulse()
        case .reservations: DockReservationsPulse()
        case .queue: DockQueuePulse()
        case .shift: DockDrawer()
        // 點餐：外帶叫號的店把右欄空著的地方拿來列等候中的號碼（點一個就叫他）；其他店空著（品項在左邊、單子在中間）
        case .order: if model.queuePinned == .takeout { DockQueueWaiting() }
        case .members, .dashboard, .settings: EmptyView()
        }
    }
}

// MARK: - 共用的小東西

private struct DockSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title)
            content
        }
    }
}

private struct DockRow: View {
    let title: String
    var detail: String?
    var trailing: String?
    var tint: Color = Theme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brand(14.5, .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.brand(13.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}

private struct DockStat: View {
    let value: String
    let label: String
    var tint: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.brand(24, .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.brand(11.5, .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func minutesSince(_ d: Date) -> Int { max(Int(Date().timeIntervalSince(d) / 60), 0) }

// MARK: - 今天（店長以上）

private struct DockToday: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let s = model.state.dailySummary(businessDate: model.businessDate)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("今天")
                .font(.brand(12, .medium))
                .foregroundStyle(Theme.muted)
            MoneyText(money: s.total, role: .small, color: Theme.ink)
            Text("・\(s.tickets) 單")
                .font(.brand(12.5, .regular))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.line) }
    }
}

// MARK: - 收現金：找零

private struct DockCashChange: View {
    let due: Money
    let typed: Money

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DockSection(title: "應收") {
                MoneyText(money: due, role: .stat, color: Theme.ink2)
            }
            if typed.cents > 0 {
                if typed >= due {
                    DockSection(title: "找零") {
                        MoneyText(money: typed - due, role: .stat, color: Theme.accentText)
                    }
                } else {
                    DockSection(title: "還差（其他的用別的方式付）") {
                        MoneyText(money: due - typed, role: .stat, color: Theme.warningFG)
                    }
                }
            }
        }
        .contentTransition(.numericText())
        .animation(Motion.fast, value: typed)
    }
}

// MARK: - 查會員：打幾碼就列出熟客

private struct DockMemberMatches: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let digits: String

    var body: some View {
        let all = Array(model.members.values)
        let hits: [Member] = digits.count >= 3
            ? all.filter { $0.phone.filter(\.isNumber).contains(digits) }.sorted { ($0.name ?? "") < ($1.name ?? "") }
            : all.sorted { ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast) }
        DockSection(title: digits.count >= 3 ? "符合的會員" : "最近查過") {
            if hits.isEmpty {
                Text(digits.count >= 3 ? "這台還沒查過這個號碼；打完按「查詢」跟後台找" : "打電話號碼的 3 碼以上，查過的熟客會出現在這裡")
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(hits.prefix(5), id: \.id) { m in
                        Button {
                            let phone = m.phone.filter(\.isNumber)
                            keypad.apply(KeypadSpec.QuickKey(m.name ?? phone, digits: phone, commits: true))
                        } label: {
                            DockRow(title: m.name ?? m.ref.maskedPhone, detail: [m.ref.maskedPhone, m.tierName].compactMap { $0 }.joined(separator: "・"),
                                    trailing: nil)
                        }
                        .buttonStyle(.plain)
                        Rule()
                    }
                }
            }
        }
    }
}

// MARK: - 統編：今天用過的

private struct DockRecentTaxIds: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad

    var body: some View {
        let recent = recentBuyers
        if !recent.isEmpty {
            DockSection(title: "今天用過的統編") {
                VStack(spacing: 0) {
                    ForEach(recent, id: \.taxId) { b in
                        Button {
                            keypad.apply(KeypadSpec.QuickKey(b.taxId, digits: b.taxId, commits: true))
                        } label: {
                            DockRow(title: b.title ?? "統編 \(b.taxId)", detail: b.title == nil ? nil : b.taxId)
                        }
                        .buttonStyle(.plain)
                        Rule()
                    }
                }
            }
        }
    }

    private var recentBuyers: [(taxId: String, title: String?)] {
        var seen = Set<String>()
        var out: [(taxId: String, title: String?)] = []
        for inv in model.state.invoices.values.sorted(by: { $0.issuedAt > $1.issuedAt }) {
            guard case .business(let id, let title) = inv.buyer, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((id, title ?? inv.buyerName))
            if out.count == 5 { break }
        }
        return out
    }
}

// MARK: - 桌位

private struct DockFloorPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let tables = model.floor.areas.flatMap(\.tables)
        let statuses = tables.map { model.tableStatus($0.id) }
        let free = statuses.filter { $0 == .available }.count
        let dining = statuses.filter { $0 == .seated || $0 == .ordering }.count
        let billing = statuses.filter { $0 == .billing }.count
        let cleaning = statuses.filter { $0 == .needsCleaning }.count
        VStack(alignment: .leading, spacing: 22) {
            DockSection(title: "桌況") {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        DockStat(value: "\(free)", label: "空桌")
                        DockStat(value: "\(dining)", label: "用餐中", tint: Theme.accentText)
                    }
                    GridRow {
                        DockStat(value: "\(billing)", label: "待結帳", tint: billing > 0 ? Theme.warningFG : Theme.ink)
                        DockStat(value: "\(cleaning)", label: "待清桌")
                    }
                }
            }
            if !overtime.isEmpty {
                DockSection(title: "超過用餐時間") {
                    VStack(spacing: 0) {
                        ForEach(overtime, id: \.id) { t in
                            DockRow(title: t.title(floor: model.floor), trailing: "\(minutesSince(t.openedAt)) 分", tint: Theme.dangerFG)
                            Rule()
                        }
                    }
                }
            }
            if let next = nextReservation {
                DockSection(title: "下一組訂位") {
                    DockRow(title: "\(TaipeiTime.clock(next.startsAt))　\(next.name)",
                            detail: "\(next.partySize) 位" + (next.tableIds.isEmpty ? "" : "・\(model.floor.tableNames(next.tableIds))"))
                }
            }
        }
    }

    private var overtime: [Ticket] {
        let limit = model.store.tableTimeLimitMinutes
        guard limit > 0 else { return [] }
        return model.state.openTickets.filter { !$0.tableIds.isEmpty && minutesSince($0.openedAt) > limit }.prefix(4).map { $0 }
    }

    private var nextReservation: Reservation? {
        let now = Date().addingTimeInterval(-15 * 60)
        return model.reservations
            .filter { $0.kind == .reservation && $0.status.isActive && $0.startsAt >= now }
            .min { $0.startsAt < $1.startsAt }
    }
}

// MARK: - 訂單

private struct DockOrdersPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let open = model.state.openTickets
        let billing = open.filter { $0.billPrintedAt != nil }
        VStack(alignment: .leading, spacing: 22) {
            DockSection(title: "進行中") {
                HStack(spacing: 12) {
                    DockStat(value: "\(open.count)", label: "張單")
                    DockStat(value: Money.sum(open.map { $0.totals.amountDue }).short, label: "未結金額")
                }
            }
            if !billing.isEmpty {
                DockSection(title: "等著結帳") {
                    VStack(spacing: 0) {
                        ForEach(billing.prefix(4), id: \.id) { t in
                            Button {
                                model.selectedTicketId = t.id
                            } label: {
                                DockRow(title: t.title(floor: model.floor), detail: "結帳單 \(t.billPrintedAt.map(TaipeiTime.clock) ?? "")",
                                        trailing: t.totals.amountDue.short)
                            }
                            .buttonStyle(.plain)
                            Rule()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 外送平台

/// 待接單（倒數，點一下到訂單接單）、各平台的狀態、忙碌／暫停（一鍵）
private struct DockDeliveryPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let pending = model.deliveryPending
        let active = model.deliveryActive
        DockSection(title: pending.isEmpty ? "外送平台" : "外送待接 \(pending.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending.prefix(4)) { t in
                    if let d = t.delivery {
                        Button {
                            model.selectedTicketId = nil
                            model.deliveryFocusId = t.id
                            if model.section != .orders { model.go(.orders) }
                        } label: {
                            HStack(spacing: 8) {
                                DeliveryTag(delivery: d, size: 12)
                                Spacer(minLength: 4)
                                DeliveryClock(delivery: d, size: 12.5)
                            }
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if pending.isEmpty {
                    Text(active.isEmpty ? "沒有外送單" : "製作中、等取餐 \(active.count) 張")
                        .font(.brand(13, .regular))
                        .foregroundStyle(Theme.muted)
                }
                ForEach(model.deliveryConfig?.enabled ?? []) { p in
                    DeliveryPlatformRow(state: p)
                }
                HStack(spacing: 8) {
                    let busy = model.deliveryBusyMinutes
                    Button(busy > 0 ? "取消忙碌" : "忙碌 +10 分") {
                        Task { await model.setDeliveryBusy(busy > 0 ? 0 : 10) }
                    }
                    .buttonStyle(.brand(busy > 0 ? .primary : .ghost, size: .sm))
                    let paused = !model.deliveryPaused.isEmpty
                    Button(paused ? "恢復接單" : "暫停 30 分") {
                        Task {
                            if paused { await model.resumeDelivery(nil) } else { await model.pauseDelivery(nil, minutes: 30) }
                        }
                    }
                    .buttonStyle(.brand(paused ? .accent : .ghost, size: .sm))
                }
            }
        }
    }
}

// MARK: - 廚房

private struct DockKitchenPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        // 跟廚房看板同一批單：外帶先結帳的也還在等出餐
        let tickets = model.kitchenTickets()
        let lines = tickets.flatMap { t in t.lines.filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) } }
        let ready = tickets.flatMap { t in t.lines.filter { $0.isActive && $0.kitchen == .ready } }
        let oldest = lines.compactMap(\.sentAt).min()
        DockSection(title: "出餐") {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    DockStat(value: "\(lines.reduce(0) { $0 + $1.quantity })", label: "份待做")
                    DockStat(value: "\(ready.reduce(0) { $0 + $1.quantity })", label: "份可出餐", tint: ready.isEmpty ? Theme.ink : Theme.successFG)
                }
                GridRow {
                    DockStat(value: oldest.map { "\(minutesSince($0)) 分" } ?? "—", label: "最久的",
                             tint: (oldest.map { minutesSince($0) } ?? 0) >= 20 ? Theme.dangerFG : Theme.ink)
                    Color.clear.frame(height: 1)
                }
            }
        }
    }
}

// MARK: - 預約

private struct DockUpcoming: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let now = Date().addingTimeInterval(-30 * 60)
        let next = model.reservations
            .filter { $0.kind == .appointment && $0.status.isActive && $0.startsAt >= now }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(5)
        DockSection(title: next.isEmpty ? "接下來沒有預約" : "接下來") {
            VStack(spacing: 0) {
                ForEach(Array(next), id: \.id) { r in
                    DockRow(title: "\(TaipeiTime.clock(r.startsAt))　\(r.name)",
                            detail: [r.staffId.map { model.staffName($0) }, r.services?.map(\.name).joined(separator: "、")].compactMap { $0 }.joined(separator: "・"),
                            trailing: r.status == .arrived ? "已到" : nil,
                            tint: r.status == .arrived ? Theme.accentText : Theme.ink)
                    Rule()
                }
            }
        }
    }
}

// MARK: - 報到

private struct DockCheckInPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let today = model.state.checkIns(businessDate: model.businessDate, cutoffHour: model.store.businessDayCutoffHour)
        let nextClass = model.classes.filter { $0.endsAt > Date() }.min { $0.startsAt < $1.startsAt }
        VStack(alignment: .leading, spacing: 22) {
            DockSection(title: "今天報到") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(today.count)")
                        .font(.brand(34, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text("人次")
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.muted)
                }
                VStack(spacing: 0) {
                    ForEach(today.prefix(3), id: \.id) { c in
                        DockRow(title: c.member.name ?? c.member.maskedPhone, detail: c.passName, trailing: TaipeiTime.clock(c.at))
                        Rule()
                    }
                }
            }
            if let c = nextClass {
                DockSection(title: c.startsAt <= Date() ? "上課中" : "下一堂課") {
                    DockRow(title: "\(TaipeiTime.clock(c.startsAt))　\(c.name)",
                            detail: [c.staffId.map { model.staffName($0) }, c.room].compactMap { $0 }.joined(separator: "・"),
                            trailing: c.spotsLeft.map { $0 == 0 ? "額滿" : "剩 \($0) 位" } ?? "\(c.booked) 人",
                            tint: Theme.ink)
                }
            }
        }
    }
}

// MARK: - 訂位與候位

private struct DockReservationsPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let waiting = model.reservations.filter { $0.kind == .waitlist && $0.status.isActive }
        let next = model.reservations
            .filter { $0.kind == .reservation && $0.status.isActive && $0.startsAt >= Date().addingTimeInterval(-15 * 60) }
            .sorted { $0.startsAt < $1.startsAt }
            .prefix(3)
        VStack(alignment: .leading, spacing: 22) {
            DockSection(title: "現場候位") {
                DockStat(value: "\(waiting.count) 組", label: "最久等了 \(waiting.map { minutesSince($0.startsAt) }.max() ?? 0) 分")
            }
            if !next.isEmpty {
                DockSection(title: "接下來的訂位") {
                    VStack(spacing: 0) {
                        ForEach(Array(next), id: \.id) { r in
                            DockRow(title: "\(TaipeiTime.clock(r.startsAt))　\(r.name)", detail: "\(r.partySize) 位", trailing: nil)
                            Rule()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 叫號

/// 等候幾位、下一號、平均等了多久；號碼牌印在哪台
private struct DockQueuePulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let s = model.queue.state
        let waiting = s?.waiting.count ?? 0
        // 每 30 秒重算平均等候
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let average = s?.averageWaitMinutes(now: ctx.date)
            VStack(alignment: .leading, spacing: 22) {
                DockSection(title: "叫號") {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            DockStat(value: "\(waiting)", label: "位等候中", tint: waiting > 0 ? Theme.accentText : Theme.ink)
                            DockStat(value: s?.waiting.first.map { "\($0)" } ?? "—", label: "下一號")
                        }
                        GridRow {
                            DockStat(value: average.map { "\($0) 分" } ?? "—", label: "平均等候",
                                     tint: (average ?? 0) >= 15 ? Theme.warningFG : Theme.ink)
                            DockStat(value: s?.current.map { "\($0)" } ?? "—", label: "現在叫到")
                        }
                    }
                }
                if let p = model.queue.problem {
                    Text(p.message)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(p.blocksPage ? Theme.dangerFG : Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DockSection(title: "號碼牌") {
                    let printers = model.printers.targets(.queue)
                    if printers.isEmpty {
                        Text("這台沒有號碼牌出單機（設定 → 出單機，勾「號碼牌」）")
                            .font(.brand(12.5, .regular))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(printers) { p in
                                DockRow(title: p.name.isEmpty ? "號碼牌出單機" : p.name, detail: model.queuePrintsOthers ? "取號就印・也印別台取的" : "這台取號就印",
                                        trailing: p.paper.label)
                                Rule()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 交班

private struct DockDrawer: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        if let s = model.openShift {
            DockSection(title: "錢櫃應有") {
                MoneyText(money: model.state.expectedCash(shiftId: s.id), role: .stat)
                Text("\(TaipeiTime.clock(s.openedAt)) 開班・\(model.staffName(s.openedBy))")
                    .font(.brand(12, .regular))
                    .foregroundStyle(Theme.muted)
            }
        } else {
            DockSection(title: "錢櫃") {
                Text("還沒開班")
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}


// MARK: - 點餐頁：等候中的號碼（外帶叫號）

/// 右欄上面那張叫號卡下面：等候中的號碼一列一個——「28 號　A031・3 項・製作中　5 分」，點了叫他（先做好的先叫）。
/// 和叫號卡點開的面板同一份資料；放不下就捲
private struct DockQueueWaiting: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        if let s = model.queue.state, !s.waiting.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("等候中・點一個號碼叫他", color: Theme.muted)
                    ForEach(s.waiting, id: \.self) { n in
                        DockChoice(title: "\(n) 號", detail: detail(n, s), trailing: wait(n, s, now: ctx.date),
                                   enabled: model.queueCanCall(n)) {
                            Task { _ = await model.callQueue(n) }
                        }
                    }
                }
            }
        }
    }

    private func detail(_ n: Int, _ s: QueueState) -> String? {
        let parts = [s.waiting.first == n ? "下一號" : nil, model.queueDetail(n)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    private func wait(_ n: Int, _ s: QueueState, now: Date) -> String? {
        s.waitMinutes(n, now: now).map { $0 == 0 ? "剛取" : "\($0) 分" }
    }
}
