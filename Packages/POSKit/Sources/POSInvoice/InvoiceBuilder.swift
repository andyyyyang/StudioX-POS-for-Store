import Foundation
import POSCore

/// 店家的發票設定（bootstrap 傳來的）
public struct InvoiceSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var sellerTaxId: String
    public var sellerName: String
    public var sellerAddress: String
    /// 財政部「電子發票整合服務平台」給的 QR Code 加密金鑰（32 個十六進位字）。沒有就不能印證明聯的 QR Code
    public var qrKey: String?
    /// 這台 iPad 的號碼段
    public var rolls: [InvoiceRoll]

    public init(enabled: Bool, sellerTaxId: String, sellerName: String, sellerAddress: String = "", qrKey: String? = nil, rolls: [InvoiceRoll] = []) {
        self.enabled = enabled; self.sellerTaxId = sellerTaxId; self.sellerName = sellerName
        self.sellerAddress = sellerAddress; self.qrKey = qrKey; self.rolls = rolls
    }

    public static let disabled = InvoiceSettings(enabled: false, sellerTaxId: "", sellerName: "")

    /// 能不能開（設定齊了）
    public var problem: String? {
        if !enabled { return "這家店沒有開電子發票" }
        if !InvoiceValidation.isTaxId(sellerTaxId) { return "後台的賣方統一編號不對" }
        if sellerName.isEmpty { return "後台沒有填營業人名稱" }
        return nil
    }
}

public enum InvoiceError: Error, Equatable, Sendable {
    case notConfigured(String)
    case noNumbers(period: String)
    case invalidBuyer(String)
    case nothingToInvoice
}

/// 單子 → 電子發票
public enum InvoiceBuilder {
    /// 發票品項：每一行照原價列，折扣、服務費各一行（加起來剛好等於總計）。
    /// 品名帶加料（「珍珠奶茶（半糖・少冰）」）；超過 256 字截掉（MIG 的長度上限）
    public static func items(for ticket: Ticket) -> [EInvoiceItem] {
        let totals = ticket.totals
        var out: [EInvoiceItem] = []
        var seq = 1
        for line in ticket.activeLines {
            let name = line.modifiers.isEmpty ? line.name : "\(line.name)（\(line.modifierText)）"
            out.append(EInvoiceItem(sequence: seq, description: String(name.prefix(256)), quantity: line.quantity,
                                    unitPrice: line.unitTotal, amount: line.gross, taxKind: line.taxKind))
            seq += 1
        }
        if totals.discountTotal.cents > 0 {
            let reason = ticket.discount?.reason.isEmpty == false ? "折扣（\(ticket.discount!.reason)）" : "折扣"
            out.append(EInvoiceItem(sequence: seq, description: reason, quantity: 1, unitPrice: -totals.discountTotal, amount: -totals.discountTotal))
            seq += 1
        }
        if totals.serviceCharge.cents > 0 {
            out.append(EInvoiceItem(sequence: seq, description: "服務費", quantity: 1, unitPrice: totals.serviceCharge, amount: totals.serviceCharge))
        }
        return out
    }

    /// 開一張發票（還沒存、還沒印）。號碼由 allocator 給；呼叫的人要先把 invoiceIssued 事件寫進日誌再印
    public static func issue(ticket: Ticket, settings: InvoiceSettings, allocator: InvoiceAllocator, deviceId: String,
                             at date: Date, randomCode: String = InvoiceBuilder.randomCode()) throws -> EInvoice {
        if let p = settings.problem { throw InvoiceError.notConfigured(p) }
        if let p = ticket.invoiceBuyer.problem { throw InvoiceError.invalidBuyer(p) }
        let totals = ticket.totals
        guard totals.total.cents > 0 else { throw InvoiceError.nothingToInvoice }
        let period = InvoicePeriod(date: date)
        guard let (number, roll) = allocator.next(period: period) else { throw InvoiceError.noNumbers(period: period.code) }

        let items = items(for: ticket)
        // 課稅別：餐飲幾乎都是應稅；有零稅率／免稅品項時分開加總、TaxType = 9（混合）
        let byKind = Dictionary(grouping: ticket.activeLines, by: \.taxKind)
        let kinds = Set(byKind.keys)
        let zero = Money.sum((byKind[.zeroRated] ?? []).map { l in totals.lines.first { $0.lineId == l.id }?.net ?? l.gross })
        let free = Money.sum((byKind[.exempt] ?? []).map { l in totals.lines.first { $0.lineId == l.id }?.net ?? l.gross })
        let taxableInclusive = totals.total - zero - free
        let taxType = kinds.count > 1 ? 9 : (kinds.first ?? .taxable).rawValue

        let buyerTaxId = ticket.invoiceBuyer.buyerTaxId
        let sales: Money, tax: Money
        if buyerTaxId != nil {
            // 打統編：銷售額是未稅、稅額分開列
            (sales, tax) = Tax.split(inclusive: taxableInclusive)
        } else {
            // 一般消費者：銷售額就是含稅金額、稅額 0（證明聯只印總計）
            (sales, tax) = (taxableInclusive, .zero)
        }
        var buyerName: String? = nil
        if case .business(_, let title) = ticket.invoiceBuyer { buyerName = title }

        return EInvoice(
            number: number, randomCode: randomCode, period: period.code, issuedAt: date,
            sellerTaxId: settings.sellerTaxId, sellerName: settings.sellerName, sellerAddress: settings.sellerAddress,
            buyer: ticket.invoiceBuyer, buyerName: buyerName, items: items, salesAmount: sales,
            zeroTaxSalesAmount: zero, freeTaxSalesAmount: free, taxAmount: tax, totalAmount: totals.total,
            taxType: taxType, taxRateBps: Tax.standardRateBps, printed: ticket.invoiceBuyer.printsProof,
            ticketId: ticket.id, deviceId: deviceId, rollId: roll.id
        )
    }

    /// 4 碼隨機碼
    public static func randomCode() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%04d", Int.random(in: 0...9999, using: &g))
    }

    /// 折讓單（部分退款、跨期退款）
    public static func allowance(for invoice: EInvoice, refund: Refund, ticket: Ticket, number: String, at date: Date) -> EInvoiceAllowance {
        let refundTotal = refund.amount.roundedToDollar()
        var items: [EInvoiceItem] = []
        if refund.lines.isEmpty {
            items = [EInvoiceItem(sequence: 1, description: "退貨折讓", quantity: 1, unitPrice: refundTotal, amount: refundTotal)]
        } else {
            for (i, rl) in refund.lines.enumerated() {
                let name = ticket.lines.first { $0.id == rl.lineId }?.name ?? "品項"
                let unit = rl.quantity > 0 ? Money(dollars: Int((Double(rl.amount.dollars) / Double(rl.quantity)).rounded())) : rl.amount
                items.append(EInvoiceItem(sequence: i + 1, description: name, quantity: rl.quantity, unitPrice: unit, amount: rl.amount))
            }
        }
        let (amount, tax) = invoice.isB2B ? Tax.split(inclusive: refundTotal) : (refundTotal, .zero)
        return EInvoiceAllowance(number: number, issuedAt: date, originalInvoiceNumber: invoice.number, originalInvoiceDate: invoice.issuedAt,
                                 sellerTaxId: invoice.sellerTaxId, buyerTaxId: invoice.buyer.buyerTaxId, items: items,
                                 amount: amount, taxAmount: tax, reason: refund.reason)
    }

    /// 退款時發票要作廢還是折讓：同一期、整張退 → 作廢；其他 → 折讓
    public static func refundAction(invoice: EInvoice?, isFullRefund: Bool, at date: Date) -> InvoiceRefundAction {
        guard let invoice else { return .none }
        let samePeriod = InvoicePeriod(date: invoice.issuedAt) == InvoicePeriod(date: date)
        return samePeriod && isFullRefund ? .void : .allowance
    }
}
