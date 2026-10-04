import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 桌位：iPad 的桌位圖（FloorView）與手機的桌位清單（PhoneFloorList）共用的資料與「選起來之後的動作」。
// 一桌的動作只有一份：iPad 放在右欄、手機放在下面的卡片，兩邊一模一樣（入座、點餐、結帳／送到結帳櫃台、換桌、併桌…）。

/// 換桌、併桌：先選單子，再點目的地
enum FloorPick: Equatable {
    case move(ticketId: String)
    case merge(ticketId: String)

    var ticketId: String {
        switch self {
        case .move(let id), .merge(let id): id
        }
    }

    /// 「換桌」「併桌」
    var kind: String {
        switch self {
        case .move: "換桌"
        case .merge: "併桌"
        }
    }

    /// 「換桌：A2 要換到哪一桌？」
    func title(_ name: String) -> String {
        switch self {
        case .move: "換桌：\(name) 要換到哪一桌？"
        case .merge: "併桌：\(name) 要併到哪一桌？"
        }
    }
}

/// 一桌現在的樣子（畫面用，不存）
struct FloorTableInfo: Identifiable {
    let table: DiningTable
    let status: TableStatus
    let tickets: [Ticket]
    /// 這桌接下來的訂位（還沒到、沒取消）
    let reservation: Reservation?
    /// 要注意的事（有就在桌子右上角點橘點，卡片上一條一條列出來）
    let attention: [String]

    var id: String { table.id }
    var isOccupied: Bool { !tickets.isEmpty }
    var guests: Int { tickets.reduce(0) { $0 + $1.guests } }
    /// 最早開的那張單（用餐多久從這裡算）
    var openedAt: Date? { tickets.map(\.openedAt).min() }

    /// 這一桌現在的樣子：桌況、開著的單、接下來的訂位、要注意的事
    static func make(_ t: DiningTable, model: POSModel, soon: Set<String>, now: Date) -> FloorTableInfo {
        let tickets = model.state.openTickets(at: t.id)
        let upcoming = model.reservations
            .filter { $0.kind == .reservation && $0.status.isActive && $0.tableIds.contains(t.id) && $0.startsAt > now.addingTimeInterval(-15 * 60) }
            .min { $0.startsAt < $1.startsAt }

        // 要注意（桌子右上角的橘點）：餐好了要上、待結帳（印了結帳單、或送到結帳櫃台）還沒付、超過用餐時間、15 分鐘內有訂位
        var attention: [String] = []
        let ready = tickets.flatMap(\.lines).filter { $0.isActive && $0.kitchen == .ready }.reduce(0) { $0 + $1.quantity }
        if ready > 0 { attention.append("\(ready) 份餐好了，可以上菜") }
        if let sent = tickets.first(where: { $0.billPrintedAt != nil && $0.billSentFrom != nil }), let from = sent.billSentFrom {
            attention.append("從\(from)送到結帳櫃台，等客人付款")
        } else if tickets.contains(where: { $0.billPrintedAt != nil }) {
            attention.append("結帳單印了，等客人付款")
        }
        let limit = model.store.tableTimeLimitMinutes
        if limit > 0, let opened = tickets.map(\.openedAt).min() {
            let m = Int(now.timeIntervalSince(opened) / 60)
            if m > limit { attention.append("超過用餐時間 \(m - limit) 分鐘") }
        }
        if let r = upcoming, r.startsAt <= now.addingTimeInterval(15 * 60) {
            attention.append("\(r.startsAt.clockText) \(r.name) \(r.partySize) 位訂了這桌")
        }

        return FloorTableInfo(
            table: t,
            status: model.state.status(of: t.id, reservedSoon: soon),
            tickets: tickets,
            reservation: upcoming,
            attention: attention
        )
    }

    /// 換桌、併桌時這一桌能不能當目的地
    func accepts(_ p: FloorPick, in state: StoreState) -> Bool {
        guard let source = state.tickets[p.ticketId] else { return false }
        switch p {
        case .move:
            return (status == .available || status == .reserved) && !source.tableIds.contains(table.id)
        case .merge:
            return tickets.contains { $0.id != source.id }
        }
    }
}

/// 一桌選起來之後的動作：大鍵看桌況（空桌＝入座、剛入座＝點餐、點過＝加點、待結帳＝結帳；不收錢的崗位是送到結帳櫃台），
/// 其他（換桌、併桌、印結帳單、改人數、訂位入座…）是動作鍵。動作要做的事由畫面給（iPad 的桌位圖、手機的清單各自記選了哪一桌）
struct TableDock {
    let model: POSModel
    /// 同一桌有好幾張單（拆過單）時，看的是哪一張
    var cardTicketId: String?
    let seat: @MainActor (DiningTable) -> Void
    let seatReservation: @MainActor (Reservation, DiningTable) -> Void
    let clean: @MainActor (DiningTable, Bool) -> Void
    let order: @MainActor (Ticket) -> Void
    let startPick: @MainActor (FloorPick) -> Void
    let deselect: @MainActor () -> Void

    /// 這台有點餐頁（報到接待沒有：只把單子打開在旁邊）
    private var canOrderHere: Bool { model.visibleSections.contains(.order) }

    func selection(_ i: FloorTableInfo) -> DockSelection {
        let t = i.table
        let badge = DockBadge(i.status.label, tone: Self.tone(i.status))
        let id = "table-\(t.id)"
        switch i.status {
        case .available:
            // 大鍵：入座（鍵盤問人數）；這桌有訂位就多一個「訂位入座」
            var actions: [POSAction] = []
            if let r = i.reservation {
                actions.append(POSAction("訂位入座：\(r.name)", icon: "calendar-days") { seatReservation(r, t) })
            }
            // 排隊等內用：桌子空出來了，叫下一號直接坐這一桌
            if let call = callNextAction(t) { actions.append(call) }
            var detail = "空桌・\(t.seats) 人桌"
            if let r = i.reservation { detail += "・\(r.startsAt.clockText) \(r.name) \(r.partySize) 位訂了這桌" }
            return DockSelection(id: id, kind: "桌位", title: t.name, detail: detail, badge: badge,
                                 primary: POSAction("入座", icon: "users") { seat(t) },
                                 actions: actions, clear: { deselect() })
        case .reserved:
            if let r = i.reservation {
                return DockSelection(id: id, kind: "桌位", title: t.name,
                                     detail: "\(r.startsAt.clockText) \(r.name) \(r.partySize) 位", badge: badge,
                                     primary: POSAction("\(r.name) 到了，入座", icon: "check") { seatReservation(r, t) },
                                     actions: [POSAction("帶其他客人", icon: "users") { seat(t) }], clear: { deselect() })
            }
            return DockSelection(id: id, kind: "桌位", title: t.name, detail: "\(t.seats) 人桌", badge: badge,
                                 primary: POSAction("入座", icon: "users") { seat(t) }, clear: { deselect() })
        case .needsCleaning:
            var actions = [POSAction("清好了，直接入座", icon: "users") { clean(t, true) }]
            if let call = callNextAction(t, cleanFirst: true) { actions.append(call) }
            return DockSelection(id: id, kind: "桌位", title: t.name, detail: "結完帳了，桌面整理好就改回空桌", badge: badge,
                                 primary: POSAction("清桌", icon: "sparkles") { clean(t, false) },
                                 actions: actions,
                                 clear: { deselect() })
        case .seated, .ordering, .billing:
            guard let ticket = i.tickets.first(where: { $0.id == cardTicketId }) ?? i.tickets.first else {
                return DockSelection(id: id, kind: "桌位", title: t.name, badge: badge, clear: { deselect() })
            }
            return occupied(i, ticket: ticket, badge: badge)
        }
    }

    /// 排隊等內用：「叫號入座：31 號（4 位）」＝叫等候的第一組、直接坐這一桌（人數不知道的鍵盤先問）。
    /// cleanFirst：待清的桌子先清好
    private func callNextAction(_ t: DiningTable, cleanFirst: Bool = false) -> POSAction? {
        let model = model
        guard model.queueForDineIn, let n = model.queue.state?.waiting.first else { return nil }
        let guests = model.queueEntry(n)?.guests
        let title = (cleanFirst ? "清好了，叫號入座 \(n)" : "叫號入座：\(n) 號") + (guests.map { "（\($0) 位）" } ?? "")
        return POSAction(title, icon: "megaphone", enabled: model.queueCanAct && !model.queueCooling(.next)) {
            if cleanFirst { model.clean(table: t) }
            Task { await model.callToSeat(n, table: t) }
        }
    }

    /// 用餐中：大鍵看桌況（剛入座＝點餐、點過＝加點、待結帳＝結帳）；其他是動作鍵。
    /// 不收錢的崗位（報到接待、前場的手機）多一個「送到結帳櫃台」：櫃台跳出這張單，客人到櫃台一起結
    private func occupied(_ i: FloorTableInfo, ticket: Ticket, badge: DockBadge) -> DockSelection {
        let t = i.table
        let model = model
        let pays = model.takesPayment
        let checkout = POSAction("結帳", icon: "credit-card") { model.beginCheckout(ticket) }
        let orderTitle = canOrderHere ? (ticket.lines.isEmpty ? "點餐" : "加點") : "看單"
        let orderAction = POSAction(orderTitle, icon: "squares-2x2") { order(ticket) }
        let billingFirst = pays && i.status == .billing
        let sent = ticket.billPrintedAt != nil && ticket.billSentFrom != nil
        var actions: [POSAction] = []
        if billingFirst {
            actions.append(orderAction)
        } else if pays {
            actions.append(checkout)
        } else if model.role.takesOrders {
            actions.append(POSAction(sent ? "再送一次到櫃台" : "送到結帳櫃台", icon: "paper-airplane", enabled: !ticket.activeLines.isEmpty) {
                model.sendToRegister(ticket)
            })
        }
        if model.canPrintBill {
            actions.append(POSAction("印結帳單", icon: "printer") {
                model.printBill(ticket)
                model.show("已送出 \(ticket.title(floor: model.floor)) 的結帳單")
            })
        }
        actions.append(POSAction("改人數", icon: "user-group") { Task { await model.setGuests(ticket) } })
        actions.append(POSAction("換桌", icon: "arrows-right-left") { startPick(.move(ticketId: ticket.id)) })
        actions.append(POSAction("併桌", icon: "link") { startPick(.merge(ticketId: ticket.id)) })
        let minutes = max(0, Int(Date().timeIntervalSince(ticket.openedAt) / 60))
        var parts = ["\(ticket.guests) 位", "\(minutes) 分", ticket.totals.amountDue.formatted]
        if i.tickets.count > 1 { parts.insert("\(ticket.number)（共 \(i.tickets.count) 張單）", at: 0) }
        // 不收錢：結帳在結帳櫃台
        if sent {
            parts.append("已送到結帳櫃台")
        } else if !pays {
            parts.append("已同步到結帳櫃台")
        }
        return DockSelection(id: "table-\(t.id)-\(ticket.id)", kind: "桌位", title: t.name,
                             detail: parts.joined(separator: "・"), badge: badge,
                             primary: billingFirst ? checkout : orderAction,
                             actions: actions, clear: { deselect() })
    }

    static func tone(_ s: TableStatus) -> Tone {
        switch s {
        case .available: .neutral
        case .reserved: .info
        case .seated, .ordering: .gold
        case .billing: .warning
        case .needsCleaning: .danger
        }
    }
}
