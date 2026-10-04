import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範的「後台歷史」：開幕（90 天前）到昨天，每一天的結帳、退款、作廢、報到。
///
/// 照日期決定（同一天每次打開都一樣）、週末比較忙、開幕初期少一點。DemoAPI.history(date:) 從這裡拿；
/// 昨天的那一批也照樣記進這台（今天、昨天的報表與訂單是從這台的事件算的）。
/// 美業、健身的歷史客人是另外編的（不是查得到的那幾位會員）：昨天的單記進這台時才不會動到他們的儲值金與課程卡。
nonisolated struct DemoHistory: Sendable {
    /// 示範的店開了幾天（更早的日子沒有資料）
    static let openedDays = 90

    let base: Bootstrap
    /// 示範打開那天（營業日）
    let today: String
    /// 熟客：查得到的會員（只有沒有儲值、課程卡的店才放進歷史）
    let regulars: [MemberRef]

    init(base: Bootstrap, regulars: [MemberRef] = []) {
        self.base = base
        self.today = TaipeiTime.businessDate(base.serverTime, cutoffHour: base.store.businessDayCutoffHour)
        self.regulars = regulars
    }

    /// 熟客的規則：店裡有賣儲值或課程卡就不用查得到的會員（昨天的單會改到他們的帳戶）
    static func regulars(_ members: [Member], catalog: Catalog) -> [MemberRef] {
        catalog.items.contains { $0.itemKind.needsMember } ? [] : members.map(\.ref)
    }

    /// 一天（變成 DayHistory 之前；昨天要照這個記進這台）
    nonisolated struct Day: Sendable {
        var date: String
        /// 結帳的、作廢的單（照開單時間）
        var tickets: [Ticket] = []
        var sales: [SaleRecord] = []
        var refunds: [TicketRefund] = []
        var checkIns: [CheckIn] = []
        var invoiceNumbers: [String] = []
        var voidedInvoiceNumbers: [String] = []

        var history: DayHistory {
            let voided = tickets.filter { $0.status == .voided }.map { t in
                VoidedTicketSummary(ticketId: t.id, number: t.number, items: t.itemCount, amount: t.totals.total, reason: t.voidInfo?.reason ?? "")
            }
            return DayHistory(businessDate: date, sales: sales, refunds: refunds, voidedTickets: voided, invoiceNumbers: invoiceNumbers,
                              voidedInvoiceNumbers: voidedInvoiceNumbers, checkIns: checkIns.count)
        }
    }

    /// 開幕前、今天、以後都是空的
    func history(_ date: String) -> DayHistory {
        day(date)?.history ?? DayHistory(businessDate: date)
    }

    // MARK: - 一天

    /// 還沒結帳的單（排好時間再一起編號、結帳）
    nonisolated private struct Draft {
        var at: Date
        var ticket: Ticket
        /// 先用儲值金付多少
        var prepaid: Money? = nil
        /// 剩下的用什麼付
        var tender: Tender = .cash
        /// 作廢（沒結帳）的原因
        var voidReason: String? = nil
    }

    nonisolated private enum Kind { case cafe, apparel, salon, fitness }

    private var kind: Kind {
        switch base.store.defaultServiceMode {
        case .apparel, .retail: .apparel
        case .salon: .salon
        case .fitness: .fitness
        case .tableService, .counter, .cafe: .cafe
        }
    }

    func day(_ date: String) -> Day? {
        guard let offset = Self.offset(from: today, to: date), offset < 0, offset >= -Self.openedDays,
              let midnight = Self.midnight(date) else { return nil }
        let cal = TaipeiTime.calendar
        let weekday = cal.component(.weekday, from: midnight.addingTimeInterval(12 * 3600))  // 1 = 星期日
        let weekend = weekday == 1 || weekday == 7
        let friday = weekday == 6
        // 開幕初期少一點，越近越多
        let ramp = 0.72 + 0.28 * Double(Self.openedDays + offset) / Double(Self.openedDays)
        var rng = SeededRandom(seed: Self.seed("\(base.version)|\(date)"))

        let hours: (open: Double, close: Double)
        let counts: (weekday: Int, friday: Int, weekend: Int)
        switch kind {
        case .cafe: hours = (8, 17.5); counts = (40, 48, 62)
        case .apparel: hours = (12, 21.5); counts = (13, 17, 26)
        case .salon: hours = (10, 20); counts = (15, 19, 25)
        case .fitness: hours = (6.5, 22.5); counts = (30, 28, 24)
        }
        let target = weekend ? counts.weekend : (friday ? counts.friday : counts.weekday)
        let n = max(Int((Double(target) * ramp).rounded()) + rng.next(7) - 3, 3)

        var drafts: [Draft] = []
        for i in 0..<n {
            let minutes = hours.open * 60 + Double(rng.next(Int((hours.close - hours.open) * 60)))
            let at = midnight.addingTimeInterval(minutes * 60)
            let id = "demo-h-\(date)-\(i)"
            let draft: Draft?
            switch kind {
            case .cafe: draft = cafe(id, date: date, at: at, rng: &rng)
            case .apparel: draft = apparel(id, date: date, at: at, rng: &rng)
            case .salon: draft = salon(id, date: date, at: at, rng: &rng)
            case .fitness: draft = fitness(id, date: date, at: at, rng: &rng)
            }
            if let draft { drafts.append(draft) }
        }
        // 偶爾一張作廢的
        if rng.chance(kind == .cafe ? 35 : 20) {
            let minutes = hours.open * 60 + Double(rng.next(Int((hours.close - hours.open) * 60)))
            let at = midnight.addingTimeInterval(minutes * 60)
            let id = "demo-h-\(date)-v"
            let made: Draft? = switch kind {
            case .cafe: cafe(id, date: date, at: at, rng: &rng)
            case .apparel: apparel(id, date: date, at: at, rng: &rng)
            case .salon: salon(id, date: date, at: at, rng: &rng)
            case .fitness: fitness(id, date: date, at: at, rng: &rng)
            }
            if var v = made, !v.ticket.activeLines.isEmpty {
                v.voidReason = rng.pick(["客人取消", "點錯了", "重複開單"]) ?? "客人取消"
                drafts.append(v)
            }
        }
        drafts.sort { $0.at < $1.at }

        var out = Day(date: date)
        let dayIndex = Self.openedDays + offset
        for (i, d) in drafts.enumerated() {
            finish(d, number: "\(base.device.code)\(String(format: "%03d", i + 1))", index: i, dayIndex: dayIndex, rng: &rng, into: &out)
        }
        addRefund(to: &out, kind: kind, rng: &rng)
        if kind == .fitness {
            out.checkIns = checkIns(date: date, midnight: midnight, weekday: weekday, ramp: ramp, rng: &rng)
        }
        return out
    }

    // MARK: - 結帳

    private func finish(_ d: Draft, number: String, index: Int, dayIndex: Int, rng: inout SeededRandom, into day: inout Day) {
        var t = d.ticket
        t.number = number
        let cashier = t.openedBy
        if let reason = d.voidReason {
            let at = d.at.addingTimeInterval(Double(3 + rng.next(10)) * 60)
            t.status = .voided
            t.voidInfo = VoidInfo(reason: reason, by: cashier, at: at, wasSent: false)
            t.closedAt = at
            t.closedBy = cashier
            day.tickets.append(t)
            return
        }
        let closeAt = d.at.addingTimeInterval(Double(closeMinutes(rng: &rng)) * 60)
        var left = t.totals.amountDue
        var payments: [Payment] = []
        if let pre = d.prepaid, pre.cents > 0, left.cents > 0 {
            let amount = min(pre, left)
            payments.append(Payment(id: "\(t.id)-p1", tender: .prepaid, amount: amount, reference: t.member?.maskedPhone, at: closeAt, by: cashier))
            left -= amount
        }
        if left.cents > 0 {
            let id = "\(t.id)-p\(payments.count + 1)"
            switch d.tender {
            case .cash:
                let exact = rng.chance(30)
                let step = left.dollars >= 1_000 ? 1_000 : (left.dollars >= 300 ? 500 : 100)
                let tendered = exact ? left : Money(dollars: ((left.dollars + step - 1) / step) * step)
                payments.append(Payment.cash(id: id, tendered: tendered, due: left, at: closeAt, by: cashier, shiftId: nil))
            case .card:
                payments.append(Payment(id: id, tender: .card, amount: left, cardLast4: String(format: "%04d", rng.next(10_000)), at: closeAt, by: cashier))
            default:
                payments.append(Payment(id: id, tender: d.tender, amount: left, reference: String(format: "%06d", rng.next(1_000_000)), at: closeAt, by: cashier))
            }
        }
        t.payments = payments
        if base.features.invoice, base.invoice.enabled {
            let amount = InvoiceBuilder.coverage(for: t, prepaid: base.store.prepaidInvoicing).amount
            if amount.cents > 0 {
                let period = InvoicePeriod(date: closeAt)
                let number = Self.track(period.code) + String(format: "%08d", 40_000_000 + dayIndex * 300 + index)
                t.invoice = InvoiceStamp(number: number, randomCode: String(format: "%04d", rng.next(10_000)), period: period.code, issuedAt: closeAt,
                                         buyer: t.invoiceBuyer, total: amount)
                day.invoiceNumbers.append(number)
            }
        }
        t.status = .closed
        t.closedAt = closeAt
        t.closedBy = cashier
        t.closedDeviceId = base.device.id
        let sale = SaleRecord(ticket: t, closedOn: base.device.id, shiftId: nil, closedAt: closeAt, closedBy: cashier,
                              staffName: staffName(cashier), floor: base.floor)
        day.tickets.append(t)
        day.sales.append(sale)
    }

    private func closeMinutes(rng: inout SeededRandom) -> Int {
        switch kind {
        case .cafe: 25 + rng.next(50)
        case .apparel: 4 + rng.next(10)
        case .salon: 50 + rng.next(100)
        case .fitness: 1 + rng.next(4)
        }
    }

    /// 偶爾退一張（整張退＝發票作廢；退一件＝折讓）；動到會員帳戶的單不退（儲值、課程卡、儲值金付的）
    private func addRefund(to day: inout Day, kind: Kind, rng: inout SeededRandom) {
        guard rng.chance(kind == .cafe ? 12 : 22) else { return }
        let candidates = day.sales.filter { s in
            s.total.cents > 0 && !s.payments.contains { $0.tender == .prepaid }
                && !s.lines.contains { $0.redeem != nil || $0.kind == .pass || $0.kind == .storedValue }
        }
        guard let sale = rng.pick(candidates) else { return }
        let manager = base.staff.first { $0.role == .manager }?.id ?? sale.closedBy
        let tender = sale.payments.first?.tender ?? .cash
        let at = sale.closedAt.addingTimeInterval(Double(20 + rng.next(90)) * 60)
        let reasons: [String] = switch kind {
        case .cafe: ["餐點送錯", "客人不滿意", "重複收款"]
        case .apparel: ["尺寸不合", "商品瑕疵", "客人改變心意"]
        case .salon: ["客人不滿意", "商品過敏", "重複刷卡"]
        case .fitness: ["重複刷卡", "商品瑕疵", "客人改變心意"]
        }
        let reason = rng.pick(reasons) ?? "客人不滿意"
        let refund: Refund
        if rng.chance(45) || sale.lines.count == 1 && sale.lines[0].quantity == 1 {
            let action: InvoiceRefundAction = sale.invoice != nil ? .void : .none
            refund = Refund(id: "\(sale.ticketId)-r1", amount: sale.total, tender: tender, reason: reason, invoiceAction: action, at: at,
                            by: manager, authorizedBy: manager)
            if action == .void, let number = sale.invoice?.number { day.voidedInvoiceNumbers.append(number) }
        } else {
            guard let line = sale.lines.first(where: { $0.net.cents > 0 }) else { return }
            let amount = sale.refundAmount(lineId: line.lineId, quantity: 1)
            guard amount.cents > 0 else { return }
            let action: InvoiceRefundAction = sale.invoice != nil ? .allowance : .none
            let c = TaipeiTime.components(at)
            let stamp = String(format: "%02d%02d%02d%02d%02d%02d", (c.year ?? 2026) % 100, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            refund = Refund(id: "\(sale.ticketId)-r1", amount: amount, tender: tender,
                            lines: [RefundLine(lineId: line.lineId, quantity: 1, amount: amount)], reason: reason, invoiceAction: action,
                            at: at, by: manager, authorizedBy: manager, allowanceNumber: action == .allowance ? "\(base.device.code)\(stamp)" : nil)
        }
        day.refunds.append(TicketRefund(ticketId: sale.ticketId, refund: refund))
    }

    // MARK: - 各行各業的單

    private func staffName(_ id: String) -> String { base.staff.first { $0.id == id }?.name ?? "" }

    private func staffIds(_ match: (StaffMember) -> Bool) -> [String] {
        base.staff.filter(match).map(\.id)
    }

    private var catalog: Catalog { base.catalog }

    private func items(in categoryId: String) -> [MenuItem] { catalog.items(in: categoryId) }

    private func ticket(_ id: String, date: String, at: Date, by: String, type: OrderType? = nil, tables: [String] = [], guests: Int = 0,
                        lines: [TicketLine], member: MemberRef? = nil, buyer: InvoiceBuyer = .paper, discount: Discount? = nil,
                        seller: String? = nil, customerName: String? = nil) -> Ticket {
        let orderType = type ?? base.store.defaultServiceMode.defaultOrderType
        return Ticket(id: id, number: "", deviceId: base.device.id, orderType: orderType, tableIds: tables, guests: guests, lines: lines,
                      discount: discount, serviceChargeBps: base.store.serviceChargeBps(for: orderType), member: member, invoiceBuyer: buyer,
                      openedAt: at, openedBy: by, businessDate: date, customerName: customerName, serviceMode: base.store.defaultServiceMode,
                      salespersonId: seller)
    }

    private func line(_ ticketId: String, _ k: Int, _ itemId: String, _ qty: Int = 1, variant: String? = nil, options: [String] = [],
                      staffId: String? = nil, assistantId: String? = nil, seller: String? = nil, redeem: PassRedemption? = nil,
                      by: String, at: Date, served: Bool = false) -> TicketLine? {
        DemoLines.make(catalog, staff: base.staff, id: "\(ticketId)-l\(k)", itemId: itemId, quantity: qty, variantId: variant, optionIds: options,
                       staffId: staffId, assistantId: assistantId, seller: seller, redeem: redeem, by: by, at: at, served: served)
    }

    /// 發票：一成多用手機條碼、偶爾打統編或捐贈
    private func buyer(rng: inout SeededRandom, carrierPercent: Int = 14) -> InvoiceBuyer {
        let r = rng.next(100)
        if r < carrierPercent {
            let chars = Array("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ+-.")
            var code = "/"
            for _ in 0..<7 { code.append(chars[rng.next(chars.count)]) }
            return .consumer(carrier: .mobileBarcode(code))
        }
        if r < carrierPercent + 3 { return .business(taxId: "27860122", title: "晴空數位有限公司") }
        if r < carrierPercent + 5 { return .donation(loveCode: "8455") }
        return .paper
    }

    // 晨麥手作：內用三分之二（桌號、人數、服務費），咖啡茶飲配早午餐、甜點、麵包
    private func cafe(_ id: String, date: String, at: Date, rng: inout SeededRandom) -> Draft? {
        let cashier = rng.weighted([("s-cameron", 6), ("s-jacob", 2), ("s-leslie", 1)]) ?? "s-cameron"
        let dineIn = rng.chance(66)
        let guests = dineIn ? 1 + rng.next(4) : 0
        let tables = dineIn ? (rng.pick(base.floor.allTables).map { [$0.id] } ?? []) : []
        var lines: [TicketLine] = []
        let count = 1 + rng.next(dineIn ? 4 : 3)
        for k in 0..<count {
            let category = rng.weighted([("c-coffee", 35), ("c-tea", 20), ("c-brunch", dineIn ? 22 : 8), ("c-dessert", 14), ("c-bread", 12)]) ?? "c-coffee"
            guard let item = rng.pick(items(in: category)) else { continue }
            let qty = 1 + (rng.chance(25) ? rng.next(max(guests, 2)) : 0)
            let options = DemoLines.randomOptions(catalog, for: item, rng: &rng)
            if let l = line(id, k, item.id, qty, options: options, by: cashier, at: at, served: true) { lines.append(l) }
        }
        guard !lines.isEmpty else { return nil }
        let member = rng.chance(9) ? rng.pick(regulars) : nil
        let t = ticket(id, date: date, at: at, by: cashier, type: dineIn ? .dineIn : .takeout, tables: tables, guests: guests, lines: lines,
                       member: member, buyer: buyer(rng: &rng))
        let tender = rng.weighted([(Tender.cash, 40), (.card, 20), (.linePay, 15), (.jkoPay, 10), (.pxPay, 8), (.easyWallet, 7)]) ?? .cash
        return Draft(at: at, ticket: t, tender: tender)
    }

    // Lumi 選物：一到三件、每件一個顏色尺寸；整張單算給一位店員；會員打九折
    private func apparel(_ id: String, date: String, at: Date, rng: inout SeededRandom) -> Draft? {
        let sellers = staffIds { $0.role != .owner }
        let seller = rng.pick(sellers) ?? base.staff.first?.id ?? ""
        var lines: [TicketLine] = []
        let count = 1 + rng.next(3)
        for k in 0..<count {
            let category = rng.weighted([("c-tops", 40), ("c-bottoms", 30), ("c-outer", 15), ("c-acc", 15)]) ?? "c-tops"
            guard let item = rng.pick(items(in: category).filter { $0.price.dollars > 10 }) else { continue }
            let variant = item.hasVariants ? rng.pick(item.activeVariants.filter(\.isAvailable))?.id : nil
            if item.hasVariants && variant == nil { continue }
            if let l = line(id, k, item.id, rng.chance(10) ? 2 : 1, variant: variant, seller: seller, by: seller, at: at) { lines.append(l) }
        }
        if rng.chance(30), let bag = line(id, 9, "ap-bag", by: seller, at: at) { lines.append(bag) }
        guard lines.contains(where: { $0.unitPrice.dollars > 10 }) else { return nil }
        var member: MemberRef? = nil
        var discount: Discount? = nil
        if rng.chance(35) {
            member = rng.pick(regulars) ?? Self.customer(rng.next(40), tag: "ah")
            if rng.chance(70) { discount = .percent(1000, reason: "會員九折") }
        }
        let t = ticket(id, date: date, at: at, by: seller, lines: lines, member: member, buyer: buyer(rng: &rng, carrierPercent: 20),
                       discount: discount, seller: seller)
        let tender = rng.weighted([(Tender.card, 40), (.linePay, 20), (.cash, 20), (.jkoPay, 12), (.pxPay, 8)]) ?? .card
        return Draft(at: at, ticket: t, tender: tender)
    }

    // Mori Hair：剪、洗剪、染燙護（設計師做、助理幫忙），會員常用次數卡抵、用儲值金付；偶爾買卡、儲值、帶一瓶保養品
    private func salon(_ id: String, date: String, at: Date, rng: inout SeededRandom) -> Draft? {
        let desk = "s-cameron"
        let designers = staffIds { $0.isBookable }
        let designer = rng.pick(designers) ?? desk
        let assistant = base.staff.first { $0.title == "助理" }?.id
        let isMember = rng.chance(75)
        let member = isMember ? Self.customer(rng.next(48), tag: "sh") : nil
        var lines: [TicketLine] = []
        var prepaid: Money? = nil

        let special = rng.next(100)
        if let member, special < 6 {
            // 買次數卡
            let pass = rng.chance(65) ? "pass-cut10" : "pass-treat5"
            if let l = line(id, 0, pass, seller: designer, by: desk, at: at) { lines.append(l) }
            let t = ticket(id, date: date, at: at, by: desk, lines: lines, member: member, buyer: buyer(rng: &rng), seller: designer)
            return lines.isEmpty ? nil : Draft(at: at, ticket: t, tender: rng.chance(70) ? .card : .linePay)
        }
        if let member, special < 12 {
            // 儲值
            let topUp = rng.chance(55) ? "topup-5000" : "topup-10000"
            if let l = line(id, 0, topUp, seller: designer, by: desk, at: at) { lines.append(l) }
            let t = ticket(id, date: date, at: at, by: desk, lines: lines, member: member, buyer: buyer(rng: &rng), seller: designer)
            return lines.isEmpty ? nil : Draft(at: at, ticket: t, tender: rng.chance(75) ? .card : .transfer)
        }

        let service = rng.weighted([("svc-cut", 30), ("svc-washcut", 26), ("svc-color", 16), ("svc-perm", 8), ("svc-treat", 12), ("svc-wash", 8)]) ?? "svc-cut"
        var redeem: PassRedemption? = nil
        if let member, (service == "svc-cut" || service == "svc-washcut"), rng.chance(30), let card = catalog.item("pass-cut10") {
            redeem = PassRedemption(passId: "\(member.id ?? "demo-sh")-cut10", name: card.name,
                                    value: AccountRules.unitValue(net: card.price, quantity: 1, spec: card.pass ?? PassSpec(kind: .visits, visits: 10)))
        }
        let chemical = service == "svc-color" || service == "svc-perm"
        let helper = chemical || service == "svc-washcut" ? (rng.chance(60) ? assistant : nil) : nil
        if let item = catalog.item(service),
           let l = line(id, 0, service, options: DemoLines.randomOptions(catalog, for: item, rng: &rng), staffId: designer, assistantId: helper,
                        redeem: redeem, by: desk, at: at) {
            lines.append(l)
        }
        if rng.chance(chemical ? 45 : 18) {
            var treatRedeem: PassRedemption? = nil
            if let member, rng.chance(25), let card = catalog.item("pass-treat5") {
                treatRedeem = PassRedemption(passId: "\(member.id ?? "demo-sh")-treat5", name: card.name,
                                             value: AccountRules.unitValue(net: card.price, quantity: 1, spec: card.pass ?? PassSpec(kind: .visits, visits: 5)))
            }
            if let l = line(id, 1, "svc-treat", staffId: designer, assistantId: helper, redeem: treatRedeem, by: desk, at: at.addingTimeInterval(3600)) {
                lines.append(l)
            }
        }
        if rng.chance(22), let item = rng.pick(items(in: "c-retail")), let l = line(id, 2, item.id, seller: designer, by: desk, at: at) {
            lines.append(l)
        }
        guard !lines.isEmpty else { return nil }
        let t = ticket(id, date: date, at: at, by: desk, lines: lines, member: member, buyer: buyer(rng: &rng), seller: designer)
        if member != nil, rng.chance(32) {
            // 用儲值金付（全部，或餘額不夠付一部分）
            let due = t.totals.amountDue
            prepaid = rng.chance(75) ? due : Money(dollars: max(due.dollars / 2 / 100 * 100, 100))
        }
        let tender = rng.weighted([(Tender.card, 45), (.cash, 30), (.linePay, 25)]) ?? .card
        return Draft(at: at, ticket: t, prepaid: prepaid, tender: tender)
    }

    // Pulse 健身：會籍、課程卡、私人教練（多半用堂數抵）、單次入場、單堂課、飲料補給
    private func fitness(_ id: String, date: String, at: Date, rng: inout SeededRandom) -> Draft? {
        let desk = rng.weighted([("s-cameron", 5), ("s-leslie", 2)]) ?? "s-cameron"
        let coaches = staffIds { $0.isBookable }
        let what = rng.weighted([("goods", 40), ("month", 11), ("quarter", 5), ("year", 2), ("class10", 5), ("pt10", 2), ("pt", 13),
                                 ("entry", 8), ("dropin", 9), ("inbody", 4)]) ?? "goods"
        let member = Self.customer(rng.next(60), tag: "fh")
        var lines: [TicketLine] = []
        var ref: MemberRef? = nil
        var customerName: String? = nil
        switch what {
        case "month", "quarter", "year", "class10", "pt10":
            let itemId = ["month": "pass-month", "quarter": "pass-quarter", "year": "pass-year", "class10": "pass-class10", "pt10": "pass-pt10"][what] ?? "pass-month"
            let seller = what == "pt10" ? rng.pick(coaches) : desk
            if let l = line(id, 0, itemId, seller: seller, by: desk, at: at) { lines.append(l) }
            ref = member
        case "pt":
            let coach = rng.pick(coaches) ?? desk
            var redeem: PassRedemption? = nil
            if rng.chance(65), let card = catalog.item("pass-pt10") {
                redeem = PassRedemption(passId: "\(member.id ?? "demo-fh")-pt10", name: card.name,
                                        value: AccountRules.unitValue(net: card.price, quantity: 1, spec: card.pass ?? PassSpec(kind: .visits, visits: 10)))
            }
            if let l = line(id, 0, "svc-pt60", staffId: coach, redeem: redeem, by: desk, at: at) { lines.append(l) }
            ref = member
        case "entry":
            if let l = line(id, 0, "entry-day", by: desk, at: at) { lines.append(l) }
            if rng.chance(50), let water = line(id, 1, "goods-water", by: desk, at: at) { lines.append(water) }
            customerName = "單次入場"
        case "dropin":
            let cls = rng.pick(["class-spin", "class-yoga", "class-hiit"]) ?? "class-spin"
            if let l = line(id, 0, cls, staffId: rng.pick(coaches), by: desk, at: at) { lines.append(l) }
        case "inbody":
            if let l = line(id, 0, "svc-inbody", staffId: rng.pick(coaches), by: desk, at: at) { lines.append(l) }
            ref = rng.chance(60) ? member : nil
        default:
            let count = 1 + rng.next(2)
            for k in 0..<count {
                guard let item = rng.pick(items(in: "c-shop")) else { continue }
                if let l = line(id, k, item.id, 1 + (rng.chance(25) ? 1 : 0), by: desk, at: at) { lines.append(l) }
            }
            ref = rng.chance(40) ? member : nil
        }
        guard !lines.isEmpty else { return nil }
        let t = ticket(id, date: date, at: at, by: desk, lines: lines, member: ref, buyer: buyer(rng: &rng), customerName: customerName)
        let tender = rng.weighted([(Tender.card, 40), (.linePay, 25), (.cash, 25), (.jkoPay, 10)]) ?? .card
        return Draft(at: at, ticket: t, tender: tender)
    }

    /// 健身房一天的報到（早上、晚上下班後最多）
    private func checkIns(date: String, midnight: Date, weekday: Int, ramp: Double, rng: inout SeededRandom) -> [CheckIn] {
        let typical = weekday == 1 ? 80 : (weekday == 7 ? 105 : 128)
        let n = Int(Double(typical + rng.next(40)) * ramp)
        let names = ["月卡", "季卡", "年卡"]
        var out: [CheckIn] = []
        for k in 0..<n {
            let slot = rng.weighted([(6.5, 14), (8.0, 8), (10.0, 5), (12.0, 8), (14.0, 4), (16.0, 6), (18.0, 22), (19.5, 18), (21.0, 7)]) ?? 18.0
            let at = midnight.addingTimeInterval((slot * 60 + Double(rng.next(90))) * 60)
            let who = Self.customer(rng.next(60), tag: "fh")
            let pass = names[rng.next(names.count)]
            // 期間會籍入場不扣次數（uses 0）：記進這台也不會動到帳戶
            out.append(CheckIn(id: "demo-h-\(date)-ci\(k)", member: who, passId: "\(who.id ?? "demo-fh")-\(pass)", passName: pass, uses: 0,
                               at: at, by: "s-cameron"))
        }
        return out.sorted { $0.at < $1.at }
    }

    // MARK: - 小工具

    /// 編出來的客人（歷史裡的熟客、健身的課程名單）：同一個 index 永遠是同一個人
    static func customer(_ i: Int, tag: String, prefixes: [String] = ["0958", "0937", "0988", "0916", "0983", "0906"]) -> MemberRef {
        let surnames = ["陳", "林", "黃", "張", "李", "王", "吳", "劉", "蔡", "楊", "許", "鄭", "謝", "郭", "洪", "曾", "邱", "廖", "賴", "周"]
        let given = ["雅婷", "怡君", "志豪", "家豪", "宜蓁", "冠宇", "欣怡", "承翰", "佳穎", "柏翰", "詩涵", "宗翰", "品妤", "俊傑", "思妤",
                     "彥廷", "郁婷", "子晴", "宇軒", "筱涵", "姿穎", "昱廷", "芷瑜", "博文"]
        let k = abs(i)
        let name = surnames[k % surnames.count] + given[(k * 7 + 3) % given.count]
        let phone = prefixes[k % prefixes.count] + String(format: "%06d", ((k + 1) * 104_729 + tag.count * 7_919) % 1_000_000)
        return MemberRef(id: "demo-\(tag)-\(k)", phone: phone, name: name, tierName: k % 5 == 0 ? "金卡會員" : "一般會員")
    }

    /// 字軌（照期別換兩個英文字）
    static func track(_ periodCode: String) -> String {
        let n = Int(periodCode) ?? 0
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        return "Q" + String(letters[n % letters.count])
    }

    /// 從 from 到 to 差幾天（yyyy-MM-dd）
    static func offset(from: String, to: String) -> Int? {
        guard let a = midnight(from), let b = midnight(to) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// yyyy-MM-dd 那天的 00:00（台北）
    static func midnight(_ date: String) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TaipeiTime.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 字串 → 亂數種子（FNV-1a；不用 hashValue：每次開 App 都不一樣）
    static func seed(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}
