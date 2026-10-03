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
                taxKind: l.taxKind, productId: l.productId, variantId: l.variantId
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
