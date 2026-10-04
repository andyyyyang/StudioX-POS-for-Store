import Foundation

// 報表：交班單（X／Z）、今天的營業、儀表板。全部從 StoreState 算；後台收到 shift.closed 時存一份交班單。

public struct TenderTotal: Codable, Sendable, Hashable {
    public var tender: Tender
    public var count: Int
    public var amount: Money
}

public struct NamedTotal: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var quantity: Int
    public var amount: Money
}

/// 一位服務人員的業績（設計師、教練、店員）
public struct StaffTotal: Codable, Sendable, Hashable {
    public var staffId: String
    /// 幾個品項（數量）
    public var items: Int
    /// 服務的實收（剪髮、私人教練）
    public var services: Money
    /// 商品、課程卡、儲值的實收
    public var goods: Money
    /// 用課程卡抵的服務價值（沒收到錢、但算業績）
    public var redeemed: Money
    /// 抽成
    public var commission: Money
    /// 當助理的次數
    public var assists: Int

    public init(staffId: String, items: Int = 0, services: Money = .zero, goods: Money = .zero, redeemed: Money = .zero, commission: Money = .zero, assists: Int = 0) {
        self.staffId = staffId; self.items = items; self.services = services; self.goods = goods; self.redeemed = redeemed
        self.commission = commission; self.assists = assists
    }

    /// 業績＝實收＋課程卡抵的價值
    public var performance: Money { services + goods + redeemed }
}

public struct HourTotal: Codable, Sendable, Hashable {
    /// 台北時間 0–23
    public var hour: Int
    public var count: Int
    public var amount: Money
}

public struct SalesSummary: Codable, Sendable, Hashable {
    /// 結帳的單數
    public var tickets: Int
    public var guests: Int
    public var itemsGross: Money
    public var discounts: Money
    public var serviceCharge: Money
    /// 營業額（含稅、扣掉折扣、含服務費；不含小費）
    public var total: Money
    public var tax: Money
    public var tips: Money
    public var refunds: Money
    /// 營業額 − 退款
    public var net: Money
    public var byTender: [TenderTotal]
    public var byCategory: [NamedTotal]
    public var topItems: [NamedTotal]
    public var byHour: [HourTotal]
    public var byOrderType: [String: Money]
    public var voidedItems: Int
    public var voidedAmount: Money
    public var voidedTickets: Int
    public var invoicesIssued: Int
    public var invoicesVoided: Int
    /// 今天開到哪些號碼（AB12345678–AB12345699）
    public var invoiceRanges: [String]
    /// 每位服務人員的業績與抽成
    public var byStaff: [StaffTotal]
    /// 各營業模式的營業額
    public var byMode: [String: Money]
    /// 賣出的儲值（預收款，不是營收）
    public var prepaidSold: Money
    /// 賣出的課程卡、會籍
    public var passesSold: Money
    /// 用儲值金付的
    public var prepaidUsed: Money
    /// 用課程卡抵掉的服務價值
    public var redeemedValue: Money
    /// 實收：真的收到的錢（含小費；不算儲值金、換貨抵用；扣掉退款與換貨退差額）
    public var received: Money
    /// 換貨抵用（退回的商品抵掉新買的）
    public var exchangeCredit: Money
    /// 入場報到人次
    public var checkIns: Int

    public var averageTicket: Money { tickets > 0 ? Money(dollars: Int((Double(total.dollars) / Double(tickets)).rounded())) : .zero }
    public var averagePerGuest: Money { guests > 0 ? Money(dollars: Int((Double(total.dollars) / Double(guests)).rounded())) : .zero }

    public static let empty = SalesSummary(sales: [], refunds: [], voidedTickets: [], invoices: [], voidedInvoices: [])

    public init(sales: [SaleRecord], refunds: [Refund], voidedTickets: [Ticket], invoices: [EInvoice], voidedInvoices: [String], checkIns: Int = 0) {
        tickets = sales.count
        guests = sales.reduce(0) { $0 + $1.guests }
        itemsGross = Money.sum(sales.map(\.itemsGross))
        discounts = Money.sum(sales.map(\.discount))
        serviceCharge = Money.sum(sales.map(\.serviceCharge))
        total = Money.sum(sales.map(\.total))
        tax = Money.sum(sales.map(\.tax))
        tips = Money.sum(sales.map(\.tip))
        self.refunds = Money.sum(refunds.map(\.amount))
        net = total - self.refunds

        var tenders: [Tender: TenderTotal] = [:]
        for p in sales.flatMap(\.payments) {
            var t = tenders[p.tender] ?? TenderTotal(tender: p.tender, count: 0, amount: .zero)
            t.count += 1
            t.amount += p.amount
            tenders[p.tender] = t
        }
        for r in refunds {
            var t = tenders[r.tender] ?? TenderTotal(tender: r.tender, count: 0, amount: .zero)
            t.amount -= r.amount
            tenders[r.tender] = t
        }
        byTender = tenders.values.sorted { $0.amount > $1.amount }

        var cats: [String: NamedTotal] = [:]
        var items: [String: NamedTotal] = [:]
        for l in sales.flatMap(\.lines) {
            let ck = l.categoryId ?? "_"
            var c = cats[ck] ?? NamedTotal(id: ck, name: l.categoryName ?? "其他", quantity: 0, amount: .zero)
            c.quantity += l.quantity
            c.amount += l.net
            cats[ck] = c
            let ik = l.itemId ?? l.name
            var i = items[ik] ?? NamedTotal(id: ik, name: l.name, quantity: 0, amount: .zero)
            i.quantity += l.quantity
            i.amount += l.net
            items[ik] = i
        }
        byCategory = cats.values.sorted { $0.amount > $1.amount }
        topItems = Array(items.values.sorted { ($0.quantity, $0.amount) > ($1.quantity, $1.amount) }.prefix(10))

        var hours: [Int: HourTotal] = [:]
        for s in sales {
            let h = TaipeiTime.components(s.closedAt).hour ?? 0
            var x = hours[h] ?? HourTotal(hour: h, count: 0, amount: .zero)
            x.count += 1
            x.amount += s.total
            hours[h] = x
        }
        byHour = hours.values.sorted { $0.hour < $1.hour }

        var types: [String: Money] = [:]
        for s in sales { types[s.orderType.rawValue, default: .zero] += s.total }
        byOrderType = types

        voidedItems = sales.reduce(0) { $0 + $1.voidedItems } + voidedTickets.reduce(0) { $0 + $1.activeLines.reduce(0) { $0 + $1.quantity } }
        voidedAmount = Money.sum(sales.map(\.voidedAmount)) + Money.sum(voidedTickets.map { $0.totals.itemsGross })
        self.voidedTickets = voidedTickets.count
        invoicesIssued = invoices.count
        invoicesVoided = voidedInvoices.count
        invoiceRanges = SalesSummary.ranges(invoices.map(\.number))

        var staff: [String: StaffTotal] = [:]
        var modes: [String: Money] = [:]
        var prepaid = Money.zero, passes = Money.zero, redeemed = Money.zero
        for sale in sales {
            modes[(sale.serviceMode ?? .tableService).rawValue, default: .zero] += sale.total
            for l in sale.lines {
                switch l.kind ?? .goods {
                case .storedValue: prepaid += l.net
                case .pass: passes += l.net
                case .goods, .service: break
                }
                redeemed += l.redeemedValue
                let who = l.staffId ?? sale.openedBy
                var st = staff[who] ?? StaffTotal(staffId: who)
                st.items += l.quantity
                if l.kind == .service { st.services += l.net } else { st.goods += l.net }
                st.redeemed += l.redeemedValue
                st.commission += l.commission
                staff[who] = st
                if let a = l.assistantId {
                    var at = staff[a] ?? StaffTotal(staffId: a)
                    at.assists += l.quantity
                    staff[a] = at
                }
            }
        }
        byStaff = staff.values.sorted { ($0.performance, $0.staffId) > ($1.performance, $1.staffId) }
        byMode = modes
        prepaidSold = prepaid
        passesSold = passes
        redeemedValue = redeemed
        let payments = sales.flatMap(\.payments)
        prepaidUsed = Money.sum(payments.filter { $0.tender == .prepaid }.map(\.amount))
        exchangeCredit = Money.sum(payments.filter { $0.tender == .exchange }.map(\.amount))
        let realIn = Money.sum(payments.filter { !$0.tender.isInternal }.map(\.amount))
        let cashBack = Money.sum(payments.filter { $0.tender.isInternal }.map(\.change))
        let realOut = Money.sum(refunds.filter { !$0.tender.isInternal }.map(\.amount))
        received = realIn - cashBack - realOut
        self.checkIns = checkIns
    }

    // 舊版 App 的交班單（事件裡存著）沒有後面這些欄位：用 0 補上，不要整筆讀不進來
    enum CodingKeys: String, CodingKey {
        case tickets, guests, itemsGross, discounts, serviceCharge, total, tax, tips, refunds, net, byTender, byCategory, topItems, byHour
        case byOrderType, voidedItems, voidedAmount, voidedTickets, invoicesIssued, invoicesVoided, invoiceRanges
        case byStaff, byMode, prepaidSold, passesSold, prepaidUsed, redeemedValue, received, exchangeCredit, checkIns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tickets = try c.decode(Int.self, forKey: .tickets)
        guests = try c.decode(Int.self, forKey: .guests)
        itemsGross = try c.decode(Money.self, forKey: .itemsGross)
        discounts = try c.decode(Money.self, forKey: .discounts)
        serviceCharge = try c.decode(Money.self, forKey: .serviceCharge)
        total = try c.decode(Money.self, forKey: .total)
        tax = try c.decode(Money.self, forKey: .tax)
        tips = try c.decode(Money.self, forKey: .tips)
        refunds = try c.decode(Money.self, forKey: .refunds)
        net = try c.decode(Money.self, forKey: .net)
        byTender = try c.decode([TenderTotal].self, forKey: .byTender)
        byCategory = try c.decode([NamedTotal].self, forKey: .byCategory)
        topItems = try c.decode([NamedTotal].self, forKey: .topItems)
        byHour = try c.decode([HourTotal].self, forKey: .byHour)
        byOrderType = try c.decode([String: Money].self, forKey: .byOrderType)
        voidedItems = try c.decode(Int.self, forKey: .voidedItems)
        voidedAmount = try c.decode(Money.self, forKey: .voidedAmount)
        voidedTickets = try c.decode(Int.self, forKey: .voidedTickets)
        invoicesIssued = try c.decode(Int.self, forKey: .invoicesIssued)
        invoicesVoided = try c.decode(Int.self, forKey: .invoicesVoided)
        invoiceRanges = try c.decode([String].self, forKey: .invoiceRanges)
        byStaff = try c.decodeIfPresent([StaffTotal].self, forKey: .byStaff) ?? []
        byMode = try c.decodeIfPresent([String: Money].self, forKey: .byMode) ?? [:]
        prepaidSold = try c.decodeIfPresent(Money.self, forKey: .prepaidSold) ?? .zero
        passesSold = try c.decodeIfPresent(Money.self, forKey: .passesSold) ?? .zero
        prepaidUsed = try c.decodeIfPresent(Money.self, forKey: .prepaidUsed) ?? .zero
        redeemedValue = try c.decodeIfPresent(Money.self, forKey: .redeemedValue) ?? .zero
        received = try c.decodeIfPresent(Money.self, forKey: .received) ?? (total + tips - refunds)
        exchangeCredit = try c.decodeIfPresent(Money.self, forKey: .exchangeCredit) ?? .zero
        checkIns = try c.decodeIfPresent(Int.self, forKey: .checkIns) ?? 0
    }

    /// 營收（扣掉預收的儲值；課程卡賣出時就算營收）
    public var revenue: Money { total - prepaidSold }

    /// 連續的號碼併成一段：AB12345678、AB12345679、AB12345680 → AB12345678–AB12345680
    public static func ranges(_ numbers: [String]) -> [String] {
        let parsed = numbers.compactMap { n -> (String, Int)? in
            guard n.count == 10, let v = Int(n.suffix(8)) else { return nil }
            return (String(n.prefix(2)), v)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var out: [String] = []
        var i = 0
        while i < parsed.count {
            var j = i
            while j + 1 < parsed.count && parsed[j + 1].0 == parsed[i].0 && parsed[j + 1].1 == parsed[j].1 + 1 { j += 1 }
            let a = parsed[i].0 + String(format: "%08d", parsed[i].1)
            let b = parsed[j].0 + String(format: "%08d", parsed[j].1)
            out.append(i == j ? a : "\(a)–\(b)")
            i = j + 1
        }
        return out
    }
}

/// 交班單
public struct ShiftReport: Codable, Sendable, Hashable {
    public var shiftId: String
    public var deviceId: String
    public var businessDate: String
    public var openedAt: Date
    public var closedAt: Date?
    public var openedBy: String
    public var closedBy: String?
    public var openingCash: Money
    public var cashSales: Money
    public var cashRefunds: Money
    /// 換貨退差額（不是現金付的款，找回現金）
    public var cashBack: Money
    public var payIns: Money
    public var payOuts: Money
    public var noSaleCount: Int
    public var expectedCash: Money
    public var countedCash: Money?
    /// 點到的 − 應有的（正數＝多、負數＝短）
    public var difference: Money? { countedCash.map { $0 - expectedCash } }
    public var summary: SalesSummary

    public init(shift s: Shift, state: StoreState, now: Date, counted: CashCount? = nil) {
        shiftId = s.id
        deviceId = s.deviceId
        businessDate = s.businessDate
        openedAt = s.openedAt
        closedAt = s.closedAt
        openedBy = s.openedBy
        closedBy = s.closedBy
        openingCash = s.openingCash
        let end = s.closedAt ?? now
        let sales = state.sales.values.filter { $0.shiftId == s.id || ($0.shiftId == nil && $0.deviceId == s.deviceId && $0.closedAt >= s.openedAt && $0.closedAt <= end) }
        let ticketsInShift = state.tickets.values
        var cashIn = Money.zero, cashOut = Money.zero, back = Money.zero
        var refunds: [Refund] = []
        for t in ticketsInShift {
            for p in t.payments where p.shiftId == s.id && p.status == .approved {
                if p.tender == .cash { cashIn += p.amount } else { back += p.change }
            }
            for r in t.refunds where r.shiftId == s.id {
                refunds.append(r)
                if r.tender == .cash { cashOut += r.amount }
            }
        }
        cashSales = cashIn
        cashRefunds = cashOut
        cashBack = back
        payIns = Money.sum(s.moves.filter { $0.kind == .payIn }.map(\.amount))
        payOuts = Money.sum(s.moves.filter { $0.kind == .payOut }.map(\.amount))
        noSaleCount = s.moves.filter { $0.kind == .noSale }.count
        expectedCash = s.expectedAtClose ?? state.expectedCash(shiftId: s.id)
        countedCash = (counted ?? s.counted)?.total
        let voided = ticketsInShift.filter { $0.status == .voided && $0.mergedInto == nil && $0.deviceId == s.deviceId && $0.openedAt >= s.openedAt && $0.openedAt <= end }
        let invoiceList = state.invoices.values.filter { $0.deviceId == s.deviceId && $0.issuedAt >= s.openedAt && $0.issuedAt <= end }
        let voidedNumbers = invoiceList.map(\.number).filter { state.voidedInvoices[$0] != nil }
        let checkIns = state.checkIns.values.filter { !$0.isVoided && $0.at >= s.openedAt && $0.at <= end }.count
        summary = SalesSummary(sales: Array(sales), refunds: refunds, voidedTickets: voided, invoices: invoiceList, voidedInvoices: voidedNumbers, checkIns: checkIns)
    }

    enum CodingKeys: String, CodingKey {
        case shiftId, deviceId, businessDate, openedAt, closedAt, openedBy, closedBy, openingCash, cashSales, cashRefunds, cashBack
        case payIns, payOuts, noSaleCount, expectedCash, countedCash, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shiftId = try c.decode(String.self, forKey: .shiftId)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        businessDate = try c.decode(String.self, forKey: .businessDate)
        openedAt = try c.decode(Date.self, forKey: .openedAt)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        openedBy = try c.decode(String.self, forKey: .openedBy)
        closedBy = try c.decodeIfPresent(String.self, forKey: .closedBy)
        openingCash = try c.decode(Money.self, forKey: .openingCash)
        cashSales = try c.decode(Money.self, forKey: .cashSales)
        cashRefunds = try c.decode(Money.self, forKey: .cashRefunds)
        cashBack = try c.decodeIfPresent(Money.self, forKey: .cashBack) ?? .zero
        payIns = try c.decode(Money.self, forKey: .payIns)
        payOuts = try c.decode(Money.self, forKey: .payOuts)
        noSaleCount = try c.decode(Int.self, forKey: .noSaleCount)
        expectedCash = try c.decode(Money.self, forKey: .expectedCash)
        countedCash = try c.decodeIfPresent(Money.self, forKey: .countedCash)
        summary = try c.decode(SalesSummary.self, forKey: .summary)
    }
}

extension StoreState {
    /// 某個營業日（所有 iPad 同步進來的都算）
    public func dailySummary(businessDate: String) -> SalesSummary {
        let sales = closedSales(businessDate: businessDate)
        let refunds = tickets.values.flatMap(\.refunds).filter { TaipeiTime.businessDate($0.at) == businessDate }
        let voided = tickets.values.filter { $0.businessDate == businessDate && $0.status == .voided && $0.mergedInto == nil }
        let invoiceList = invoices.values.filter { TaipeiTime.businessDate($0.issuedAt) == businessDate }
        let voidedNumbers = invoiceList.map(\.number).filter { voidedInvoices[$0] != nil }
        return SalesSummary(sales: sales, refunds: refunds, voidedTickets: voided, invoices: invoiceList, voidedInvoices: voidedNumbers,
                            checkIns: checkIns(businessDate: businessDate).count)
    }
}
