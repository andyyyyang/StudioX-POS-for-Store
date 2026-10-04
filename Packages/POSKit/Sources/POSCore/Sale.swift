import Foundation

/// 結帳那一刻的完整紀錄（ticketClosed 事件帶的內容）。
///
/// 後台直接存這一份（pos_sales／pos_sale_lines／pos_payments），不用自己重算單子：
/// 金額的算法只有 iPad 上這一份（TicketTotals），後台只檢查加起來對不對。
public struct SaleLine: Codable, Sendable, Hashable {
    public var lineId: String
    public var itemId: String?
    public var name: String
    public var categoryId: String?
    public var categoryName: String?
    public var modifiers: String
    public var quantity: Int
    /// 單價＋加料
    public var unitPrice: Money
    public var gross: Money
    public var discount: Money
    /// 實收（扣掉單品折扣與分攤的整單折扣）
    public var net: Money
    public var taxKind: TaxKind
    public var productId: String?
    public var variantId: String?
    // 非餐飲業（沒有就不出現）
    public var kind: ItemKind?
    public var skuId: String?
    /// 「黑・M」
    public var variantName: String?
    /// 業績算給誰（已經照「行上指定 → 整單銷售人員 → 開單的人」決定好）
    public var staffId: String?
    public var assistantId: String?
    public var commissionBps: Int?
    /// 賣出的課程卡／會籍
    public var pass: PassSpec?
    public var passStartsAt: Date?
    /// 儲值：每一份加多少
    public var credit: Money?
    /// 用課程卡抵
    public var redeem: PassRedemption?

    /// 課程卡抵掉的價值（業績用）
    public var redeemedValue: Money { (redeem?.value ?? .zero) * quantity }
    /// 算業績的金額：實收＋課程卡抵掉的價值
    public var performanceValue: Money { net + redeemedValue }
    /// 抽成（整數元）
    public var commission: Money { performanceValue.applying(bps: commissionBps ?? 0) }
    /// 「經典直筒褲 黑・M」
    public var displayName: String { variantName.map { "\(name) \($0)" } ?? name }
}

public struct SaleRecord: Codable, Sendable, Hashable {
    public var ticketId: String
    public var number: String
    /// 結帳的那一台（錢進了它的錢櫃）
    public var deviceId: String
    /// 開單的那一台（手持點餐機開、櫃台結帳時兩個不一樣）
    public var openedDeviceId: String
    public var shiftId: String?
    public var businessDate: String
    public var orderType: OrderType
    public var tableIds: [String]
    public var tableNames: String
    public var guests: Int
    public var customerName: String?
    public var openedAt: Date
    public var closedAt: Date
    public var openedBy: String
    public var closedBy: String
    public var staffName: String
    public var member: MemberRef?
    public var lines: [SaleLine]
    public var itemsGross: Money
    public var discount: Money
    public var discountReason: String?
    public var serviceCharge: Money
    public var total: Money
    public var tip: Money
    public var tax: Money
    public var payments: [Payment]
    public var invoice: InvoiceStamp?
    /// 作廢了幾個品項、多少錢（報表的「作廢」）
    public var voidedItems: Int
    public var voidedAmount: Money
    public var note: String
    /// 結帳時的營業模式
    public var serviceMode: ServiceMode?
    public var salespersonId: String?
    /// 換貨單：抵掉了哪張原單的哪些品項
    public var exchange: ExchangeCredit?
    /// 從哪一筆預約來的
    public var appointmentId: String?

    public init(ticket t: Ticket, closedOn deviceId: String, shiftId: String?, closedAt: Date, closedBy: String, staffName: String, floor: FloorPlan) {
        let totals = t.totals
        let amounts = Dictionary(uniqueKeysWithValues: totals.lines.map { ($0.lineId, $0) })
        ticketId = t.id
        number = t.number
        self.deviceId = deviceId
        openedDeviceId = t.deviceId
        self.shiftId = shiftId
        businessDate = t.businessDate
        orderType = t.orderType
        tableIds = t.tableIds
        tableNames = floor.tableNames(t.tableIds)
        guests = t.guests
        customerName = t.customerName
        openedAt = t.openedAt
        self.closedAt = closedAt
        openedBy = t.openedBy
        self.closedBy = closedBy
        self.staffName = staffName
        member = t.member
        lines = t.activeLines.map { l in
            let a = amounts[l.id]
            return SaleLine(
                lineId: l.id, itemId: l.itemId, name: l.name, categoryId: l.categoryId, categoryName: l.categoryName,
                modifiers: l.modifierText, quantity: l.quantity, unitPrice: l.unitTotal, gross: l.gross,
                discount: (a?.lineDiscount ?? .zero) + (a?.orderDiscountShare ?? .zero), net: a?.net ?? l.gross,
                taxKind: l.taxKind, productId: l.productId, variantId: l.variantId,
                kind: l.kind, skuId: l.skuId, variantName: l.variantName, staffId: t.performer(of: l), assistantId: l.assistantId,
                commissionBps: l.commissionBps, pass: l.pass, passStartsAt: l.passStartsAt, credit: l.credit, redeem: l.redeem
            )
        }
        itemsGross = totals.itemsGross
        discount = totals.discountTotal
        discountReason = t.discount?.reason
        serviceCharge = totals.serviceCharge
        total = totals.total
        tip = totals.tip
        tax = totals.tax
        payments = t.approvedPayments
        invoice = t.invoice
        let voided = t.lines.filter { !$0.isActive }
        voidedItems = voided.reduce(0) { $0 + $1.quantity }
        voidedAmount = Money.sum(voided.map(\.gross))
        note = t.note
        serviceMode = t.serviceMode
        salespersonId = t.salespersonId
        exchange = t.exchange
        appointmentId = t.appointmentId
    }

    /// 這一行退 quantity 個值多少（照實收比例，整數元；退到最後一個時把零頭補齊）
    public func refundAmount(lineId: String, quantity: Int, alreadyRefunded: Int = 0) -> Money {
        guard let l = lines.first(where: { $0.lineId == lineId }), l.quantity > 0 else { return .zero }
        let q = min(max(quantity, 0), l.quantity - alreadyRefunded)
        guard q > 0 else { return .zero }
        if alreadyRefunded + q >= l.quantity {
            let before = Money(dollars: l.net.dollars * alreadyRefunded / l.quantity)
            return l.net - before
        }
        return Money(dollars: l.net.dollars * (alreadyRefunded + q) / l.quantity) - Money(dollars: l.net.dollars * alreadyRefunded / l.quantity)
    }

    /// 每一行已經退了幾個（部分退款、換貨）
    public func refundedQuantities(_ refunds: [Refund]) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in refunds {
            if r.lines.isEmpty {
                // 沒列品項：退了整張才算全部退；只退一部分金額不算退了哪一件
                if r.amount >= total { for l in lines { out[l.lineId] = l.quantity } }
            } else {
                for rl in r.lines { out[rl.lineId, default: 0] += rl.quantity }
            }
        }
        return out
    }

    /// 加起來對不對（後台收到時也做同樣的檢查）
    public var problems: [String] {
        var out: [String] = []
        let net = Money.sum(lines.map(\.net))
        if net + serviceCharge != total { out.append("品項實收 \(net.plain)＋服務費 \(serviceCharge.plain) ≠ 總計 \(total.plain)") }
        let paid = Money.sum(payments.map(\.amount))
        if paid < total + tip { out.append("收款 \(paid.plain) 少於應收 \((total + tip).plain)") }
        return out
    }
}
