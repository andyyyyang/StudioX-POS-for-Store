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
    /// 會員的儲值金（扣客人的餘額；要先找到會員）
    case prepaid
    /// 換貨：退回的商品抵掉的金額（不是真的收錢）
    case exchange
    /// 外送平台代收（Uber Eats、foodpanda 的單：客人在平台上付了，平台扣掉抽成之後撥給店）
    case platform

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
        case .prepaid: "儲值金"
        case .exchange: "換貨抵用"
        case .platform: "外送平台"
        }
    }

    /// 付款畫面上列出來給人選的（儲值金要有會員才出現、換貨抵用是自動的）
    public static let selectable: [Tender] = [.cash, .card, .tapToPay, .linePay, .jkoPay, .pxPay, .easyWallet, .stored, .voucher, .transfer, .other]

    /// 不是真的收到錢（儲值金是之前收過的、換貨是退回的商品抵的）：「實收」不算
    public var isInternal: Bool { self == .prepaid || self == .exchange }

    /// 會進錢櫃的（交班時要點錢）
    public var isCash: Bool { self == .cash }
    /// 需要輸入交易序號／授權碼（對帳用）
    public var wantsReference: Bool { self != .cash && !isInternal && self != .platform }
    /// 電子支付（掃客人的付款碼）
    public var isWallet: Bool { [.linePay, .jkoPay, .pxPay, .easyWallet].contains(self) }
}

public enum PaymentStatus: String, Codable, Sendable, Hashable {
    case approved, voided
}

/// 經銀行刷卡機（EDC 的收銀機連線，ECR）收或退的款：刷卡機回的資料。
/// 對帳（端末代號、批次、調閱編號）、之後在刷卡機上取消／退貨都要用，所以整份留在付款上。
/// 欄位都是選填：舊的 iPad、後台不認得這一塊也照常（沒有的時候 JSON 裡不出現）
public struct CardTerminalRef: Codable, Sendable, Hashable {
    /// 電文格式（`nccc`：聯卡中心 8N1 標準）
    public var format: String
    /// 付款工具（N 信用卡、C 銀聯、S Smart Pay、E 電子票證、W 電子錢包）：退貨時照原來的送
    public var kind: String?
    /// 端末代號（TID）
    public var terminalId: String?
    /// 商店代號（MID）
    public var merchantId: String?
    /// 批次號碼（刷卡機結帳一次換一批）
    public var batchNo: String?
    /// 調閱編號（簽單上的 Receipt No；在刷卡機上取消要用）
    public var receiptNo: String?
    /// 授權碼（電子錢包沒有）
    public var approvalNo: String?
    /// 卡別、錢包、票證（Visa、LINE Pay、悠遊卡…）
    public var brand: String?
    /// 主機代號（03 信用卡、06 電子票證、08 電子錢包）
    public var hostId: String?
    /// 刷卡機上的交易日期時間（YYMMDDhhmmss）
    public var at: String?
    /// 電子錢包：特店訂單編號、錢包業者的交易序號
    public var walletOrderId: String?
    public var walletTransactionId: String?

    public init(format: String, kind: String? = nil, terminalId: String? = nil, merchantId: String? = nil, batchNo: String? = nil,
                receiptNo: String? = nil, approvalNo: String? = nil, brand: String? = nil, hostId: String? = nil, at: String? = nil,
                walletOrderId: String? = nil, walletTransactionId: String? = nil) {
        self.format = format; self.kind = kind; self.terminalId = terminalId; self.merchantId = merchantId; self.batchNo = batchNo
        self.receiptNo = receiptNo; self.approvalNo = approvalNo; self.brand = brand; self.hostId = hostId; self.at = at
        self.walletOrderId = walletOrderId; self.walletTransactionId = walletTransactionId
    }

    /// 同一台刷卡機、同一批、同一個調閱編號＝同一筆（查上一筆時認得是不是已經記過的）
    public var key: String { Self.key(terminalId: terminalId, batchNo: batchNo, receiptNo: receiptNo) }

    public static func key(terminalId: String?, batchNo: String?, receiptNo: String?) -> String {
        "\(terminalId ?? "")/\(batchNo ?? "")/\(receiptNo ?? "")"
    }

    /// 「調閱 000123・授權 AB1234・批次 000042」
    public var summary: String {
        var parts: [String] = []
        if let r = receiptNo, !r.isEmpty { parts.append("調閱 \(r)") }
        if let a = approvalNo, !a.isEmpty { parts.append("授權 \(a)") }
        if let b = batchNo, !b.isEmpty { parts.append("批次 \(b)") }
        return parts.isEmpty ? "刷卡機" : parts.joined(separator: "・")
    }
}

public struct Payment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var tender: Tender
    /// 算進這張單的金額（現金是收的錢扣掉找零）
    public var amount: Money
    /// 現金：客人給的錢
    public var tendered: Money?
    /// 找零（一律是現金從錢櫃拿出去；換貨抵用比新買的多時，差額也是這樣退給客人）
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
    /// 經刷卡機收的（端末、批次、調閱編號…）；手動輸入的沒有
    public var terminal: CardTerminalRef?

    public init(id: String, tender: Tender, amount: Money, tendered: Money? = nil, change: Money = .zero, reference: String? = nil,
                cardLast4: String? = nil, status: PaymentStatus = .approved, at: Date, by: String, shiftId: String? = nil, voidReason: String? = nil,
                terminal: CardTerminalRef? = nil) {
        self.id = id; self.tender = tender; self.amount = amount; self.tendered = tendered; self.change = change
        self.reference = reference; self.cardLast4 = cardLast4; self.status = status; self.at = at; self.by = by
        self.shiftId = shiftId; self.voidReason = voidReason; self.terminal = terminal
    }

    /// 這筆讓錢櫃多了多少現金：現金收的錢扣掉找零；其他方式只有找零（從錢櫃拿出去）
    public var drawerDelta: Money {
        guard status == .approved else { return .zero }
        return tender == .cash ? amount : .zero - change
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
    /// 在刷卡機上退的（取消或退貨）：刷卡機回的資料
    public var terminal: CardTerminalRef?

    public init(id: String, amount: Money, tender: Tender, lines: [RefundLine] = [], reason: String, invoiceAction: InvoiceRefundAction,
                at: Date, by: String, authorizedBy: String? = nil, shiftId: String? = nil, allowanceNumber: String? = nil,
                terminal: CardTerminalRef? = nil) {
        self.id = id; self.amount = amount; self.tender = tender; self.lines = lines; self.reason = reason
        self.invoiceAction = invoiceAction; self.at = at; self.by = by; self.authorizedBy = authorizedBy
        self.shiftId = shiftId; self.allowanceNumber = allowanceNumber; self.terminal = terminal
    }

    public var isFull: Bool { lines.isEmpty }
}
