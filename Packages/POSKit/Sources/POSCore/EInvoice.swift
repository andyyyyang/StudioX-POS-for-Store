import Foundation

// 電子發票的資料（開立時的內容）。放在 POSCore 是因為它跟著事件走（invoiceIssued），
// 號碼配發、條碼、QR Code、證明聯版面在 POSInvoice。上傳財政部在後台（MIG 4.1 的 F0401／F0501／G0401）。

public struct EInvoiceItem: Codable, Sendable, Hashable {
    public var sequence: Int
    public var description: String
    public var quantity: Int
    public var unitPrice: Money
    public var amount: Money
    public var taxKind: TaxKind

    public init(sequence: Int, description: String, quantity: Int, unitPrice: Money, amount: Money, taxKind: TaxKind = .taxable) {
        self.sequence = sequence; self.description = description; self.quantity = quantity
        self.unitPrice = unitPrice; self.amount = amount; self.taxKind = taxKind
    }
}

public struct EInvoice: Codable, Sendable, Hashable {
    /// 字軌＋8 碼（AB12345678）
    public var number: String
    /// 4 碼隨機碼
    public var randomCode: String
    /// 期別：民國年 3 碼＋雙數月 2 碼（11510 = 115 年 9–10 月）
    public var period: String
    public var issuedAt: Date
    public var sellerTaxId: String
    public var sellerName: String
    public var sellerAddress: String
    public var buyer: InvoiceBuyer
    /// 買方名稱（B2B 的公司抬頭；B2C 不填）
    public var buyerName: String?
    public var items: [EInvoiceItem]
    /// 應稅銷售額：B2B 是未稅金額；B2C 是含稅金額（證明聯不分開列稅）
    public var salesAmount: Money
    public var zeroTaxSalesAmount: Money
    public var freeTaxSalesAmount: Money
    public var taxAmount: Money
    public var totalAmount: Money
    /// 1 應稅、2 零稅率、3 免稅、9 混合
    public var taxType: Int
    public var taxRateBps: Int
    /// 有沒有印證明聯
    public var printed: Bool
    public var ticketId: String
    public var deviceId: String
    /// 號碼段（配發給這台的那一本）
    public var rollId: String

    public init(number: String, randomCode: String, period: String, issuedAt: Date, sellerTaxId: String, sellerName: String,
                sellerAddress: String, buyer: InvoiceBuyer, buyerName: String?, items: [EInvoiceItem], salesAmount: Money,
                zeroTaxSalesAmount: Money, freeTaxSalesAmount: Money, taxAmount: Money, totalAmount: Money, taxType: Int,
                taxRateBps: Int, printed: Bool, ticketId: String, deviceId: String, rollId: String) {
        self.number = number; self.randomCode = randomCode; self.period = period; self.issuedAt = issuedAt
        self.sellerTaxId = sellerTaxId; self.sellerName = sellerName; self.sellerAddress = sellerAddress; self.buyer = buyer
        self.buyerName = buyerName; self.items = items; self.salesAmount = salesAmount; self.zeroTaxSalesAmount = zeroTaxSalesAmount
        self.freeTaxSalesAmount = freeTaxSalesAmount; self.taxAmount = taxAmount; self.totalAmount = totalAmount
        self.taxType = taxType; self.taxRateBps = taxRateBps; self.printed = printed; self.ticketId = ticketId
        self.deviceId = deviceId; self.rollId = rollId
    }

    public var isB2B: Bool { buyer.buyerTaxId != nil }

    public var stamp: InvoiceStamp {
        InvoiceStamp(number: number, randomCode: randomCode, period: period, issuedAt: issuedAt, buyer: buyer, total: totalAmount)
    }
}

/// 折讓單（退一部分、或跨期退款）
public struct EInvoiceAllowance: Codable, Sendable, Hashable {
    /// 折讓證明單號碼（店內自編，16 碼內）
    public var number: String
    public var issuedAt: Date
    public var originalInvoiceNumber: String
    public var originalInvoiceDate: Date
    public var sellerTaxId: String
    public var buyerTaxId: String?
    public var items: [EInvoiceItem]
    /// 折讓的未稅金額（B2C：含稅）
    public var amount: Money
    public var taxAmount: Money
    public var reason: String

    public init(number: String, issuedAt: Date, originalInvoiceNumber: String, originalInvoiceDate: Date, sellerTaxId: String,
                buyerTaxId: String?, items: [EInvoiceItem], amount: Money, taxAmount: Money, reason: String) {
        self.number = number; self.issuedAt = issuedAt; self.originalInvoiceNumber = originalInvoiceNumber
        self.originalInvoiceDate = originalInvoiceDate; self.sellerTaxId = sellerTaxId; self.buyerTaxId = buyerTaxId
        self.items = items; self.amount = amount; self.taxAmount = taxAmount; self.reason = reason
    }

    public var total: Money { amount + taxAmount }
}
