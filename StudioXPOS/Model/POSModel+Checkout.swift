import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 結帳：收款（可以分好幾種付）、發票（紙本／載具／統編／捐贈）、結帳、印；退款、補開、改統編
extension POSModel {
    // MARK: 進出結帳畫面

    func beginCheckout(_ t: Ticket) {
        guard !t.activeLines.isEmpty else {
            show("還沒有點東西", tone: .warning)
            return
        }
        guard takesPayment else {
            show("這台是「\(role.label)」，請到結帳櫃台結帳（單子已經同步過去了）", tone: .info)
            return
        }
        // 手機離開店裡的 Wi-Fi（連不到櫃台的 iPad）：不能結帳（單子上的「結帳」本來就反灰，這裡是其他入口）
        guard phoneOnStoreWiFi else {
            show("和櫃台的 iPad 連同一個 Wi-Fi 才能結帳", tone: .info)
            return
        }
        // 現金模式：不進結帳畫面，應收多少收多少現金、直接結帳（換貨單照平常：要先抵掉退回的）
        if cashModeActive && t.exchange == nil {
            Task { await cashCheckout(t) }
            return
        }
        keypad.cancel()
        // 折價券：改了品項、小計低於最低消費的，結帳前拿掉（提示說一聲；單子上之前已經提醒過）
        dropCouponBelowMinimum(t)
        selectedTicketId = t.id
        checkoutTicketId = t.id
        if ![.order, .floor, .orders, .appointments, .checkIn, .members].contains(section) { section = .order }
        // 外帶叫號：一進結帳就取號——結帳畫面、收據、廚房、叫號、QR 都是這一個號碼
        takeNumberForCheckout(t)
        // 換貨單：退回的商品先抵掉；抵完了（新的比較便宜或一樣）直接結帳、退差額
        if t.exchange != nil {
            applyExchangeCredit(t)
            if let fresh = state.tickets[t.id], fresh.totals.isPaidInFull {
                Task { await complete(fresh) }
            }
        }
    }

    /// 現金模式的結帳：應收多少就收多少現金（不找零）→ 開發票（單子上有載具就開到載具）→ 結帳、印。
    /// 不進結帳畫面（不會閃一下）。開不了發票：和平常一樣跳「開不了發票」（先結帳之後補開／取消）；
    /// 取消的話錢已經記上了，單子的大鍵變成「收現金 NT$0」，再按一次就是重新開發票、結帳
    func cashCheckout(_ given: Ticket) async {
        guard let me = currentStaff, let t0 = state.tickets[given.id], t0.isOpen else { return }
        guard !t0.activeLines.isEmpty else {
            show("還沒有點東西", tone: .warning)
            return
        }
        // 手機：和櫃台的 iPad 同一個 Wi-Fi 才能結帳；要印證明聯又沒有發票出單機（或金鑰）：先掃載具，不然到櫃台結
        guard phoneOnStoreWiFi else {
            show("和櫃台的 iPad 連同一個 Wi-Fi 才能結帳", tone: .info)
            return
        }
        guard !needsCounterForInvoice(t0) else {
            show("要印發票證明聯，這支手機印不了：先掃載具（或捐贈），不然這張請到櫃台結帳", tone: .warning)
            return
        }
        keypad.cancel()
        dropCouponBelowMinimum(t0)
        selectedTicketId = t0.id
        takeNumberForCheckout(t0)
        guard let t = state.tickets[t0.id] else { return }
        let due = t.totals.balance
        if due.cents > 0 {
            let p = Payment.cash(id: newID(), tendered: due, due: due, at: Date(), by: me.id, shiftId: openShift?.id)
            guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
            if settings.openDrawerOnCash { printers.openDrawer() }
        }
        lastChange = .zero
        if let paid = state.tickets[t.id], paid.totals.isPaidInFull { await complete(paid) }
    }

    func cancelCheckout() {
        keypad.cancel()
        if let t = checkoutTicket, t.exchange != nil { releaseExchangeCredit(t) }
        checkoutTicketId = nil
    }

    // MARK: 收款

    /// 收現金：右側鍵盤打客人給的錢（快速鍵：剛好、湊整的鈔票）；少於應收＝先收一部分（其他用別的方式付）
    func takeCash(_ t: Ticket) async {
        let due = t.totals.balance
        guard due.cents > 0, let me = currentStaff else { return }
        guard role.hasDrawer else {
            show("這台沒有錢櫃：現金請到結帳櫃台收，這裡可以刷卡或電子支付", tone: .warning)
            return
        }
        guard let tendered = await keypad.askMoney(.cashTendered(due: due, presets: store.cashQuickAmounts)), tendered.cents > 0 else { return }
        let p = Payment.cash(id: newID(), tendered: tendered, due: due, at: Date(), by: me.id, shiftId: openShift?.id)
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
        if settings.openDrawerOnCash { printers.openDrawer() }
        lastChange = p.change
        if let fresh = state.tickets[t.id], fresh.totals.isPaidInFull { await complete(fresh) }
    }

    /// 用會員的儲值金付（餘額＝後台的＋這台還沒同步的）
    func payWithPrepaid(_ t: Ticket) async {
        let due = t.totals.balance
        guard due.cents > 0, let me = currentStaff else { return }
        guard t.member?.id != nil else {
            show("先找會員才能用儲值金", tone: .warning)
            await attachMember(to: t)
            return
        }
        if member(for: t.member) == nil { await refreshMember(t.member) }
        guard let acct = account(for: t.member), acct.wallet.cents > 0 else {
            show("這位會員沒有儲值金", tone: .warning)
            return
        }
        guard let amount = await keypad.askMoney(.prepaid(balance: acct.wallet, due: due)), amount.cents > 0 else { return }
        let p = Payment(id: newID(), tender: .prepaid, amount: amount, reference: t.member?.maskedPhone, at: Date(), by: me.id, shiftId: openShift?.id)
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else { return }
        lastChange = .zero
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
        // 用儲值金付的（儲值時開過）、用課程卡抵的不重開；全部都是就不用開
        let invoiceable = InvoiceBuilder.coverage(for: t, prepaid: store.prepaidInvoicing).amount
        if !skipInvoice, features.invoice, invoiceSettings.enabled, invoiceable.cents > 0 {
            do {
                invoice = try InvoiceBuilder.issue(ticket: t, settings: invoiceSettings, allocator: allocator, deviceId: device.id, at: Date(),
                                                   prepaid: store.prepaidInvoicing)
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
        // 換貨單：原單的退款（換貨抵用＋發票作廢或折讓）和新單一起記
        bodies += exchangeSettlement(for: t)
        bodies.append(.ticketClosed(TicketClosed(ticketId: t.id, sale: sale)))
        // 先寫進日誌（fsync）才印：就算出單機卡紙、App 當掉，這筆帳也在
        guard record(bodies) else { return }

        if let invoice, invoice.printed {
            printers.printInvoice(InvoiceProof(invoice: invoice, storeName: store.name, qrKey: invoiceSettings.qrKey), detail: sale, store: store)
        }
        // 叫號用在外帶取餐：取餐號碼就是叫號的號碼（一進結帳就取了；沒取到的這時候再取）
        if takesTakeoutNumber(t) {
            await completeTakeout(t, sale: sale, unsent: unsent, toKitchen: toKitchen)
            return
        }
        // 櫃台、咖啡：客人要拿取餐號碼等叫號，一定印（號碼印在最上面、很大）
        let pickup = mode.printsPickupNumber && t.tableIds.isEmpty ? Templates.pickupNumber(t.number) : nil
        // 會員帳戶有變（儲值、扣卡、用儲值金付）：收據一定印，讓客人看到餘額
        let touchesAccount = sale.lines.contains { $0.redeem != nil || $0.kind == .pass || $0.kind == .storedValue }
            || sale.payments.contains { $0.tender == .prepaid }
        if let pickup {
            printers.print(receipt(for: sale, pickupNumber: pickup), role: .receipt)
        } else if touchesAccount {
            printers.print(receipt(for: sale), role: .receipt)
        } else {
            switch settings.receiptMode {
            case "always": printers.print(receipt(for: sale), role: .receipt)
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
        if t.exchange != nil, lastChange.cents > 0, settings.openDrawerOnCash { printers.openDrawer() }
        let change = lastChange.cents > 0 ? (t.exchange != nil ? "・退差額 \(lastChange.formatted)" : "・找零 \(lastChange.formatted)") : ""
        let number = pickup.map { "取餐 \($0)・" } ?? ""
        show("已結帳 \(number)\(t.number) \(sale.total.formatted)\(change)")
        Task { await topUpInvoiceRolls() }
    }

    /// 外帶單結帳完成（叫號用在外帶取餐）：畫面先回到點餐（下一位客人可以點了）→ 取號（最多等 5 秒）→
    /// 號碼掛在單子上、印號碼牌、收據的取餐號碼是叫號的號碼、右欄的叫號卡大大地顯示「24 號」。
    /// 叫號連不上也照樣結帳：收據照印（沒有取餐號碼），之後在「訂單」這一筆按「補取號」
    private func completeTakeout(_ t: Ticket, sale: SaleRecord, unsent: [TicketLine], toKitchen: Bool) async {
        let kitchenLines = !unsent.isEmpty && toKitchen && settings.printKitchenTickets ? unsent : []
        let kitchenMode: Templates.KitchenMode = t.lines.contains(where: \.isSent) ? .add : .new
        lastSale = sale
        checkoutTicketId = nil
        selectedTicketId = nil
        if t.exchange != nil, lastChange.cents > 0, settings.openDrawerOnCash { printers.openDrawer() }
        let change = lastChange.cents > 0 ? (t.exchange != nil ? "・退差額 \(lastChange.formatted)" : "・找零 \(lastChange.formatted)") : ""
        Task { await topUpInvoiceRolls() }

        let result = await takeTakeoutNumber(for: t, sale: sale)
        if lastSale?.ticketId == t.id, let fresh = state.sales[t.id] { lastSale = fresh }
        switch result {
        case .taken(let n):
            printTakeoutSlips(t, sale: sale, number: n, kitchenLines: kitchenLines, kitchenMode: kitchenMode)
            flashTakeout(n, ticket: t)
            // 單號不寫（客人只認取餐號碼）
            show("已結帳 \(sale.total.formatted)・取餐號碼 \(n) 號\(change)")
        case .failed:
            printTakeoutSlips(t, sale: sale, number: nil, kitchenLines: kitchenLines, kitchenMode: kitchenMode)
            show("已結帳 \(sale.total.formatted)\(change)・叫號連不上，沒有取到號碼：連上後到「訂單」\(t.number) 這一筆按「補取號」", tone: .warning)
        case .late:
            // 廚房先做；收據、號碼牌等號碼回來再印（takeTakeoutNumber 接手）
            if !kitchenLines.isEmpty { printKitchen(t, lines: kitchenLines, mode: kitchenMode) }
            show("已結帳 \(sale.total.formatted)\(change)・叫號比較慢，號碼取到了會自動印出來", tone: .info)
        }
    }

    /// 交易明細：服務人員的名字、會員帳戶的餘額（儲值金、還能用的課程卡）。
    /// 外帶單有叫號的號碼（結帳後才取到的也算）：取餐號碼印叫號的號碼
    func receipt(for sale: SaleRecord, reprint: Bool = false, pickupNumber: String? = nil) -> Receipt {
        var names: [String: String] = [:]
        for s in staff { names[s.id] = s.name }
        let queued = sale.orderType == .dineIn ? nil
            : (state.sales[sale.ticketId]?.queueNumber ?? state.tickets[sale.ticketId]?.queueNumber ?? sale.queueNumber)
        // 叫號的號碼：號碼下面印 QR（掃了看叫到幾號、大約還要等多久）
        let link = queued.flatMap { queueLink($0, waiting: queue.state?.waiting.count ?? 0, day: sale.businessDate) }
        return Templates.saleReceipt(sale, store: store, reprint: reprint, pickupNumber: queued.map { String($0) } ?? pickupNumber,
                                     pickupLink: link, staffNames: names,
                                     accountLines: reprint ? [] : accountLines(for: sale.member))
    }

    /// 「儲值金餘額 8,500」「剪髮 10 次卡 剩 9 次・到 2027/3/20」
    func accountLines(for ref: MemberRef?) -> [String] {
        guard let acct = account(for: ref) else { return [] }
        var out: [String] = []
        if acct.wallet.cents != 0 || member(for: ref)?.wallet != nil { out.append("儲值金餘額 \(acct.wallet.plain)") }
        for p in acct.usablePasses(at: Date()) { out.append("\(p.name) \(p.statusText(at: Date()))") }
        return out
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
            let inv = try InvoiceBuilder.issue(ticket: t, settings: invoiceSettings, allocator: allocator, deviceId: device.id, at: Date(),
                                               prepaid: store.prepaidInvoicing)
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
        printers.print(receipt(for: sale, reprint: reprint), role: .receipt)
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
            let inv = try InvoiceBuilder.issue(ticket: reopened, settings: invoiceSettings, allocator: alloc, deviceId: device.id, at: Date(),
                                               prepaid: store.prepaidInvoicing)
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

    /// 退款：右側鍵盤打金額（預設全部）；同一期整張退＝發票作廢，其他＝折讓單。
    /// lines：退哪幾件（服飾、課程卡、儲值）——金額照原單實收算好、不再問；庫存、課程卡、儲值金跟著退
    func refund(_ sale: SaleRecord, tender: Tender, reason: String, lines: [String: Int] = [:]) async {
        guard let t = state.tickets[sale.ticketId], let me = currentStaff else { return }
        guard takesPayment else {
            show("這台是「\(role.label)」，退款請到結帳櫃台", tone: .info)
            return
        }
        if tender == .cash && !role.hasDrawer {
            show("這台沒有錢櫃：現金退款請到結帳櫃台", tone: .warning)
            return
        }
        guard let auth = await authorize(.refund, detail: "\(sale.number) 退款") else { return }
        let refundable = sale.total + sale.tip - t.refundedAmount
        guard refundable.cents > 0 else {
            show("這張單已經全部退完了", tone: .neutral)
            return
        }
        let already = sale.refundedQuantities(t.refunds)
        // 卡抵的行金額是 0 也要列（退了才會還回次數）
        let itemised: [RefundLine] = lines.compactMap { lineId, q in
            guard q > 0, sale.lines.contains(where: { $0.lineId == lineId }) else { return nil }
            let amount = sale.refundAmount(lineId: lineId, quantity: q, alreadyRefunded: already[lineId] ?? 0)
            return RefundLine(lineId: lineId, quantity: q, amount: amount)
        }.sorted { $0.lineId < $1.lineId }
        // 這次退完之後每一件都退了：服務費、小費這些剩下的也一起退
        let everyLine = !itemised.isEmpty && sale.lines.allSatisfy { l in
            (already[l.lineId] ?? 0) + (itemised.first { $0.lineId == l.lineId }?.quantity ?? 0) >= l.quantity
        }
        let amount: Money
        if itemised.isEmpty {
            guard let typed = await keypad.askMoney(.refund(max: refundable)) else { return }
            amount = typed
        } else if everyLine {
            amount = refundable
        } else {
            amount = min(Money.sum(itemised.map(\.amount)), refundable)
        }
        guard amount.cents > 0 || itemised.contains(where: { $0.amount.isZero }) else { return }
        // 整張退：沒有退過、而且金額是全部（或每一件都退了）
        let full = t.refunds.isEmpty && (amount == refundable || everyLine)
        let invoice = t.invoice.flatMap { state.invoices[$0.number] }
        let action = (invoice != nil && t.invoice?.isVoided == false) ? InvoiceBuilder.refundAction(invoice: invoice, isFullRefund: full, at: Date()) : .none
        var refund = Refund(id: newID(), amount: amount, tender: tender, lines: full ? [] : itemised, reason: reason, invoiceAction: action, at: Date(),
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
