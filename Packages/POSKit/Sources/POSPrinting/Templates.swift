import Foundation
import POSCore
import POSInvoice

/// 各種單據的版面。文字都是繁體中文、金額不寫「NT$」（收據上都是新台幣）
public enum Templates {
    // MARK: 交易明細（收據）

    /// pickupNumber：櫃台、咖啡模式的取餐號碼（印在最上面、很大，客人拿著等叫號）
    /// staffNames：服務人員 id → 名字（美業、課程每一行印是誰做的）
    /// accountLines：結帳後的會員帳戶（「儲值金餘額 8,500」「剪髮 10 次卡 剩 9 次」）
    /// pickupLink：叫號的號碼的網頁（掃了看叫到幾號、大約還要等多久）。有的話號碼下面印 QR，
    /// 單號那一行改成取餐號碼（客人手上只有一個號碼），交易序號放到最下面（退貨、查帳用）
    public static func saleReceipt(_ sale: SaleRecord, store: StoreProfile, reprint: Bool = false, pickupNumber: String? = nil,
                                   pickupLink: String? = nil,
                                   staffNames: [String: String] = [:], accountLines: [String] = []) -> Receipt {
        var r = Receipt(doc: pickupNumber == nil ? .receipt : .pickup)
        if let pickupNumber {
            r.add(.text("取餐號碼", ReceiptStyle(align: .center, bold: true)))
            r.add(.text(pickupNumber, ReceiptStyle(align: .center, bold: true, scale: 3)))
            if let pickupLink {
                r.add(.qr(pickupLink))
                r.add(.text("掃描看叫到幾號、大約還要等多久", .center))
            }
            r.add(.doubleRule)
        }
        let queued = pickupNumber != nil && pickupLink != nil
        let top = r.blocks.count
        r.add(.text(store.name, .title))
        if !store.address.isEmpty { r.add(.text(store.address, .center)) }
        if !store.phone.isEmpty { r.add(.text("電話 \(store.phone)", .center)) }
        r.storeHeader = top..<r.blocks.count
        r.add(.text(reprint ? "交易明細（補印）" : "交易明細", ReceiptStyle(align: .center, bold: true)))
        r.add(.rule)
        let showsType = sale.serviceMode?.showsOrderType ?? true
        let where_ = showsType ? sale.orderType.label + (sale.tableNames.isEmpty ? "" : " \(sale.tableNames)") : (sale.customerName ?? "")
        r.add(.row(queued ? "取餐 \(pickupNumber ?? "") 號" : "單號 \(sale.number)", where_, .strong))
        r.add(.row(TaipeiTime.dayString(sale.closedAt) + " " + TaipeiTime.clock(sale.closedAt), sale.staffName, .body))
        if sale.guests > 0 { r.add(.text("人數 \(sale.guests)", .body)) }
        r.add(.rule)
        let perLine = sale.serviceMode?.staffPerLine ?? false
        let title = sale.serviceMode?.staffTitle ?? "服務人員"
        for l in sale.lines {
            r.add(.row("\(l.displayName) ×\(l.quantity)", l.redeem != nil ? "卡抵" : l.gross.plain, .body))
            if !l.modifiers.isEmpty { r.add(.detail(l.modifiers)) }
            if let rd = l.redeem { r.add(.detail("用「\(rd.name)」抵 \(l.quantity) 次")) }
            if perLine, let who = l.staffId.flatMap({ staffNames[$0] }) {
                r.add(.detail("\(title) \(who)" + (l.assistantId.flatMap { staffNames[$0] }.map { "・助理 \($0)" } ?? "")))
            }
        }
        if let x = sale.exchange { r.add(.detail("換貨：原單 \(x.number) 退回 \(x.lines.reduce(0) { $0 + $1.quantity }) 件")) }
        r.add(.rule)
        r.add(.row("小計", sale.itemsGross.plain, .body))
        if sale.discount.cents > 0 { r.add(.row("折扣" + (sale.discountReason.map { "（\($0)）" } ?? ""), "−" + sale.discount.plain, .body)) }
        // 門市折價券：印代碼（客人對得到是哪一張；退款時店員也看得到）
        if let code = sale.couponCode { r.add(.detail("折價券代碼 \(code)")) }
        if sale.serviceCharge.cents > 0 { r.add(.row("服務費", sale.serviceCharge.plain, .body)) }
        r.add(.row("總計", sale.total.plain, .big))
        if sale.tip.cents > 0 { r.add(.row("小費", sale.tip.plain, .body)) }
        r.add(.text("（含營業稅 \(sale.tax.plain)）", ReceiptStyle(align: .right)))
        r.add(.rule)
        for p in sale.payments {
            r.add(.row(p.tender.label + (p.cardLast4.map { " *\($0)" } ?? ""), (p.tendered ?? p.amount).plain, .body))
            if p.change.cents > 0 { r.add(.row("找零", p.change.plain, .body)) }
        }
        if let inv = sale.invoice {
            r.add(.rule)
            r.add(.row("發票", inv.display, .body))
            r.add(.detail(inv.buyer.summary))
        }
        if let m = sale.member {
            r.add(.row("會員", (m.name ?? "") + " " + m.maskedPhone, .body))
            for line in accountLines { r.add(.detail(line)) }
        }
        if queued { r.add(.detail("交易序號 \(sale.number)")) }
        if !store.receiptFooter.isEmpty {
            r.add(.feed(1))
            r.add(.text(store.receiptFooter, .center))
        }
        r.add(.cut)
        return r
    }

    // MARK: 結帳單（內用，客人要買單時先印給他看）

    public static func bill(_ t: Ticket, store: StoreProfile, floor: FloorPlan) -> Receipt {
        let x = t.totals
        var r = Receipt(doc: .bill)
        r.add(.text(store.name, .title))
        r.storeHeader = 0..<r.blocks.count
        r.add(.text("結帳單", ReceiptStyle(align: .center, bold: true)))
        r.add(.rule)
        r.add(.row(t.title(floor: floor), "單號 \(t.number)", .strong))
        if t.guests > 0 { r.add(.text("人數 \(t.guests)", .body)) }
        r.add(.rule)
        for l in t.activeLines {
            r.add(.row("\(l.name) ×\(l.quantity)", l.gross.plain, .body))
            if !l.modifiers.isEmpty { r.add(.detail(l.modifierText)) }
            if let d = l.discount { r.add(.detail("\(d.label)  −\(l.lineDiscount.plain)")) }
        }
        r.add(.rule)
        r.add(.row("小計", x.subtotal.plain, .body))
        if x.orderDiscount.cents > 0 {
            // 折價券印它的名字（「折價券 新會員 100 元」），其他的印「折扣 9 折」
            let label = t.discount.map { $0.isCoupon && !$0.reason.isEmpty ? $0.reason : "折扣 \($0.label)" } ?? "折扣"
            r.add(.row(label, "−" + x.orderDiscount.plain, .body))
        }
        if x.serviceCharge.cents > 0 { r.add(.row("服務費 \(percentText(bps: t.serviceChargeBps))", x.serviceCharge.plain, .body)) }
        r.add(.row("應付", x.amountDue.plain, .big))
        if x.paid.cents > 0 { r.add(.row("已付", x.paid.plain, .body)); r.add(.row("尚欠", x.balance.plain, .strong)) }
        r.add(.feed(1))
        r.add(.text("此單非發票，結帳後另開電子發票", .center))
        r.add(.cut)
        return r
    }

    // MARK: 廚房單

    public enum KitchenMode: Sendable, Hashable {
        /// 第一次送單
        case new
        /// 同一桌加點
        case add
        /// 作廢（已經送出的品項不要做了）
        case void
        /// 催菜（第 2、3 道開始做）
        case fire
        case reprint
    }

    /// 取餐號碼：單號的數字部分（A023 → 23）
    public static func pickupNumber(_ ticketNumber: String) -> String {
        let digits = ticketNumber.filter(\.isNumber)
        return String(Int(digits) ?? 0)
    }

    public static func kitchenTicket(_ t: Ticket, lines: [TicketLine], station: String?, mode: KitchenMode, floor: FloorPlan, at: Date) -> Receipt {
        var r = Receipt(doc: .kitchen)
        let heading: String = switch mode {
        case .new: "出單"
        case .add: "加點"
        case .void: "作廢"
        case .fire: "催菜"
        case .reprint: "補印"
        }
        r.add(.beep)
        r.add(.text("【\(heading)】\(station ?? "")", ReceiptStyle(align: .center, bold: true, scale: 2, invert: mode == .void)))
        r.add(.text(t.title(floor: floor), ReceiptStyle(align: .center, bold: true, scale: 2)))
        r.add(.row("單號 \(t.number)", TaipeiTime.clock(at), .body))
        if t.guests > 0 { r.add(.text("\(t.guests) 位", .body)) }
        r.add(.doubleRule)
        for l in lines {
            r.add(.row(l.name, "×\(l.quantity)", .big))
            if !l.modifiers.isEmpty { r.add(.text("  " + l.modifierText, .strong)) }
            if !l.note.isEmpty { r.add(.text("  ※ " + l.note, .strong)) }
            if l.course > 0 { r.add(.detail("第 \(l.course) 道")) }
            if let s = l.seat { r.add(.detail("座位 \(s)")) }
        }
        if !t.note.isEmpty {
            r.add(.rule)
            r.add(.text("備註：" + t.note, .strong))
        }
        r.add(.feed(1))
        r.add(.cut)
        return r
    }

    // MARK: 交班單（Z 帳）

    public static func shiftReport(_ rep: ShiftReport, store: StoreProfile, deviceName: String, staffName: (String) -> String) -> Receipt {
        let s = rep.summary
        var r = Receipt()
        r.add(.text(store.name, .title))
        r.add(.text(rep.closedAt == nil ? "交班前報表（X 帳）" : "交班報表（Z 帳）", ReceiptStyle(align: .center, bold: true)))
        r.add(.rule)
        r.add(.row("收銀機", deviceName, .body))
        r.add(.row("營業日", rep.businessDate, .body))
        r.add(.row("開班", "\(TaipeiTime.clock(rep.openedAt)) \(staffName(rep.openedBy))", .body))
        if let c = rep.closedAt { r.add(.row("交班", "\(TaipeiTime.clock(c)) \(staffName(rep.closedBy ?? ""))", .body)) }
        r.add(.rule)
        r.add(.row("單數", "\(s.tickets)", .body))
        r.add(.row("來客數", "\(s.guests)", .body))
        r.add(.row("品項小計", s.itemsGross.plain, .body))
        r.add(.row("折扣", "−" + s.discounts.plain, .body))
        r.add(.row("服務費", s.serviceCharge.plain, .body))
        r.add(.row("營業額", s.total.plain, .big))
        r.add(.row("（含稅）", s.tax.plain, .body))
        if s.tips.cents > 0 { r.add(.row("小費", s.tips.plain, .body)) }
        if s.refunds.cents > 0 { r.add(.row("退款", "−" + s.refunds.plain, .body)) }
        r.add(.row("客單價", s.averageTicket.plain, .body))
        if s.prepaidSold.cents > 0 { r.add(.row("其中儲值（預收）", s.prepaidSold.plain, .body)) }
        if s.passesSold.cents > 0 { r.add(.row("其中課程卡、會籍", s.passesSold.plain, .body)) }
        if s.prepaidUsed.cents > 0 { r.add(.row("儲值金扣款", s.prepaidUsed.plain, .body)) }
        if s.redeemedValue.cents > 0 { r.add(.row("課程卡抵用（價值）", s.redeemedValue.plain, .body)) }
        if s.checkIns > 0 { r.add(.row("入場報到", "\(s.checkIns) 人次", .body)) }
        r.add(.rule)
        r.add(.text("付款方式", .strong))
        for t in s.byTender { r.add(.row("\(t.tender.label) \(t.count) 筆", t.amount.plain, .body)) }
        r.add(.rule)
        r.add(.text("錢櫃", .strong))
        r.add(.row("零用金", rep.openingCash.plain, .body))
        r.add(.row("現金收入", rep.cashSales.plain, .body))
        if rep.cashRefunds.cents > 0 { r.add(.row("現金退款", "−" + rep.cashRefunds.plain, .body)) }
        if rep.cashBack.cents > 0 { r.add(.row("換貨退差額", "−" + rep.cashBack.plain, .body)) }
        if rep.payIns.cents > 0 { r.add(.row("存入", rep.payIns.plain, .body)) }
        if rep.payOuts.cents > 0 { r.add(.row("取出", "−" + rep.payOuts.plain, .body)) }
        r.add(.row("應有現金", rep.expectedCash.plain, .strong))
        if let counted = rep.countedCash, let diff = rep.difference {
            r.add(.row("實點現金", counted.plain, .strong))
            r.add(.row(diff.cents == 0 ? "相符" : diff.isNegative ? "短少" : "溢收", diff.isZero ? "0" : (diff.isNegative ? "−" : "+") + Money(cents: abs(diff.cents)).plain, .big))
        }
        if rep.noSaleCount > 0 { r.add(.row("只開錢櫃", "\(rep.noSaleCount) 次", .body)) }
        r.add(.rule)
        r.add(.row("作廢品項", "\(s.voidedItems) 項 \(s.voidedAmount.plain)", .body))
        r.add(.row("作廢單", "\(s.voidedTickets) 張", .body))
        r.add(.row("發票", "開 \(s.invoicesIssued)・作廢 \(s.invoicesVoided)", .body))
        for range in s.invoiceRanges { r.add(.detail(range)) }
        if !s.byStaff.isEmpty && s.byStaff.contains(where: { $0.commission.cents > 0 || $0.redeemed.cents > 0 || $0.assists > 0 }) {
            r.add(.rule)
            r.add(.text("業績", .strong))
            for st in s.byStaff {
                r.add(.row(staffName(st.staffId), st.performance.plain, .body))
                if st.commission.cents > 0 || st.assists > 0 {
                    r.add(.detail("抽成 \(st.commission.plain)" + (st.assists > 0 ? "・助理 \(st.assists) 次" : "")))
                }
            }
        }
        if !s.byCategory.isEmpty {
            r.add(.rule)
            r.add(.text("分類", .strong))
            for c in s.byCategory { r.add(.row("\(c.name) \(c.quantity)", c.amount.plain, .body)) }
        }
        r.add(.feed(2))
        r.add(.text("交班人簽名 ____________", .body))
        r.add(.cut)
        return r
    }

    // MARK: 號碼牌（叫號）

    /// 號碼牌的文字版：店名、很大的號碼、「目前 N 人等候中」、時間、看叫號進度的 QR Code（客人的網址）。
    /// iPad 平常照後台的版面畫成點陣圖印（和樹莓派印的一樣）；這一份是出單機只能印文字時的備案，也是「最近列印」裡看得到的內容。
    /// 號碼放到最大：58 mm 一列 32 格 → 4 倍（8 格）；80 mm 48 格 → 6 倍（8 格），四位數也放得下
    public static func queueTicket(number: Int, waiting: Int, storeName: String, at: Date, link: String?, paper: PaperWidth = .mm58,
                                   waitingText: String? = nil) -> Receipt {
        var r = Receipt()
        r.add(.text(storeName, .title))
        r.add(.text("你的號碼", ReceiptStyle(align: .center, bold: true)))
        r.add(.text(String(number), ReceiptStyle(align: .center, bold: true, scale: paper == .mm58 ? 4 : 6)))
        r.add(.text(waitingText ?? "目前 \(waiting) 人等候中", ReceiptStyle(align: .center, bold: true)))
        r.add(.text(TaipeiTime.dayString(at) + " " + TaipeiTime.clock(at), .center))
        if let link, !link.isEmpty {
            r.add(.feed(1))
            r.add(.text("掃描看現在叫到幾號", .center))
            r.add(.qr(link))
        }
        r.add(.feed(1))
        r.add(.cut)
        return r
    }

    // MARK: 電子發票證明聯（文字模式的備案）

    /// 出單機不能印點陣圖時的備案：條碼與 QR Code 用出單機自己的指令，兩個 QR Code 上下排（正式的證明聯請用 App 畫的點陣圖：左右並排）
    public static func invoiceProofFallback(_ p: InvoiceProof) -> Receipt {
        var r = Receipt()
        r.add(.text(p.storeName, .title))
        r.add(.text(p.heading, ReceiptStyle(align: .center, bold: true, scale: 2)))
        r.add(.text(p.periodLabel, ReceiptStyle(align: .center, bold: true, scale: 2)))
        r.add(.text(p.numberLabel, ReceiptStyle(align: .center, bold: true, scale: 2)))
        r.add(.row(p.dateTime, p.formatCode ?? "", .body))
        r.add(.row(p.randomCode, p.total, .body))
        r.add(.row(p.seller, p.buyer ?? "", .body))
        r.add(.barcode39(p.barcode))
        if let l = p.qrLeft { r.add(.qr(l)) }
        if let rr = p.qrRight { r.add(.qr(rr)) }
        r.add(.cut)
        return r
    }
}
