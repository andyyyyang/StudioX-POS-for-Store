import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 手機的桌位：桌位圖在手機上太小，改成照區域分組的清單（桌況的顏色、幾位、坐了多久、金額）。
///
///   ┌ Floor plan ───── 空桌 6・用餐中 4 ┐
///   │ ■ 1F  3/11                      │
///   │ ▌A2   用餐中    4 位・32 分  NT$1,280 ● │
///   │ ▌A3   空桌      4 人桌               │
///   └──────────────────────────────────┘
///
/// 點一桌＝選起來（再點一次取消）；動作和 iPad 桌位圖的右欄同一份（TableDock）：入座、點餐／加點、送到結帳櫃台、換桌、併桌…
struct PhoneFloorList: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTableId: String?
    /// 同一桌好幾張單（拆過單）時看哪一張：和 iPad 一樣看第一張
    @State private var cardTicketId: String?
    /// 換桌、併桌：選好單子，等著點目的地
    @State private var pick: FloorPick?

    var body: some View {
        // 每 30 秒重畫：坐了多久、快到的訂位、超時
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
        .dockSelection(dock)
        .onAppear {
            // 截圖：先選一桌用餐中的
            if LaunchArguments.preselect, selectedTableId == nil,
               let t = model.floor.allTables.first(where: { !model.state.openTickets(at: $0.id).isEmpty }) {
                selectedTableId = t.id
            }
        }
    }

    private var anim: Animation? { reduceMotion ? nil : Motion.fast }

    // MARK: 清單

    private func content(now: Date) -> some View {
        let soon = model.reservedSoon
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                    header(soon: soon)
                        .padding(.bottom, 6)
                    if let p = pick {
                        pickBanner(p)
                    }
                    if model.floor.areas.isEmpty {
                        EmptyState(icon: "table-cells", title: "還沒有桌位", message: "請店長到後台「門市 POS → 桌位」排好桌子，這裡會自動出現。")
                            .frame(height: 260)
                    }
                    ForEach(model.floor.areas) { area in
                        let infos = area.tables.map { FloorTableInfo.make($0, model: model, soon: soon, now: now) }
                        areaHeader(area, infos: infos)
                            .padding(.top, 12)
                        ForEach(infos) { i in
                            row(i, now: now)
                                .id(i.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedTableId) { _, id in
                guard let id else { return }
                withAnimation(anim) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func header(soon: Set<String>) -> some View {
        let statuses = model.floor.allTables.map { model.state.status(of: $0.id, reservedSoon: soon) }
        let free = statuses.filter { $0 == .available }.count
        let dining = statuses.filter { $0 == .seated || $0 == .ordering || $0 == .billing }.count
        let billing = statuses.filter { $0 == .billing }.count
        let dirty = statuses.filter { $0 == .needsCleaning }.count
        return VStack(alignment: .leading, spacing: 10) {
            PageTitle(title: "Floor *plan*", subtitle: "桌位")
            HStack(spacing: 8) {
                count(TableStatus.available.label, free, .available)
                count(TableStatus.ordering.label, dining, .ordering)
                if billing > 0 { count(TableStatus.billing.label, billing, .billing) }
                if dirty > 0 { count(TableStatus.needsCleaning.label, dirty, .needsCleaning) }
            }
        }
    }

    private func count(_ label: String, _ n: Int, _ s: TableStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.table(s)).frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(Theme.muted)
            Text("\(n)")
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .font(.brand(13, .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.line) }
    }

    private func areaHeader(_ a: FloorArea, infos: [FloorTableInfo]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(a.name.isEmpty ? "未命名" : a.name)
            Spacer(minLength: 8)
            Text("\(infos.filter(\.isOccupied).count)/\(infos.count) 桌用餐中")
                .font(.brand(12.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
    }

    /// 一桌：左邊桌況的色條、桌名與狀態、幾位・坐了多久（或空桌幾人桌、訂位）、金額；要注意的事是橘點
    private func row(_ i: FloorTableInfo, now: Date) -> some View {
        let selected = selectedTableId == i.id || isPickSource(i)
        let dimmed = pick.map { !i.accepts($0, in: model.state) && !isPickSource(i) } ?? false
        return Button {
            tap(i)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(i.table.name)
                            .font(.brand(18, .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        FloorStatusTag(status: i.status)
                        if i.tickets.count > 1 {
                            Text("\(i.tickets.count) 張單")
                                .textRole(.xs)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(detail(i, now: now))
                        .font(.brand(13, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let first = i.attention.first {
                        Text(first + (i.attention.count > 1 ? "（還有 \(i.attention.count - 1) 件）" : ""))
                            .font(.brand(12.5, .medium))
                            .foregroundStyle(Theme.accentText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: 6)
                if i.isOccupied {
                    MoneyText(money: Money.sum(i.tickets.map(\.totals.amountDue)), role: .h4)
                        .fixedSize()
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            // 左邊的色條＝桌況（和桌位圖同一組顏色）
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.table(i.status))
                    .frame(width: 5)
                    .padding(.vertical, 12)
                    .padding(.leading, 9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1)
            }
            .opacity(dimmed ? 0.4 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel("\(i.table.name)，\(i.status.label)，\(detail(i, now: now))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 「4 位・32 分」；空桌「4 人桌」；訂位「18:30 王先生 4 位」；待清桌「結完帳了」
    private func detail(_ i: FloorTableInfo, now: Date) -> String {
        switch i.status {
        case .seated, .ordering, .billing:
            let minutes = i.openedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) } ?? 0
            var parts = ["\(i.guests) 位", "\(minutes) 分"]
            if let t = i.tickets.first, t.billSentFrom != nil, t.billPrintedAt != nil { parts.append("已送到結帳櫃台") }
            return parts.joined(separator: "・")
        case .reserved:
            if let r = i.reservation { return "\(r.startsAt.clockText) \(r.name) \(r.partySize) 位" }
            return "\(i.table.seats) 人桌"
        case .needsCleaning:
            return "結完帳了，整理好就改回空桌"
        case .available:
            if let r = i.reservation { return "\(i.table.seats) 人桌・\(r.startsAt.clockText) 有訂位" }
            return "\(i.table.seats) 人桌"
        }
    }

    // MARK: 點一桌

    private func tap(_ i: FloorTableInfo) {
        model.touch()
        if let pick {
            finishPick(pick, at: i)
            return
        }
        withAnimation(anim) {
            if selectedTableId == i.id {
                selectedTableId = nil
                cardTicketId = nil
            } else {
                selectedTableId = i.id
                cardTicketId = nil
            }
        }
    }

    private func deselect() {
        withAnimation(anim) {
            selectedTableId = nil
            cardTicketId = nil
        }
    }

    // MARK: 選起來之後的動作（和 iPad 的桌位圖同一份）

    private var dock: DockSelection? {
        if let p = pick { return pickDock(p) }
        guard let id = selectedTableId, let t = model.floor.allTables.first(where: { $0.id == id }) else { return nil }
        let info = FloorTableInfo.make(t, model: model, soon: model.reservedSoon, now: Date())
        return TableDock(model: model, cardTicketId: cardTicketId,
                         seat: { seat($0) },
                         seatReservation: { seatReservation($0, at: $1) },
                         clean: { clean($0, thenSeat: $1) },
                         order: { order($0) },
                         startPick: { startPick($0) },
                         deselect: { deselect() })
            .selection(info)
    }

    /// 入座：鍵盤問人數 → 開單 → 到點餐（取消就停在這裡）
    private func seat(_ t: DiningTable) {
        selectedTableId = t.id
        Task { await model.seat(table: t) }
    }

    /// 訂位的客人到了：用訂位入座（大團體訂了好幾桌，還空著的都一起帶）
    private func seatReservation(_ r: Reservation, at t: DiningTable) {
        var ids = r.tableIds.filter { id in
            let s = model.tableStatus(id)
            return s == .available || s == .reserved
        }
        if !ids.contains(t.id) { ids = [t.id] }
        Task { await model.seat(r, at: ids) }
    }

    private func clean(_ t: DiningTable, thenSeat: Bool) {
        model.clean(table: t)
        if thenSeat {
            seat(t)
        } else {
            model.show("\(t.name) 清好了")
            deselect()
        }
    }

    /// 點餐／加點：到點餐頁、那張單打開在下面
    private func order(_ ticket: Ticket) {
        deselect()
        model.selectedTicketId = ticket.id
        if model.visibleSections.contains(.order) { model.go(.order) }
    }

    // MARK: 換桌、併桌

    private func startPick(_ p: FloorPick) {
        model.keypad.cancel()
        withAnimation(anim) { pick = p }
    }

    private func isPickSource(_ i: FloorTableInfo) -> Bool {
        guard let pick, let source = model.state.tickets[pick.ticketId] else { return false }
        return source.tableIds.contains(i.table.id)
    }

    private func finishPick(_ p: FloorPick, at i: FloorTableInfo) {
        guard let source = model.state.tickets[p.ticketId], source.isOpen else {
            withAnimation(anim) { pick = nil }
            return
        }
        guard i.accepts(p, in: model.state) else {
            switch p {
            case .move: model.show("請點一張空桌", tone: .warning)
            case .merge: model.show("請點一桌正在用餐的", tone: .warning)
            }
            return
        }
        switch p {
        case .move:
            model.move(source, to: [i.table.id])
        case .merge:
            guard let target = i.tickets.first(where: { $0.id != source.id }) else { return }
            model.merge(source, into: target)
        }
        model.selectedTicketId = nil
        withAnimation(anim) {
            pick = nil
            selectedTableId = i.table.id
            cardTicketId = nil
        }
    }

    private func pickBanner(_ p: FloorPick) -> some View {
        let name = model.state.tickets[p.ticketId].map { $0.title(floor: model.floor) } ?? "這張單"
        return HStack(spacing: 12) {
            LiveDot(color: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title(name))
                    .font(.brand(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pickHint(p))
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.dock, in: .rect(cornerRadius: Metric.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
        }
        .transition(.opacity)
    }

    private func pickHint(_ p: FloorPick) -> String {
        switch p {
        case .move: "點一張空桌（亮著的那些）"
        case .merge: "點一桌正在用餐的，兩張單會合成一張"
        }
    }

    /// 換桌、併桌：等著點目的地（× 取消）
    private func pickDock(_ p: FloorPick) -> DockSelection {
        let name = model.state.tickets[p.ticketId].map { $0.title(floor: model.floor) } ?? "這張單"
        return DockSelection(id: "pick-\(p.ticketId)", kind: p.kind, title: name, detail: pickHint(p),
                             clear: { withAnimation(anim) { pick = nil } })
    }
}
