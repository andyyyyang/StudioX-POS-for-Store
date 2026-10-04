import Foundation

/// 兩台 iPad 斷線時各做各的、連上後才發現衝突（同一桌兩邊都結帳、結帳後又加點…）。
/// 不吞掉：留一筆給店長處理（App 上方會出現一條提醒）。
public struct Conflict: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// 兩台都結了同一張單
        case doubleClose
        /// 單子已經結了，另一台又收了一筆錢（要退）
        case paymentAfterClose
        /// 單子已經結了／作廢了，另一台又加了品項（沒有收到錢）
        case linesAfterClose
        /// 同一張發票號碼開了兩次（不該發生：號碼段是分開配的）
        case duplicateInvoice
    }

    /// 造成衝突的事件 id
    public var id: String
    public var kind: Kind
    public var ticketId: String?
    public var deviceId: String
    public var message: String
    public var at: Date
    public var resolved: Bool

    public init(id: String, kind: Kind, ticketId: String?, deviceId: String, message: String, at: Date, resolved: Bool = false) {
        self.id = id; self.kind = kind; self.ticketId = ticketId; self.deviceId = deviceId; self.message = message; self.at = at; self.resolved = resolved
    }
}

/// 這家店現在的樣子：把所有事件依序重播的結果。
///
/// `apply` 只看事件內容（不看現在時間、不碰網路、不碰檔案），所以在每台 iPad 與後台重播出來都一樣。
public struct StoreState: Codable, Sendable, Hashable {
    public var tickets: [String: Ticket] = [:]
    public var sales: [String: SaleRecord] = [:]
    public var shifts: [String: Shift] = [:]
    /// 結完帳還沒清的桌子
    public var needsCleaning: Set<String> = []
    public var attendance: [ClockEntry] = []
    /// 今天賣完的品項（覆寫菜單上的 isAvailable）
    public var itemAvailability: [String: Bool] = [:]
    public var invoices: [String: EInvoice] = [:]
    public var voidedInvoices: [String: VoidInfo] = [:]
    public var allowances: [EInvoiceAllowance] = []
    public var conflicts: [Conflict] = []
    /// 入場報到（健身房、教室）
    public var checkIns: [String: CheckIn] = [:]
    /// 每一筆事件造成的會員帳戶變動（儲值金、課程卡）。查會員時把後台還沒算進去的補上
    public var accountLog: [AccountEntry] = []
    /// 套用過的事件數（快照之後接著算）
    public var applied: Int = 0
    /// 看過最大的 Lamport 時鐘
    public var lamport: Int = 0
    /// 每台裝置看過最大的流水號
    public var deviceSeq: [String: Int] = [:]

    public init() {}

    /// 從頭重播
    public static func replay(_ events: [POSEvent]) -> StoreState {
        var s = StoreState()
        for e in events.sorted(by: POSEvent.replayOrder) { s.apply(e) }
        return s
    }

    // MARK: - 套用一筆事件

    public mutating func apply(_ e: POSEvent) {
        applied += 1
        lamport = max(lamport, e.lamport)
        deviceSeq[e.deviceId] = max(deviceSeq[e.deviceId] ?? 0, e.seq)
        let at = e.date
        let staff = e.staffId ?? ""

        switch e.body {
        case .ticketOpened(let o):
            guard tickets[o.ticketId] == nil else { return }
            tickets[o.ticketId] = Ticket(
                id: o.ticketId, number: o.number, deviceId: e.deviceId, orderType: o.orderType, tableIds: o.tableIds,
                guests: o.guests, serviceChargeBps: o.serviceChargeBps, member: o.member, openedAt: at, openedBy: staff,
                businessDate: o.businessDate, splitFrom: o.splitFrom, customerName: o.customerName,
                serviceMode: o.serviceMode, salespersonId: o.salespersonId, exchange: o.exchange, appointmentId: o.appointmentId
            )
            needsCleaning.subtract(o.tableIds)

        case .linesAdded(let a):
            guard var t = tickets[a.ticketId] else { return }
            guard t.isOpen else {
                conflict(e, .linesAfterClose, t.id, "\(t.number) 已經\(t.status == .closed ? "結帳" : "作廢")，另一台又加了 \(a.lines.count) 個品項（沒有收到錢）")
                return
            }
            for line in a.lines where !t.lines.contains(where: { $0.id == line.id }) {
                t.lines.append(line)
            }
            tickets[t.id] = t

        case .lineUpdated(let u):
            updateLine(u.ticketId, u.lineId) { l in
                if let q = u.quantity { l.quantity = max(q, 1) }
                if let p = u.unitPrice { l.unitPrice = p }
                if let n = u.note { l.note = n }
                if let s = u.seat { l.seat = s == 0 ? nil : s }
                if let c = u.course { l.course = c }
                if let m = u.modifiers { l.modifiers = m }
                if u.clearDiscount == true { l.discount = nil }
                if let d = u.discount { l.discount = d }
                if let s = u.staffId { l.staffId = s.isEmpty ? nil : s }
                if let a = u.assistantId { l.assistantId = a.isEmpty ? nil : a }
                if let c = u.commissionBps { l.commissionBps = c }
                if u.clearRedeem == true { l.redeem = nil }
                if let r = u.redeem { l.redeem = r }
                if let p = u.passStartsAt { l.passStartsAt = p }
                if let k = u.skuId {
                    l.skuId = k
                    l.variantName = u.variantName
                    l.variantId = u.variantId
                }
            }

        case .linesVoided(let v):
            for id in v.lineIds {
                updateLine(v.ticketId, id, allowClosed: false) { l in
                    l.voided = VoidInfo(reason: v.reason, by: staff, authorizedBy: v.authorizedBy, at: at, wasSent: l.isSent)
                }
            }

        case .linesRemoved(let r):
            // 只拿掉還沒送出的（送出去的要作廢，廚房才知道）
            guard var t = tickets[r.ticketId], t.isOpen else { return }
            let ids = Set(r.lineIds)
            t.lines.removeAll { ids.contains($0.id) && !$0.isSent }
            tickets[t.id] = t

        case .linesSent(let s):
            for id in s.lineIds {
                updateLine(s.ticketId, id) { l in
                    if l.kitchen == .new {
                        l.kitchen = .sent
                        l.sentAt = at
                    }
                }
            }

        case .kitchenUpdated(let k):
            // 廚房在結帳後才按「出餐」也照樣記（外帶先結帳後出餐很常見）
            for id in k.lineIds {
                updateLine(k.ticketId, id, allowClosed: true) { l in
                    l.kitchen = k.status
                    l.kitchenAt = at
                    if l.sentAt == nil { l.sentAt = at }
                }
            }

        case .ticketUpdated(let u):
            guard var t = tickets[u.ticketId] else { return }
            if let g = u.guests { t.guests = max(g, 0) }
            if let n = u.note { t.note = n }
            if let o = u.orderType { t.orderType = o }
            if let s = u.serviceChargeBps { t.serviceChargeBps = max(s, 0) }
            if u.clearDiscount == true { t.discount = nil }
            if let d = u.discount { t.discount = d }
            if let tip = u.tip { t.tip = tip }
            if let b = u.invoiceBuyer { t.invoiceBuyer = b }
            if u.clearMember == true { t.member = nil }
            if let m = u.member { t.member = m }
            if let c = u.customerName { t.customerName = c.isEmpty ? nil : c }
            if let s = u.salespersonId { t.salespersonId = s.isEmpty ? nil : s }
            if let q = u.queueNumber {
                t.queueNumber = q > 0 ? q : nil
                // 外帶是結帳完成「之後」才拿到號碼：結帳那一刻的紀錄也跟著掛上（收據、訂單、報表看得到）
                if sales[t.id] != nil { sales[t.id]?.queueNumber = t.queueNumber }
            }
            tickets[t.id] = t

        case .ticketMoved(let m):
            guard var t = tickets[m.ticketId], t.isOpen else { return }
            t.tableIds = m.tableIds
            tickets[t.id] = t
            needsCleaning.subtract(m.tableIds)

        case .ticketsMerged(let m):
            guard var target = tickets[m.targetId], var source = tickets[m.sourceId], target.isOpen, source.isOpen, m.targetId != m.sourceId else { return }
            target.lines += source.lines.filter { l in !target.lines.contains { $0.id == l.id } }
            target.payments += source.payments
            target.guests += source.guests
            target.tableIds += source.tableIds.filter { !target.tableIds.contains($0) }
            if target.member == nil { target.member = source.member }
            source.lines = []
            source.payments = []
            source.status = .voided
            source.mergedInto = target.id
            source.closedAt = at
            source.closedBy = staff
            tickets[target.id] = target
            tickets[source.id] = source

        case .ticketSplit(let s):
            guard var source = tickets[s.sourceId], source.isOpen, tickets[s.opened.ticketId] == nil else { return }
            var fresh = Ticket(
                id: s.opened.ticketId, number: s.opened.number, deviceId: e.deviceId, orderType: s.opened.orderType,
                tableIds: s.opened.tableIds, guests: s.opened.guests, serviceChargeBps: s.opened.serviceChargeBps,
                member: s.opened.member ?? source.member, openedAt: at, openedBy: staff, businessDate: s.opened.businessDate,
                splitFrom: source.id, customerName: s.opened.customerName, serviceMode: s.opened.serviceMode ?? source.serviceMode,
                salespersonId: s.opened.salespersonId ?? source.salespersonId
            )
            fresh.invoiceBuyer = .paper
            for move in s.moves {
                guard let i = source.lines.firstIndex(where: { $0.id == move.lineId }), source.lines[i].isActive, move.quantity > 0 else { continue }
                var moved = source.lines[i]
                moved.id = move.newLineId
                if move.quantity >= source.lines[i].quantity {
                    source.lines.remove(at: i)
                } else {
                    moved.quantity = move.quantity
                    // 拆一部分數量：單品折扣若是固定金額，留在原來那行，避免兩行各折一次
                    if moved.discount?.kind == .amount { moved.discount = nil }
                    source.lines[i].quantity -= move.quantity
                }
                fresh.lines.append(moved)
            }
            tickets[source.id] = source
            tickets[fresh.id] = fresh

        case .billPrinted(let b):
            guard var t = tickets[b.ticketId] else { return }
            t.billPrintedAt = at
            // 送到結帳櫃台（手機、報到接待）記從哪裡來；之後在櫃台真的印了結帳單就是印的
            t.billSentFrom = b.sentFrom
            tickets[t.id] = t

        case .paymentAdded(let p):
            guard var t = tickets[p.ticketId] else { return }
            if !t.isOpen {
                conflict(e, .paymentAfterClose, t.id, "\(t.number) 已經結帳，另一台又收了 \(p.payment.tender.label) \(p.payment.amount.formatted)（要退給客人）")
            }
            if !t.payments.contains(where: { $0.id == p.payment.id }) { t.payments.append(p.payment) }
            tickets[t.id] = t

        case .paymentVoided(let v):
            guard var t = tickets[v.ticketId], let i = t.payments.firstIndex(where: { $0.id == v.paymentId }) else { return }
            t.payments[i].status = .voided
            t.payments[i].voidReason = v.reason
            tickets[t.id] = t

        case .invoiceIssued(let i):
            if let existing = invoices[i.invoice.number], existing.ticketId != i.invoice.ticketId {
                conflict(e, .duplicateInvoice, i.ticketId, "發票 \(i.invoice.number) 開了兩次（\(existing.ticketId.prefix(8))、\(i.ticketId.prefix(8))）")
                return
            }
            invoices[i.invoice.number] = i.invoice
            guard var t = tickets[i.ticketId] else { return }
            t.invoice = i.invoice.stamp
            tickets[t.id] = t

        case .invoiceVoided(let v):
            voidedInvoices[v.number] = VoidInfo(reason: v.reason, by: staff, authorizedBy: v.authorizedBy, at: at, wasSent: false)
            guard var t = tickets[v.ticketId], t.invoice?.number == v.number else { return }
            t.invoice?.voidedAt = at
            t.invoice?.voidReason = v.reason
            tickets[t.id] = t
            if sales[t.id]?.invoice?.number == v.number {
                sales[t.id]?.invoice?.voidedAt = at
                sales[t.id]?.invoice?.voidReason = v.reason
            }

        case .ticketClosed(let c):
            guard var t = tickets[c.ticketId] else { return }
            guard t.status == .open else {
                if t.status == .closed {
                    conflict(e, .doubleClose, t.id, "\(t.number) 在兩台都結了帳（\(c.sale.total.formatted)），請確認有沒有重複收款")
                }
                return
            }
            t.status = .closed
            t.closedAt = at
            t.closedBy = staff
            t.closedDeviceId = e.deviceId
            tickets[t.id] = t
            sales[t.id] = c.sale
            if t.orderType == .dineIn { needsCleaning.formUnion(t.tableIds) }
            logAccount(e, AccountRules.moves(sale: c.sale))

        case .ticketVoided(let v):
            guard var t = tickets[v.ticketId], t.isOpen else { return }
            t.status = .voided
            t.voidInfo = VoidInfo(reason: v.reason, by: staff, authorizedBy: v.authorizedBy, at: at, wasSent: t.lines.contains { $0.isSent })
            t.closedAt = at
            t.closedBy = staff
            tickets[t.id] = t

        case .saleRefunded(let r):
            guard var t = tickets[r.ticketId], !t.refunds.contains(where: { $0.id == r.refund.id }) else { return }
            t.refunds.append(r.refund)
            tickets[t.id] = t
            if let a = r.allowance { allowances.append(a) }
            if let sale = sales[t.id] { logAccount(e, AccountRules.moves(refund: r.refund, sale: sale)) }

        case .tableCleaned(let c):
            needsCleaning.remove(c.tableId)

        case .shiftOpened(let o):
            guard shifts[o.shiftId] == nil else { return }
            shifts[o.shiftId] = Shift(id: o.shiftId, deviceId: e.deviceId, openedAt: at, openedBy: staff, openingCash: o.openingCash, businessDate: o.businessDate)

        case .cashMoved(let m):
            guard var s = shifts[m.shiftId], !s.moves.contains(where: { $0.id == m.move.id }) else { return }
            s.moves.append(m.move)
            shifts[s.id] = s

        case .shiftClosed(let c):
            guard var s = shifts[c.shiftId], s.isOpen else { return }
            s.closedAt = at
            s.closedBy = staff
            s.counted = c.counted
            s.expectedAtClose = c.expected
            s.note = c.note
            shifts[s.id] = s

        case .clockedIn(let r):
            guard !attendance.contains(where: { $0.staffId == r.staffId && $0.outAt == nil }) else { return }
            attendance.append(ClockEntry(staffId: r.staffId, inAt: at))

        case .clockedOut(let r):
            if let i = attendance.lastIndex(where: { $0.staffId == r.staffId && $0.outAt == nil }) {
                attendance[i].outAt = at
            }

        case .itemAvailability(let a):
            itemAvailability[a.itemId] = a.available

        case .saleExchanged(let x):
            guard var t = tickets[x.ticketId], t.status == .closed else { return }
            var swaps = t.swaps ?? []
            for sw in x.swaps where !swaps.contains(sw) { swaps.append(sw) }
            t.swaps = swaps
            tickets[t.id] = t

        case .checkedIn(let c):
            guard checkIns[c.checkIn.id] == nil else { return }
            var ci = c.checkIn
            ci.at = at
            ci.by = staff
            ci.voidedAt = nil
            checkIns[ci.id] = ci
            logAccount(e, AccountRules.moves(checkIn: ci))

        case .checkInVoided(let v):
            guard var ci = checkIns[v.checkInId], !ci.isVoided else { return }
            ci.voidedAt = at
            ci.note = ci.note.isEmpty ? v.reason : ci.note + "；" + v.reason
            checkIns[ci.id] = ci
            logAccount(e, AccountRules.moves(checkInVoided: ci, at: at))

        case .unknown:
            break
        }
    }

    private mutating func logAccount(_ e: POSEvent, _ moves: [AccountMove]) {
        guard !moves.isEmpty, !accountLog.contains(where: { $0.eventId == e.id }) else { return }
        accountLog.append(AccountEntry(eventId: e.id, moves: moves))
    }

    private mutating func updateLine(_ ticketId: String, _ lineId: String, allowClosed: Bool = false, _ change: (inout TicketLine) -> Void) {
        guard var t = tickets[ticketId], allowClosed || t.isOpen, let i = t.lines.firstIndex(where: { $0.id == lineId }) else { return }
        guard t.lines[i].isActive else { return }
        change(&t.lines[i])
        tickets[ticketId] = t
    }

    private mutating func conflict(_ e: POSEvent, _ kind: Conflict.Kind, _ ticketId: String?, _ message: String) {
        guard !conflicts.contains(where: { $0.id == e.id }) else { return }
        conflicts.append(Conflict(id: e.id, kind: kind, ticketId: ticketId, deviceId: e.deviceId, message: message, at: e.date))
    }

    // MARK: - 查詢

    public var openTickets: [Ticket] {
        tickets.values.filter(\.isOpen).sorted { ($0.openedAt, $0.number) < ($1.openedAt, $1.number) }
    }

    public func openTickets(at tableId: String) -> [Ticket] {
        openTickets.filter { $0.tableIds.contains(tableId) }
    }

    /// 桌況。reservedSoon：30 分鐘內有預約的桌子（訂位在後台，不在事件裡）
    public func status(of tableId: String, reservedSoon: Set<String> = []) -> TableStatus {
        let open = openTickets(at: tableId)
        if !open.isEmpty {
            if open.contains(where: { $0.billPrintedAt != nil }) { return .billing }
            return open.contains(where: { !$0.activeLines.isEmpty }) ? .ordering : .seated
        }
        if needsCleaning.contains(tableId) { return .needsCleaning }
        if reservedSoon.contains(tableId) { return .reserved }
        return .available
    }

    public func isAvailable(_ item: MenuItem) -> Bool {
        itemAvailability[item.id] ?? item.isAvailable
    }

    public func openShift(on deviceId: String) -> Shift? {
        shifts.values.filter { $0.deviceId == deviceId && $0.isOpen }.max { $0.openedAt < $1.openedAt }
    }

    public var clockedIn: [String] {
        attendance.filter { $0.outAt == nil }.map(\.staffId)
    }

    public var unresolvedConflicts: [Conflict] { conflicts.filter { !$0.resolved } }

    /// 下一個單號：這台的字母＋今天的流水號（A001、A002…）。每台字母不同，所以斷網也不會重號
    public func nextTicketNumber(deviceCode: String, businessDate: String) -> String {
        let used = tickets.values
            .filter { $0.businessDate == businessDate && $0.number.hasPrefix(deviceCode) }
            .compactMap { Int($0.number.dropFirst(deviceCode.count)) }
        let next = (used.max() ?? 0) + 1
        return deviceCode + (next < 1000 ? String(format: "%03d", next) : String(next))
    }

    /// 這一班錢櫃裡應該有多少現金：零用金＋現金收款−找零退差額−現金退款＋存入−取出
    public func expectedCash(shiftId: String) -> Money {
        guard let s = shifts[shiftId] else { return .zero }
        var cash = s.openingCash + Money.sum(s.moves.map(\.signed))
        for t in tickets.values {
            for p in t.payments where p.shiftId == shiftId {
                cash += p.drawerDelta
            }
            for r in t.refunds where r.shiftId == shiftId && r.tender == .cash {
                cash -= r.amount
            }
        }
        return cash
    }

    // MARK: 會員帳戶、報到

    /// 這個會員在這台記了、但後台的餘額還沒算進去的帳戶變動（included：後台說它算過的事件 id）
    public func pendingAccountMoves(memberId: String, excluding included: Set<String>) -> [AccountMove] {
        accountLog.filter { !included.contains($0.eventId) }.flatMap { $0.moves.filter { $0.memberId == memberId } }
    }

    /// 現在的帳戶：後台查到的＋這台還沒算進去的
    public func account(memberId: String, server: MemberAccount, included: Set<String>) -> MemberAccount {
        server.applying(pendingAccountMoves(memberId: memberId, excluding: included))
    }

    /// 某個營業日的報到（取消的不算）
    public func checkIns(businessDate: String, cutoffHour: Int = 4) -> [CheckIn] {
        checkIns.values
            .filter { !$0.isVoided && TaipeiTime.businessDate($0.at, cutoffHour: cutoffHour) == businessDate }
            .sorted { $0.at > $1.at }
    }

    /// 這個會員今天報到過了沒（同一天第二次報到要提醒，不擋）
    public func lastCheckIn(memberId: String) -> CheckIn? {
        checkIns.values.filter { !$0.isVoided && $0.member.id == memberId }.max { $0.at < $1.at }
    }

    /// 已結帳的單（依結帳時間）
    public func closedSales(businessDate: String? = nil) -> [SaleRecord] {
        sales.values
            .filter { businessDate == nil || $0.businessDate == businessDate }
            .sorted { $0.closedAt < $1.closedAt }
    }
}
