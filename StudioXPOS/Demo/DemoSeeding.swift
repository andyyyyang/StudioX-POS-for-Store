import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 示範資料的共用工具：今天的單照收銀台一樣的事件記進去（報表、會員帳戶、業績都從事件算，和真的一樣），
// 加上幾個做假資料用的小函式（發票號碼段、人員、條碼、會員身上的卡）。

/// 收款的一筆（金額 nil＝剩下的全部）
struct DemoPay {
    var tender: Tender
    var amount: Money?

    init(_ tender: Tender, _ amount: Money? = nil) {
        self.tender = tender
        self.amount = amount
    }
}

/// 把示範的「今天」記進日誌：開班 → 開單 → 加品項 → 收款 → 開發票 → 結帳、報到
struct DemoSeeder {
    let ledger: Ledger
    let bootstrap: Bootstrap
    let businessDate: String
    let shiftId = "demo-shift"

    init(ledger: Ledger, bootstrap: Bootstrap, now: Date) {
        self.ledger = ledger
        self.bootstrap = bootstrap
        businessDate = TaipeiTime.businessDate(now, cutoffHour: bootstrap.store.businessDayCutoffHour)
    }

    var catalog: Catalog { bootstrap.catalog }

    func staff(_ id: String?) -> StaffMember? {
        guard let id else { return nil }
        return bootstrap.staff.first { $0.id == id }
    }

    /// 開班（零用金）、上班打卡
    func openShift(by managerId: String, clockIn ids: [String], cash: Money, at: Date) throws {
        try ledger.record(.shiftOpened(ShiftOpened(shiftId: shiftId, openingCash: cash, businessDate: businessDate)), staffId: managerId, at: at)
        try ledger.record(ids.map { EventBody.clockedIn(StaffRef(staffId: $0)) }, staffId: managerId, at: at.addingTimeInterval(60))
    }

    /// 單子上的一行（照菜單抄一份，和收銀台加品項一樣）：
    /// staffId 是做這一項服務的人（設計師、教練）；seller 是整張單的銷售人員（算抽成用）；redeem 是用客人的課程卡抵
    func line(_ itemId: String, _ quantity: Int = 1, variant variantId: String? = nil, optionIds: [String] = [], staffId: String? = nil,
              assistantId: String? = nil, seller: String? = nil, redeem: PassRedemption? = nil, price: Money? = nil, note: String = "",
              by: String, at: Date) -> TicketLine {
        let id = UUID().uuidString.lowercased()
        if let l = DemoLines.make(catalog, staff: bootstrap.staff, id: id, itemId: itemId, quantity: quantity, variantId: variantId,
                                  optionIds: optionIds, staffId: staffId, assistantId: assistantId, seller: seller, redeem: redeem,
                                  price: price, note: note, by: by, at: at) {
            return l
        }
        // 示範資料打錯字也不要讓 App 當掉：照名字加一行
        return TicketLine(id: id, itemId: nil, name: itemId, unitPrice: price ?? .zero, quantity: max(quantity, 1), addedAt: at, addedBy: by)
    }

    /// 開一張單、加品項（還沒結帳）
    func open(_ ticketId: String, at: Date, by: String, mode: ServiceMode, member: MemberRef? = nil, customerName: String? = nil,
              salespersonId: String? = nil, appointmentId: String? = nil, lines: [TicketLine]) throws {
        let type = mode.defaultOrderType
        let number = ledger.state.nextTicketNumber(deviceCode: bootstrap.device.code, businessDate: businessDate)
        let opened = TicketOpened(ticketId: ticketId, number: number, orderType: type, serviceChargeBps: bootstrap.store.serviceChargeBps(for: type),
                                  businessDate: businessDate, customerName: customerName, serviceMode: mode, member: member,
                                  salespersonId: salespersonId, appointmentId: appointmentId)
        try ledger.record(.ticketOpened(opened), staffId: by, at: at)
        if !lines.isEmpty {
            try ledger.record(.linesAdded(LinesAdded(ticketId: ticketId, lines: lines)), staffId: by, at: at.addingTimeInterval(45))
        }
    }

    /// 整張單打折（會員折扣）
    func discount(_ ticketId: String, _ d: Discount, by: String, at: Date) throws {
        try ledger.record(.ticketUpdated(TicketUpdated(ticketId: ticketId, discount: d)), staffId: by, at: at)
    }

    /// 收款（照順序，最後一筆收剩下的）→ 開發票（用儲值金付的、用卡抵的不重開）→ 結帳
    func close(_ ticketId: String, at: Date, by: String, pay: [DemoPay], buyer: InvoiceBuyer? = nil) throws {
        if let buyer, buyer != .paper {
            try ledger.record(.ticketUpdated(TicketUpdated(ticketId: ticketId, invoiceBuyer: buyer)), staffId: by, at: at.addingTimeInterval(-30))
        }
        guard let t = ledger.state.tickets[ticketId], t.isOpen else { return }
        var left = t.totals.balance
        for (i, p) in pay.enumerated() where left.cents > 0 {
            let amount = min(p.amount ?? left, left)
            guard amount.cents > 0 else { continue }
            let id = "\(ticketId)-pay\(i + 1)"
            let payment: Payment
            switch p.tender {
            case .cash:
                let tendered = Money(dollars: ((amount.dollars + 99) / 100) * 100)
                payment = Payment.cash(id: id, tendered: tendered, due: amount, at: at, by: by, shiftId: shiftId)
            case .card:
                payment = Payment(id: id, tender: .card, amount: amount, cardLast4: String(format: "%04d", (ticketId.count * 373 + i * 91) % 10_000),
                                  at: at, by: by, shiftId: shiftId)
            case .prepaid:
                payment = Payment(id: id, tender: .prepaid, amount: amount, reference: t.member?.maskedPhone, at: at, by: by, shiftId: shiftId)
            default:
                payment = Payment(id: id, tender: p.tender, amount: amount, reference: String(format: "%06d", (ticketId.count * 7_919 + i * 131) % 1_000_000),
                                  at: at, by: by, shiftId: shiftId)
            }
            try ledger.record(.paymentAdded(PaymentAdded(ticketId: ticketId, payment: payment)), staffId: by, at: at)
            left -= amount
        }
        guard let paid = ledger.state.tickets[ticketId], paid.totals.isPaidInFull else { return }
        let closeAt = at.addingTimeInterval(5)
        let prepaid = bootstrap.store.prepaidInvoicing
        var invoice: EInvoice? = nil
        if bootstrap.features.invoice, bootstrap.invoice.enabled, InvoiceBuilder.coverage(for: paid, prepaid: prepaid).amount.cents > 0 {
            // 號碼段不夠（剛換期）就先不開：示範一定要打得開
            invoice = try? InvoiceBuilder.issue(ticket: paid, settings: bootstrap.invoice,
                                                allocator: InvoiceAllocator(rolls: bootstrap.invoice.rolls, state: ledger.state),
                                                deviceId: bootstrap.device.id, at: closeAt, prepaid: prepaid)
        }
        var closing = paid
        closing.invoice = invoice?.stamp
        let sale = SaleRecord(ticket: closing, closedOn: bootstrap.device.id, shiftId: shiftId, closedAt: closeAt, closedBy: by,
                              staffName: staff(by)?.name ?? "", floor: bootstrap.floor)
        var bodies: [EventBody] = []
        if let invoice { bodies.append(.invoiceIssued(InvoiceIssued(ticketId: ticketId, invoice: invoice))) }
        bodies.append(.ticketClosed(TicketClosed(ticketId: ticketId, sale: sale)))
        try ledger.record(bodies, staffId: by, at: closeAt)
    }

    /// 照後台歷史記一天（昨天）：開單、加品項、折扣與發票類型、收款、開發票（號碼段不夠就不開）、結帳；作廢的單、退款、報到
    func replay(_ day: DemoHistory.Day) throws {
        for t in day.tickets {
            let opened = TicketOpened(ticketId: t.id, number: t.number, orderType: t.orderType, tableIds: t.tableIds, guests: t.guests,
                                      serviceChargeBps: t.serviceChargeBps, businessDate: t.businessDate, customerName: t.customerName,
                                      serviceMode: t.serviceMode, member: t.member, salespersonId: t.salespersonId, appointmentId: t.appointmentId)
            var bodies: [EventBody] = [.ticketOpened(opened), .linesAdded(LinesAdded(ticketId: t.id, lines: t.lines))]
            if t.discount != nil || t.invoiceBuyer != .paper || t.queueNumber != nil {
                // 叫號的號碼（黃毛丫頭）：結帳的紀錄也帶著
                bodies.append(.ticketUpdated(TicketUpdated(ticketId: t.id, discount: t.discount, invoiceBuyer: t.invoiceBuyer == .paper ? nil : t.invoiceBuyer,
                                                           queueNumber: t.queueNumber)))
            }
            try ledger.record(bodies, staffId: t.openedBy, at: t.openedAt)
            let by = t.closedBy ?? t.openedBy
            let closeAt = t.closedAt ?? t.openedAt
            if t.status == .voided {
                try ledger.record(.ticketVoided(TicketVoided(ticketId: t.id, reason: t.voidInfo?.reason ?? "點錯了")), staffId: by, at: closeAt)
                continue
            }
            try ledger.record(t.payments.map { EventBody.paymentAdded(PaymentAdded(ticketId: t.id, payment: $0)) }, staffId: by, at: closeAt)
            guard let paid = ledger.state.tickets[t.id], paid.isOpen, paid.totals.isPaidInFull else { continue }
            var invoice: EInvoice? = nil
            if t.invoice != nil, bootstrap.features.invoice, bootstrap.invoice.enabled {
                invoice = try? InvoiceBuilder.issue(ticket: paid, settings: bootstrap.invoice,
                                                    allocator: InvoiceAllocator(rolls: bootstrap.invoice.rolls, state: ledger.state),
                                                    deviceId: bootstrap.device.id, at: closeAt, prepaid: bootstrap.store.prepaidInvoicing)
            }
            var closing = paid
            closing.invoice = invoice?.stamp
            let sale = SaleRecord(ticket: closing, closedOn: bootstrap.device.id, shiftId: nil, closedAt: closeAt, closedBy: by,
                                  staffName: staff(by)?.name ?? "", floor: bootstrap.floor)
            var closingBodies: [EventBody] = []
            if let invoice { closingBodies.append(.invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: invoice))) }
            closingBodies.append(.ticketClosed(TicketClosed(ticketId: t.id, sale: sale)))
            // 內用的桌子收好了（不然今天一打開就一堆「待清」）
            if t.orderType == .dineIn {
                closingBodies += t.tableIds.map { EventBody.tableCleaned(TableRef(tableId: $0)) }
            }
            try ledger.record(closingBodies, staffId: by, at: closeAt)
        }
        for r in day.refunds {
            var bodies: [EventBody] = []
            if r.refund.invoiceAction == .void, let number = ledger.state.tickets[r.ticketId]?.invoice?.number {
                bodies.append(.invoiceVoided(InvoiceVoided(ticketId: r.ticketId, number: number, reason: r.refund.reason, authorizedBy: r.refund.authorizedBy)))
            }
            bodies.append(.saleRefunded(SaleRefunded(ticketId: r.ticketId, refund: r.refund)))
            try ledger.record(bodies, staffId: r.refund.by, at: r.refund.at)
        }
        // 報到的時間是事件的時間：一筆一筆記
        for c in day.checkIns {
            try ledger.record(.checkedIn(CheckedIn(checkIn: c)), staffId: c.by, at: c.at)
        }
    }

    /// 入場報到（健身房）：用哪一張卡（次數卡扣 1 次、期間會籍不扣）
    func checkIn(_ id: String, member: MemberRef, passId: String?, passName: String?, perVisit: Bool, sessionId: String? = nil,
                 reservationId: String? = nil, note: String = "", by: String, at: Date) throws {
        let c = CheckIn(id: id, member: member, passId: passId, passName: passName, uses: passId != nil && perVisit ? 1 : 0,
                        sessionId: sessionId, reservationId: reservationId, note: note, at: at, by: by)
        try ledger.record(.checkedIn(CheckedIn(checkIn: c)), staffId: by, at: at)
    }
}

/// 照菜單做一行（示範的今天、後台的歷史共用；不綁主執行緒）
nonisolated enum DemoLines {
    static func make(_ catalog: Catalog, staff: [StaffMember], id: String, itemId: String, quantity: Int = 1, variantId: String? = nil,
                     optionIds: [String] = [], staffId: String? = nil, assistantId: String? = nil, seller: String? = nil,
                     redeem: PassRedemption? = nil, price: Money? = nil, note: String = "", by: String, at: Date,
                     served: Bool = false) -> TicketLine? {
        guard let item = catalog.item(itemId) else { return nil }
        let variant = item.variant(variantId)
        let modifiers: [AppliedModifier] = catalog.groups(for: item).flatMap { g in
            g.options.filter { optionIds.contains($0.id) }.map {
                AppliedModifier(groupId: g.id, groupName: g.name, optionId: $0.id, name: $0.name, priceDelta: $0.priceDelta)
            }
        }
        let unit = price ?? item.price(of: variant)
        let commissionOwner = staffId ?? seller ?? by
        let ownerBps = staff.first { $0.id == commissionOwner }?.commissionBps
        let credit: Money? = item.itemKind == .storedValue ? (item.openPrice ? unit : (item.credit ?? item.price)) : nil
        return TicketLine(
            id: id, itemId: item.id, name: item.name, categoryId: item.categoryId,
            categoryName: catalog.category(item.categoryId)?.name, unitPrice: unit, modifiers: modifiers, quantity: max(quantity, 1), note: note,
            station: catalog.station(for: item), taxKind: item.taxKind, addedAt: at, addedBy: by,
            sentAt: served ? at.addingTimeInterval(60) : nil, kitchen: served ? .served : .new,
            productId: item.productId, variantId: variant?.productVariantId ?? item.variantId,
            kind: item.kind, skuId: variant?.id, variantName: variant?.label, staffId: staffId, assistantId: assistantId,
            durationMinutes: item.durationMinutes, pass: item.pass, credit: credit, redeem: redeem,
            commissionBps: item.commissionBps ?? ownerBps
        )
    }

    /// 隨便選加料（必選的照預設或隨機一個；選填的偶爾加一個）
    static func randomOptions(_ catalog: Catalog, for item: MenuItem, rng: inout SeededRandom) -> [String] {
        var out: [String] = []
        for g in catalog.groups(for: item) {
            let options = g.options.filter(\.isAvailable)
            if g.minSelect > 0 {
                if let d = options.first(where: \.isDefault), rng.chance(55) {
                    out.append(d.id)
                } else if let o = rng.pick(options) {
                    out.append(o.id)
                }
            } else if rng.chance(25), let o = rng.pick(options) {
                out.append(o.id)
            }
        }
        return out
    }
}

// MARK: - 做假資料用的小函式

extension DemoStore {
    /// 這家示範的發票設定：上一期、這一期、下一期各一段號碼（剛換期時單子會落在上一期）
    static func demoInvoice(taxId: String, name: String, address: String, now: Date, tracks: (String, String, String)) -> InvoiceSettings {
        let period = InvoicePeriod(date: now)
        return InvoiceSettings(
            enabled: true, sellerTaxId: taxId, sellerName: name, sellerAddress: address, qrKey: "6E8B2A1C4D5F70819A2B3C4D5E6F7081",
            rolls: [
                InvoiceRoll(id: "demo-roll-0", period: period.previous.code, track: tracks.0, start: 3_345_600, end: 3_345_799),
                InvoiceRoll(id: "demo-roll-1", period: period.code, track: tracks.1, start: 13_345_600, end: 13_345_899),
                InvoiceRoll(id: "demo-roll-2", period: period.next.code, track: tracks.2, start: 23_345_600, end: 23_345_649),
            ]
        )
    }

    /// 人員（職稱、排不排預約、抽成）：PIN 和晨麥手作一樣的雜湊方式
    static func person(_ id: String, _ name: String, _ role: StaffRole, _ pin: String, _ swatch: Swatch, title: String,
                       bookable: Bool = false, commissionBps: Int? = nil) -> StaffMember {
        var s = member(id, name, role, pin, swatch)
        s.title = title
        s.bookable = bookable
        s.commissionBps = commissionBps
        return s
    }

    /// EAN-13：前 12 碼＋檢查碼（吊牌、商品條碼）
    nonisolated static func ean13(_ twelve: String) -> String {
        let digits = twelve.compactMap(\.wholeNumberValue)
        guard digits.count == 12 else { return twelve }
        var sum = 0
        for (i, d) in digits.enumerated() { sum += i % 2 == 0 ? d : d * 3 }
        return twelve + String((10 - sum % 10) % 10)
    }

    /// 往前取整到 n 分鐘（預約表的格子；台北是整點時區，UTC 對齊就是台北對齊）
    static func slot(_ date: Date, minutes: Int) -> Date {
        let size = Double(max(minutes, 1) * 60)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / size).rounded(.down) * size)
    }

    /// 營業日那天（台北）的某個鐘點：課表的 07:00、12:30
    static func clock(_ hour: Int, _ minute: Int, on now: Date, cutoffHour: Int) -> Date {
        let day = TaipeiTime.calendar.startOfDay(for: now.addingTimeInterval(TimeInterval(-cutoffHour * 3600)))
        return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    /// 這個月的某一天當生日（MM-DD）：不管哪天打開示範，都有一位當月壽星
    static func birthdayThisMonth(_ day: Int, now: Date) -> String {
        let month = TaipeiTime.components(now).month ?? 1
        return String(format: "%02d-%02d", month, min(max(day, 1), 28))
    }

    static func daysAgo(_ days: Double, _ now: Date) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// 會員身上已經有的卡（後台記的）：幾天前買的、還剩幾次
    static func heldPass(_ id: String, _ item: MenuItem?, boughtDaysAgo: Double, remaining: Int? = nil, now: Date,
                         status: MemberPass.Status = .active) -> MemberPass? {
        guard let item, let spec = item.pass else { return nil }
        let start = daysAgo(boughtDaysAgo, now)
        let expires = spec.validDays.map { TaipeiTime.endOfDay(start, plusDays: $0) }
        let left: Int? = spec.kind == .visits ? (remaining ?? spec.visits) : nil
        var resolved = status
        if resolved == .active, spec.kind == .visits, (left ?? 0) <= 0 { resolved = .usedUp }
        if resolved == .active, let expires, expires <= now { resolved = .expired }
        return MemberPass(id: id, name: item.name, spec: spec, remaining: left, startsAt: start, expiresAt: expires,
                          ticketId: "demo-hist-\(id)", unitValue: AccountRules.unitValue(net: item.price, quantity: 1, spec: spec), status: resolved)
    }

    /// 以前的一次消費（後台整理的「最近幾次」）
    static func visit(_ id: String, _ number: String, daysAgo days: Double, now: Date, total: Int, items: [String], staff: [String] = [],
                      note: String? = nil) -> MemberVisit {
        MemberVisit(ticketId: "demo-hist-\(id)", number: number, at: daysAgo(days, now), total: Money(dollars: total), items: items,
                    staffNames: staff, note: note)
    }
}
