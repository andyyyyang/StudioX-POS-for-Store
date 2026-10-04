import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 換貨（服飾、零售）
///
///   同款換規格（換尺寸、換顏色、價格一樣）：只記 sale.exchanged，不動錢、不動發票，後台調庫存
///   換別的商品：開一張「換貨單」，退回的品項當作付款（換貨抵用）；新的比較貴補差額、比較便宜退差額（現金）。
///   結帳那一刻同時記：原單的退款（換貨抵用、發票作廢或折讓）＋新單的結帳（新發票）
extension POSModel {
    /// 能不能換（店家設定的換貨天數內）
    func canExchange(_ sale: SaleRecord) -> Bool {
        guard mode.usesExchanges || store.exchangeDays > 0 else { return false }
        guard store.exchangeDays > 0 else { return true }
        return Date().timeIntervalSince(sale.closedAt) <= TimeInterval(store.exchangeDays * 86_400)
    }

    /// 這張單每一行還能退／換幾個
    func returnableQuantities(_ sale: SaleRecord) -> [String: Int] {
        let refunded = sale.refundedQuantities(state.tickets[sale.ticketId]?.refunds ?? [])
        var out: [String: Int] = [:]
        for l in sale.lines where l.redeem == nil && (l.kind ?? .goods) == .goods {
            out[l.lineId] = max(l.quantity - (refunded[l.lineId] ?? 0), 0)
        }
        return out
    }

    /// 同款換規格：結帳後換尺寸、換顏色（同價），不動錢、不動發票
    func swapVariant(in sale: SaleRecord, lineId: String, quantity: Int, to variant: ItemVariant, reason: String = "換尺寸") {
        guard let line = sale.lines.first(where: { $0.lineId == lineId }) else { return }
        let swap = VariantSwap(lineId: lineId, quantity: max(quantity, 1), fromSkuId: line.skuId, toSkuId: variant.id,
                               toVariantName: variant.label, toProductVariantId: variant.productVariantId)
        guard record(.saleExchanged(SaleExchanged(ticketId: sale.ticketId, swaps: [swap], reason: reason))) else { return }
        show("\(line.name) 換成 \(variant.label)")
    }

    /// 換別的商品：開一張換貨單（退回的品項值多少照原單實收），接著在點餐畫面加新的商品
    func startExchange(from sale: SaleRecord, returning quantities: [String: Int]) {
        let refunded = sale.refundedQuantities(state.tickets[sale.ticketId]?.refunds ?? [])
        let lines: [RefundLine] = quantities.compactMap { lineId, q in
            guard q > 0 else { return nil }
            let amount = sale.refundAmount(lineId: lineId, quantity: q, alreadyRefunded: refunded[lineId] ?? 0)
            return RefundLine(lineId: lineId, quantity: q, amount: amount)
        }.sorted { $0.lineId < $1.lineId }
        guard !lines.isEmpty else { return }
        let credit = ExchangeCredit(ticketId: sale.ticketId, number: sale.number, lines: lines, amount: Money.sum(lines.map(\.amount)))
        guard let t = openTicket(type: mode.defaultOrderType, member: sale.member, salespersonId: currentStaff?.id, exchange: credit) else { return }
        selectedTicketId = t.id
        section = .order
        show("換貨單 \(t.number)：退回 \(credit.amount.formatted)，請加要換的商品", tone: .info)
    }

    /// 進結帳時把換貨抵用記成一筆付款（新的比較便宜：差額記在找零，從錢櫃退現金）
    func applyExchangeCredit(_ t: Ticket) {
        guard let x = t.exchange, t.isOpen, let me = currentStaff else { return }
        guard !t.approvedPayments.contains(where: { $0.tender == .exchange }) else { return }
        let due = t.totals.amountDue
        let used = min(x.amount, due)
        let back = x.amount - used
        let p = Payment(id: newID(), tender: .exchange, amount: used, change: back, reference: x.number, at: Date(), by: me.id, shiftId: openShift?.id)
        record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p)))
        if back.cents > 0 { lastChange = back }
    }

    /// 離開結帳（回去加商品）：換貨抵用先拿掉，回來再照新的金額算
    func releaseExchangeCredit(_ t: Ticket) {
        guard t.isOpen else { return }
        for p in t.approvedPayments where p.tender == .exchange {
            record(.paymentVoided(PaymentVoided(ticketId: t.id, paymentId: p.id, reason: "回去改商品")))
        }
    }

    /// 結帳時一起記的：原單的退款（換貨抵用）與它的發票處理（同一期整張退＝作廢，其他＝折讓）
    func exchangeSettlement(for t: Ticket) -> [EventBody] {
        guard let x = t.exchange, let original = state.tickets[x.ticketId], let me = currentStaff else { return [] }
        let sale = state.sales[x.ticketId]
        let returnedAll = sale.map { s in
            let already = s.refundedQuantities(original.refunds)
            return s.lines.allSatisfy { l in (already[l.lineId] ?? 0) + (x.lines.first { $0.lineId == l.lineId }?.quantity ?? 0) >= l.quantity }
        } ?? false
        let invoice = original.invoice.flatMap { $0.isVoided ? nil : state.invoices[$0.number] }
        let action = InvoiceBuilder.refundAction(invoice: invoice, isFullRefund: returnedAll, at: Date())
        var refund = Refund(id: newID(), amount: x.amount, tender: .exchange, lines: returnedAll ? [] : x.lines, reason: "換貨（\(t.number)）",
                            invoiceAction: action, at: Date(), by: me.id, shiftId: openShift?.id)
        var bodies: [EventBody] = []
        var allowance: EInvoiceAllowance? = nil
        if action == .void, let invoice {
            bodies.append(.invoiceVoided(InvoiceVoided(ticketId: original.id, number: invoice.number, reason: "換貨")))
        } else if action == .allowance, let invoice {
            let number = "\(device.code)\(Self.allowanceStamp(Date()))"
            refund.allowanceNumber = number
            allowance = InvoiceBuilder.allowance(for: invoice, refund: refund, ticket: original, number: number, at: Date())
        }
        bodies.append(.saleRefunded(SaleRefunded(ticketId: original.id, refund: refund, allowance: allowance)))
        return bodies
    }
}
