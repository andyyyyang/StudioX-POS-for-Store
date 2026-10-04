import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 結帳：收款（可以分好幾種付）、發票（紙本／載具／統編／捐贈）、結帳、印；退款、補開、改統編
extension POSModel {
    // MARK: 進出結帳畫面

    func beginCheckout(_ t: Ticket) {
        guard !t.activeLines.isEmpty else {
            show("還沒有點東西", tone: .warning)
            return
        }
        keypad.cancel()
        selectedTicketId = t.id
        checkoutTicketId = t.id
        if section != .order && section != .floor && section != .orders { section = .order }
    }

    func cancelCheckout() {
        keypad.cancel()
        checkoutTicketId = nil
    }

    // MARK: 收款

    /// 收現金：右側鍵盤打客人給的錢（快速鍵：剛好、湊整的鈔票）；少於應收＝先收一部分（其他用別的方式付）
    func takeCash(_ t: Ticket) async {
        let due = t.totals.balance
        guard due.cents > 0, let me = currentStaff else { return }
        guard let tendered = await keypad.askMoney(.cashTendered(due: due, presets: store.cashQuickAmounts)), tendered.cents > 0 else { return }
        let p = Payment.cash(id: newID(), tendered: tendered, due: due, at: Date(), by: me.id, shiftId: openShift?.id)
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
        if settings.openDrawerOnCash { printers.openDrawer() }
        lastChange = p.change
        if let fresh = state.tickets[t.id], fresh.totals.isPaidInFull { await complete(fresh) }
    }

    /// 刷卡、電子支付、禮券：金額預設是剩下的（右側鍵盤可以改成只付一部分），刷卡再問末四碼（給對帳用，可以跳過）
    func take(_ tender: Tender, for t: Ticket) async {
        let due = t.totals.balance
        guard due.cents > 0, let me = currentStaff else { return }
        guard let amount = await keypad.askMoney(KeypadSpec(
            kind: .money, title: tender.label, subtitle: "剩 \(due.formatted)", initial: String(due.dollars),
            quickKeys: [.init("全部", digits: String(due.dollars), commits: true)], confirmLabel: "收款", maxValue: due.dollars, minValue: 1
        )) else { return }
        var last4: String? = nil
        var reference: String? = nil
        if tender == .card {
            last4 = await keypad.ask(KeypadSpec(kind: .code(minLength: 4, maxLength: 4), title: "卡號末四碼", subtitle: "刷卡機上的單據（可以跳過）", confirmLabel: "完成"))?.digits
        } else if tender.isWallet || tender == .stored {
            reference = await keypad.ask(KeypadSpec(kind: .code(minLength: 4, maxLength: 20), title: "交易序號", subtitle: "\(tender.label) 的交易序號末幾碼（可以跳過）", confirmLabel: "完成"))?.digits
        }
        let p = Payment(id: newID(), tender: tender, amount: amount, reference: reference, cardLast4: last4, at: Date(), by: me.id, shiftId: openShift?.id)
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
        lastChange = .zero
        if let fresh = state.tickets[t.id], fresh.totals.isPaidInFull { await complete(fresh) }
    }

    /// 平分：每個人付一份（右側鍵盤問幾個人）
    func splitEvenly(_ t: Ticket) async -> [Money]? {
        guard let ways = await keypad.askNumber(KeypadSpec(kind: .count, title: "平分", subtitle: "剩 \(t.totals.balance.formatted) 分給幾個人", quickKeys: [2, 3, 4, 5].map { .init("\($0) 人", digits: String($0)) }, confirmLabel: "平分", maxValue: 20, minValue: 2)) else { return nil }
        return TicketTotals.split(t.totals.balance, ways: ways)
    }

    func voidPayment(_ p: Payment, in t: Ticket) async {
        guard let auth = await authorize(.refund, detail: "退回 \(p.tender.label) \(p.amount.formatted)") else { return }
        record(.paymentVoided(PaymentVoided(ticketId: t.id, paymentId: p.id, reason: "結帳前退回", authorizedBy: auth.authorizerId)))
        if p.tender == .cash, settings.openDrawerOnCash { printers.openDrawer() }
    }

    func setTip(_ t: Ticket) async {
        guard let tip = await keypad.askMoney(.tip(base: t.totals.total)) else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, tip: tip)))
    }

    // MARK: 發票

    func setBuyer(_ buyer: InvoiceBuyer, for t: Ticket) {
        guard buyer != t.invoiceBuyer else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, invoiceBuyer: buyer)))
    }

    /// 統編：右側鍵盤（打滿 8 碼當場驗檢查碼）
    func askTaxId(for t: Ticket) async {
        var initial = KeypadSpec.taxId
        if case .business(let id, _) = t.invoiceBuyer { initial.initial = id }
        guard let e = await keypad.ask(initial) else { return }
        setBuyer(.business(taxId: e.digits, title: nil), for: t)
    }

    func askLoveCode(for t: Ticket) async {
        guard let e = await keypad.ask(.loveCode) else { return }
        setBuyer(.donation(loveCode: e.digits), for: t)
    }

    /// 手機條碼（掃描器、相機或手打）
    func setCarrier(_ raw: String, for t: Ticket) -> Bool {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if InvoiceValidation.isMobileBarcode(code) {
            setBuyer(.consumer(carrier: .mobileBarcode(code)), for: t)
            return true
        }
        if InvoiceValidation.isCitizenCertificate(code) {
            setBuyer(.consumer(carrier: .citizenCertificate(code)), for: t)
            return true
        }
        return false
    }

    // MARK: 結帳

    /// 收齊了：（開發票）→ 記結帳 → 印證明聯、交易明細、還沒送的廚房單
    func complete(_ given: Ticket, skipInvoice: Bool = false) async {
        guard let t = state.tickets[given.id], t.isOpen, t.totals.isPaidInFull, let me = currentStaff else { return }
        var bodies: [EventBody] = []
        let unsent = t.unsentLines
        let toKitchen = features.kitchen && mode.usesKitchen
        if !unsent.isEmpty && toKitchen {
            bodies.append(.linesSent(LinesSent(ticketId: t.id, lineIds: unsent.map(\.id))))
        }

        var invoice: EInvoice? = nil
        if !skipInvoice, features.invoice, invoiceSettings.enabled, t.totals.total.cents > 0 {
            do {
                invoice = try InvoiceBuilder.issue(ticket: t, settings: invoiceSettings, allocator: allocator, deviceId: device.id, at: Date())
            } catch let e as InvoiceError {
                pendingInvoiceFailure = InvoiceFailure(ticketId: t.id, message: Self.describe(e))
                return
            } catch {
                pendingInvoiceFailure = InvoiceFailure(ticketId: t.id, message: error.localizedDescription)
                return
            }
        }
        if let invoice { bodies.append(.invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: invoice))) }

        var closing = t
        closing.invoice = invoice?.stamp
        let sale = SaleRecord(ticket: closing, closedOn: device.id, shiftId: openShift?.id, closedAt: Date(), closedBy: me.id, staffName: me.name, floor: floor)
        bodies.append(.ticketClosed(TicketClosed(ticketId: t.id, sale: sale)))
        // 先寫進日誌（fsync）才印：就算出單機卡紙、App 當掉，這筆帳也在
        guard record(bodies) else { return }

        if let invoice, invoice.printed {
            printers.printInvoice(InvoiceProof(invoice: invoice, storeName: store.name, qrKey: invoiceSettings.qrKey), detail: sale, store: store)
        }
        // 櫃台、咖啡：客人要拿取餐號碼等叫號，一定印（號碼印在最上面、很大）
        let pickup = mode.printsPickupNumber && t.tableIds.isEmpty ? Templates.pickupNumber(t.number) : nil
        if let pickup {
            printers.print(Templates.saleReceipt(sale, store: store, pickupNumber: pickup), role: .receipt)
        } else {
            switch settings.receiptMode {
            case "always": printers.print(Templates.saleReceipt(sale, store: store), role: .receipt)
            case "ask": receiptOffer = sale
            default: break
            }
        }
        if !unsent.isEmpty && toKitchen && settings.printKitchenTickets {
            printKitchen(t, lines: unsent, mode: t.lines.contains(where: \.isSent) ? .add : .new)
        }
        lastSale = sale
        checkoutTicketId = nil
        selectedTicketId = nil
        let change = lastChange.cents > 0 ? "・找零 \(lastChange.formatted)" : ""
        let number = pickup.map { "取餐 \($0)・" } ?? ""
        show("已結帳 \(number)\(t.number) \(sale.total.formatted)\(change)")
        Task { await topUpInvoiceRolls() }
    }

    static func describe(_ e: InvoiceError) -> String {
        switch e {
        case .notConfigured(let m): m
        case .noNumbers(let p): "\(InvoicePeriod(code: p)?.label ?? p) 的發票號碼用完了（或還沒有字軌）。請到後台「門市 POS → 電子發票」新增字軌，連上網後這台會自動拿新的號碼。"
        case .invalidBuyer(let m): m
        case .nothingToInvoice: "金額是 0，不用開發票"
        }
    }

    /// 之後補開（結帳時號碼用完、斷網拿不到號碼段）
    func issueLateInvoice(for sale: SaleRecord) async {
        guard let t = state.tickets[sale.ticketId] else { return }
        do {
            let inv = try InvoiceBuilder.issue(ticket: t, settings: invoiceSettings, allocator: allocator, deviceId: device.id, at: Date())
            guard record(.invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: inv))) else { return }
            if inv.printed { printers.printInvoice(InvoiceProof(invoice: inv, storeName: store.name, qrKey: invoiceSettings.qrKey), detail: sale, store: store) }
            show("已補開 \(inv.stamp.display)")
        } catch let e as InvoiceError {
            alert = AlertInfo(title: "開不了發票", message: Self.describe(e))
        } catch {}
    }

    /// 補印證明聯（每張只能印一次正本；之後都是「補印」）
    func reprintInvoice(for sale: SaleRecord) async {
        guard let number = state.tickets[sale.ticketId]?.invoice?.number ?? sale.invoice?.number, let inv = state.invoices[number] else { return }
        guard await authorize(.reprintInvoice, detail: inv.stamp.display) != nil else { return }
        printers.printInvoice(InvoiceProof(invoice: inv, storeName: store.name, qrKey: invoiceSettings.qrKey, reprint: true), detail: nil, store: store)
    }

    func printReceipt(_ sale: SaleRecord, reprint: Bool = false) {
        printers.print(Templates.saleReceipt(sale, store: store, reprint: reprint), role: .receipt)
    }

    /// 結帳後客人才說要打統編：作廢原本那張、用同一筆交易重開（同一期才行）
    func changeBuyer(of sale: SaleRecord, to buyer: InvoiceBuyer) async {
        guard let t = state.tickets[sale.ticketId], let old = t.invoice, let oldInv = state.invoices[old.number] else { return }
        guard InvoicePeriod(date: oldInv.issuedAt) == invoicePeriod else {
            alert = AlertInfo(title: "不同期了", message: "這張發票是上一期開的，不能作廢重開。請客人用折讓、或下次消費時再打統編。")
            return
        }
        guard let auth = await authorize(.voidInvoice, detail: "作廢 \(old.display) 重開") else { return }
        var reopened = t
        reopened.invoiceBuyer = buyer
        do {
            var alloc = allocator
            alloc.markUsed(old.number)
            let inv = try InvoiceBuilder.issue(ticket: reopened, settings: invoiceSettings, allocator: alloc, deviceId: device.id, at: Date())
            guard record([
                .invoiceVoided(InvoiceVoided(ticketId: t.id, number: old.number, reason: "買方資料變更", authorizedBy: auth.authorizerId)),
                .ticketUpdated(TicketUpdated(ticketId: t.id, invoiceBuyer: buyer)),
                .invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: inv)),
            ]) else { return }
            if inv.printed { printers.printInvoice(InvoiceProof(invoice: inv, storeName: store.name, qrKey: invoiceSettings.qrKey), detail: nil, store: store) }
            show("已作廢 \(old.display)、重開 \(inv.stamp.display)")
        } catch let e as InvoiceError {
            alert = AlertInfo(title: "開不了發票", message: Self.describe(e))
        } catch {}
    }

    // MARK: 退款

    /// 退款：右側鍵盤打金額（預設全部）；同一期整張退＝發票作廢，其他＝折讓單
    func refund(_ sale: SaleRecord, tender: Tender, reason: String) async {
        guard let t = state.tickets[sale.ticketId], let me = currentStaff else { return }
        guard let auth = await authorize(.refund, detail: "\(sale.number) 退款") else { return }
        let refundable = sale.total + sale.tip - t.refundedAmount
        guard refundable.cents > 0 else {
            show("這張單已經全部退完了", tone: .neutral)
            return
        }
        guard let amount = await keypad.askMoney(.refund(max: refundable)) else { return }
        let full = amount == refundable && t.refunds.isEmpty
        let invoice = t.invoice.flatMap { state.invoices[$0.number] }
        let action = (invoice != nil && t.invoice?.isVoided == false) ? InvoiceBuilder.refundAction(invoice: invoice, isFullRefund: full, at: Date()) : .none
        var refund = Refund(id: newID(), amount: amount, tender: tender, reason: reason, invoiceAction: action, at: Date(),
                            by: me.id, authorizedBy: auth.authorizerId, shiftId: openShift?.id)
        var bodies: [EventBody] = []
        var allowance: EInvoiceAllowance? = nil
        switch action {
        case .void:
            if let invoice { bodies.append(.invoiceVoided(InvoiceVoided(ticketId: t.id, number: invoice.number, reason: reason, authorizedBy: auth.authorizerId))) }
        case .allowance:
            if let invoice {
                let number = "\(device.code)\(Self.allowanceStamp(Date()))"
                refund.allowanceNumber = number
                allowance = InvoiceBuilder.allowance(for: invoice, refund: refund, ticket: t, number: number, at: Date())
            }
        case .none:
            break
        }
        bodies.append(.saleRefunded(SaleRefunded(ticketId: t.id, refund: refund, allowance: allowance)))
        guard record(bodies) else { return }
        if tender == .cash, settings.openDrawerOnCash { printers.openDrawer() }
        printers.print(Self.refundSlip(sale: sale, refund: refund, allowance: allowance, store: store, staff: me.name), role: .receipt)
        show("已退款 \(amount.formatted)" + (action == .void ? "・發票已作廢" : action == .allowance ? "・開了折讓單" : ""))
    }

    /// 折讓單號：裝置字母＋時間（yyMMddHHmmss），同一台不會重複
    static func allowanceStamp(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return String(format: "%02d%02d%02d%02d%02d%02d", (c.year ?? 2026) % 100, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func refundSlip(sale: SaleRecord, refund: Refund, allowance: EInvoiceAllowance?, store: StoreProfile, staff: String) -> Receipt {
        var r = Receipt()
        r.add(.text(store.name, .title))
        r.add(.text("退款單", ReceiptStyle(align: .center, bold: true)))
        r.add(.rule)
        r.add(.row("原單號", sale.number, .body))
        r.add(.row("時間", TaipeiTime.dayString(refund.at) + " " + TaipeiTime.clock(refund.at), .body))
        r.add(.row("經手", staff, .body))
        r.add(.row("原因", refund.reason, .body))
        r.add(.rule)
        r.add(.row("退款（\(refund.tender.label)）", refund.amount.plain, .big))
        if let a = allowance {
            r.add(.rule)
            r.add(.text("營業人銷貨退回、進貨退出或折讓證明單", .strong))
            r.add(.row("折讓單號", a.number, .body))
            r.add(.row("原發票", a.originalInvoiceNumber, .body))
            r.add(.row("折讓金額", a.amount.plain, .body))
            if a.taxAmount.cents > 0 { r.add(.row("營業稅", a.taxAmount.plain, .body)) }
            r.add(.feed(2))
            r.add(.text("買受人簽章 ____________", .body))
        } else if refund.invoiceAction == .void {
            r.add(.text("原發票已作廢", .center))
        }
        r.add(.cut)
        return r
    }
}

/// 結帳時發票開不出來（號碼用完、設定不齊）：問要不要先結帳、之後補開
struct InvoiceFailure: Identifiable, Equatable {
    var id: String { ticketId }
    var ticketId: String
    var message: String
}
