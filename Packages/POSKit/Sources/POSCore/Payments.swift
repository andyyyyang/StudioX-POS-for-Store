import Foundation

/// 付款方式
public enum Tender: String, Codable, Sendable, Hashable, CaseIterable {
    case cash
    /// 信用卡（店裡的刷卡機；手動輸入授權碼、卡號末四碼）
    case card
    /// 感應支付（iPhone／iPad 上的 Tap to Pay，或外接讀卡機）
    case tapToPay
    case linePay
    case jkoPay
    case pxPay
    case easyWallet
    /// 悠遊卡、一卡通這類電子票證
    case stored
    /// 禮券、餐券
    case voucher
    /// 轉帳
    case transfer
    case other

    public var label: String {
        switch self {
        case .cash: "現金"
        case .card: "信用卡"
        case .tapToPay: "感應支付"
        case .linePay: "LINE Pay"
        case .jkoPay: "街口支付"
        case .pxPay: "全支付"
        case .easyWallet: "悠遊付"
        case .stored: "電子票證"
        case .voucher: "禮券"
        case .transfer: "轉帳"
        case .other: "其他"
        }
    }

    /// 會進錢櫃的（交班時要點錢）
    public var isCash: Bool { self == .cash }
    /// 需要輸入交易序號／授權碼（對帳用）
    public var wantsReference: Bool { self != .cash }
    /// 電子支付（掃客人的付款碼）
    public var isWallet: Bool { [.linePay, .jkoPay, .pxPay, .easyWallet].contains(self) }
}

public enum PaymentStatus: String, Codable, Sendable, Hashable {
    case approved, voided
}

public struct Payment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var tender: Tender
    /// 算進這張單的金額（現金是收的錢扣掉找零）
    public var amount: Money
    /// 現金：客人給的錢
    public var tendered: Money?
    /// 現金：找零
    public var change: Money
    /// 刷卡授權碼、電子支付的交易序號
    public var reference: String?
    /// 卡號末四碼
    public var cardLast4: String?
    public var status: PaymentStatus
    public var at: Date
    public var by: String
    /// 收在哪一班（交班時算錢櫃）
    public var shiftId: String?
    public var voidReason: String?

    public init(id: String, tender: Tender, amount: Money, tendered: Money? = nil, change: Money = .zero, reference: String? = nil,
                cardLast4: String? = nil, status: PaymentStatus = .approved, at: Date, by: String, shiftId: String? = nil, voidReason: String? = nil) {
        self.id = id; self.tender = tender; self.amount = amount; self.tendered = tendered; self.change = change
        self.reference = reference; self.cardLast4 = cardLast4; self.status = status; self.at = at; self.by = by
        self.shiftId = shiftId; self.voidReason = voidReason
    }

    /// 現金收款：給了多少、要付多少 → 這筆算多少、找多少
    public static func cash(id: String, tendered: Money, due: Money, at: Date, by: String, shiftId: String?) -> Payment {
        let applied = min(tendered, due)
        return Payment(id: id, tender: .cash, amount: applied, tendered: tendered, change: max(tendered - due, .zero), at: at, by: by, shiftId: shiftId)
    }
}

/// 發票怎麼處理這次退款
public enum InvoiceRefundAction: String, Codable, Sendable, Hashable {
    /// 作廢重開（同一期、證明聯收回）
    case void
    /// 開折讓單（跨期、或部分退款）
    case allowance
    /// 沒開發票
    case none
}

public struct RefundLine: Codable, Sendable, Hashable {
    public var lineId: String
    public var quantity: Int
    public var amount: Money

    public init(lineId: String, quantity: Int, amount: Money) {
        self.lineId = lineId; self.quantity = quantity; self.amount = amount
    }
}

public struct Refund: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var amount: Money
    public var tender: Tender
    /// 部分退款退了哪些品項（全部退就是空的）
    public var lines: [RefundLine]
    public var reason: String
    public var invoiceAction: InvoiceRefundAction
    public var at: Date
    public var by: String
    public var authorizedBy: String?
    public var shiftId: String?
    /// 折讓單號（invoiceAction == .allowance）
    public var allowanceNumber: String?

    public init(id: String, amount: Money, tender: Tender, lines: [RefundLine] = [], reason: String, invoiceAction: InvoiceRefundAction,
                at: Date, by: String, authorizedBy: String? = nil, shiftId: String? = nil, allowanceNumber: String? = nil) {
        self.id = id; self.amount = amount; self.tender = tender; self.lines = lines; self.reason = reason
        self.invoiceAction = invoiceAction; self.at = at; self.by = by; self.authorizedBy = authorizedBy
        self.shiftId = shiftId; self.allowanceNumber = allowanceNumber
    }

    public var isFull: Bool { lines.isEmpty }
}
