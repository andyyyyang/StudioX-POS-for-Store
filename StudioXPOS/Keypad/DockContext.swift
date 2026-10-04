import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側鍵盤上面的那一塊：跟著現在在做的事變。鍵位永遠固定在下面，這裡放「這一刻最需要的資訊」。
///
///   正在打數字：收現金 → 即時的找零／還差；查會員 → 打幾碼就列出熟客（點一下帶入）；統編 → 今天用過的
///   待機：點餐 → 今天熱賣（點一下加入，配合先打數量）；桌位 → 桌況與超時、下一組訂位；預約 → 接下來的；
///         報到 → 今天的人次、下一堂課；廚房 → 待做與最久的；訂單 → 待結帳；交班 → 錢櫃應有；店長以上看得到今天的營業額
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
                        if model.currentStaff?.can(.viewReports) == true { DockToday() }
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
            DockMemberMatches(digits: r.entry.isPristine ? "" : r.entry.digits)
        } else if r.spec.kind == .taxId {
            DockRecentTaxIds()
        } else {
            Color.clear
        }
    }

    // MARK: 待機

    @ViewBuilder
    private var idle: some View {
        switch model.section {
        case .order: DockQuickPicks()
        case .floor: DockFloorPulse()
        case .orders: DockOrdersPulse()
        case .kitchen: DockKitchenPulse()
        case .appointments: DockUpcoming()
        case .checkIn: DockCheckInPulse()
        case .reservations: DockReservationsPulse()
        case .shift: DockDrawer()
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

// MARK: - 點餐：今天熱賣

private struct DockQuickPicks: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad

    var body: some View {
        let picks = items
        if !picks.isEmpty {
            DockSection(title: keypad.multiplier.map { "今天熱賣・點一下加 ×\($0)" } ?? "今天熱賣・點一下加入") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(picks) { item in
                        Button {
                            Task { await model.tap(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.shortName ?? item.name)
                                    .font(.brand(13.5, .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(item.hasVariants ? "選規格" : item.price.short)
                                    .font(.brand(12, .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.line) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("加入 \(item.name)")
                    }
                }
            }
        }
    }

    /// 今天賣最多的（還能賣的）；不夠六個用菜單前面的補
    private var items: [MenuItem] {
        let top = model.state.dailySummary(businessDate: model.businessDate).topItems
        var out: [MenuItem] = []
        for t in top {
            guard let i = model.catalog.item(t.id), model.isAvailable(i), i.itemKind == .goods || i.itemKind == .service else { continue }
            out.append(i)
            if out.count == 6 { return out }
        }
        for c in model.catalog.categories {
            for i in model.catalog.items(in: c.id) where model.isAvailable(i) && !out.contains(where: { $0.id == i.id }) && !i.itemKind.needsMember {
                out.append(i)
                if out.count == 6 { return out }
            }
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

// MARK: - 廚房

private struct DockKitchenPulse: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let lines = model.state.openTickets.flatMap { t in t.lines.filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) } }
        let ready = model.state.openTickets.flatMap { t in t.lines.filter { $0.isActive && $0.kitchen == .ready } }
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
                DockStat(value: "\(waiting.count) 組", label: "最久等了 \(waiting.map { minutesSince($0.createdAt) }.max() ?? 0) 分")
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
