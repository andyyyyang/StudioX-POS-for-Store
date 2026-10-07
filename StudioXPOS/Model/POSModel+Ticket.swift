import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 點餐：開單、加品項、改數量／價格／折扣、作廢、送廚房、換桌併桌拆單、會員
extension POSModel {
    // MARK: 開單

    /// 開一張新單（內用帶桌號與人數；外帶、外送可以帶稱呼）。
    /// 美業、健身從預約或報到開單時帶會員；服飾可以帶整單的銷售人員；換貨單帶退回的品項
    @discardableResult
    func openTicket(type: OrderType, tableIds: [String] = [], guests: Int = 0, customerName: String? = nil, member: MemberRef? = nil,
                    salespersonId: String? = nil, exchange: ExchangeCredit? = nil, appointmentId: String? = nil) -> Ticket? {
        let id = newID()
        let number = state.nextTicketNumber(deviceCode: device.code, businessDate: businessDate)
        let opened = TicketOpened(ticketId: id, number: number, orderType: type, tableIds: tableIds, guests: guests,
                                  serviceChargeBps: store.serviceChargeBps(for: type), businessDate: businessDate, customerName: customerName,
                                  serviceMode: mode, member: member,
                                  salespersonId: salespersonId ?? (mode.staffPerTicket ? currentStaff?.id : nil),
                                  exchange: exchange, appointmentId: appointmentId)
        guard record(.ticketOpened(opened)) else { return nil }
        selectedTicketId = id
        // 沒有單時掃到的載具：掛到這一張（POSModel+Scan）
        applyPendingCarrier(to: id)
        return state.tickets[id]
    }

    /// 帶位：點空桌 → 右側鍵盤問人數 → 開單、跳到點餐
    func seat(table: DiningTable) async {
        if let existing = state.openTickets(at: table.id).first {
            selectedTicketId = existing.id
            goToOrderIfShown()
            return
        }
        guard let guests = await keypad.askNumber(.guests(current: 0).with(subtitle: "\(table.name)・\(table.seats) 人桌"), validate: { $0 < 1 ? "至少 1 位" : nil }) else { return }
        if let t = openTicket(type: .dineIn, tableIds: [table.id], guests: guests) {
            selectedTicketId = t.id
            goToOrderIfShown()
            if !visibleSections.contains(.order) { show("\(table.name) 入座 \(guests) 位，已同步到前場與結帳櫃台", tone: .info) }
        }
    }

    /// 這台有點餐頁才跳過去（報到接待只帶位，點餐交給前場）
    func goToOrderIfShown() {
        if visibleSections.contains(.order) { section = .order }
    }

    /// 開單時還可以選的其他用餐方式（點品項就會開預設的那一種，所以不用再放「開外帶單」）。
    /// 沒有用餐方式的模式（服飾、美業、課程）、全外帶的店（叫號用在外帶取餐、沒有排隊等內用）：沒有其他的
    var otherOrderTypes: [OrderType] {
        guard mode.showsOrderType else { return [] }
        let usage = queueConfig?.usage ?? []
        let takeoutOnly = mode.defaultOrderType == .takeout && usage.contains(.takeout) && !usage.contains(.dineIn)
        guard !takeoutOnly else { return [] }
        return OrderType.allCases.filter { $0 != mode.defaultOrderType }
    }

    /// 單子頁首可以切換的用餐方式（內用／外帶／外送的分段控制）。
    /// 有用餐方式的模式三種都可以：全外帶的攤子開單時不多放「開內用單」（otherOrderTypes），但偶爾有人坐下來吃、有人叫外送，單子上照樣改得了。
    /// 服飾、美業、課程沒有用餐方式：空的（頁首不顯示）
    var ticketOrderTypes: [OrderType] {
        mode.showsOrderType ? OrderType.allCases : []
    }

    /// 目前這張單；沒有就照營業模式開一張（櫃台、零售：外帶；餐廳、咖啡：內用，不選桌直接點）
    func ensureTicket() -> Ticket? {
        if let t = selectedTicket { return t }
        return openTicket(type: mode.defaultOrderType)
    }

    // MARK: 加品項

    /// 點了菜單上的一格
    func tap(_ item: MenuItem) async {
        touch()
        guard isAvailable(item) else {
            show("\(item.name) 今天賣完了", tone: .warning)
            return
        }
        if item.hasVariants {
            // 服飾：先選顏色、尺寸（VariantPanel）；同一個位置一次只開一張卡
            modifierItem = nil
            variantItem = item
            return
        }
        if !catalog.groups(for: item).isEmpty {
            variantItem = nil
            modifierItem = item
            return
        }
        let qty = keypad.takeQuantity()
        var price: Money? = nil
        if item.openPrice {
            guard let p = await keypad.askMoney(item.itemKind == .storedValue ? .topUp() : .openPrice(name: item.name)) else { return }
            price = p
        }
        guard await ensureMemberIfNeeded(for: item) else { return }
        add(item, quantity: qty, modifiers: [], note: "", price: price)
    }

    /// 儲值、課程卡、會籍一定要記在會員身上：單子上還沒有會員就先查
    func ensureMemberIfNeeded(for item: MenuItem) async -> Bool {
        guard item.itemKind.needsMember else { return true }
        guard let t = ensureTicket() else { return false }
        if t.member?.id != nil { return true }
        show("\(item.itemKind.label)要記在會員身上，先打會員電話", tone: .info)
        await attachMember(to: t)
        if state.tickets[t.id]?.member?.id != nil { return true }
        show("沒有會員，不能賣\(item.itemKind.label)", tone: .warning)
        return false
    }

    /// 加進目前的單（同樣的品項、同樣的加料、還沒送出就加數量，不另起一行）
    func add(_ item: MenuItem, variant: ItemVariant? = nil, quantity: Int, modifiers: [AppliedModifier], note: String, price: Money? = nil,
             staffId: String? = nil) {
        guard let t = ensureTicket(), let me = currentStaff else { return }
        let category = catalog.category(item.categoryId)
        // 會籍續約：同一種還沒到期就接在後面
        var passStart: Date? = nil
        if let spec = item.pass, let acct = account(for: t.member) {
            passStart = acct.renewalStart(name: item.name, spec: spec, at: Date())
        }
        let who = staffId ?? (mode.staffPerLine && item.itemKind == .service ? defaultPerformer(for: t) : nil)
        let line = TicketLine(
            id: newID(), itemId: item.id, name: item.name, categoryId: item.categoryId, categoryName: category?.name,
            unitPrice: price ?? item.price(of: variant), modifiers: modifiers, quantity: max(quantity, 1), note: note,
            station: catalog.station(for: item), taxKind: item.taxKind, addedAt: Date(), addedBy: me.id,
            productId: item.productId, variantId: variant?.productVariantId ?? item.variantId,
            kind: item.kind, skuId: variant?.id, variantName: variant?.label, staffId: who,
            durationMinutes: item.durationMinutes, pass: item.pass, passStartsAt: passStart,
            credit: item.itemKind == .storedValue ? (item.openPrice ? price : item.credit ?? item.price) : nil,
            commissionBps: commissionBps(item: item, staffId: who ?? t.salespersonId ?? me.id)
        )
        let added: Bool
        if let same = t.lines.last(where: { $0.canMerge(with: line) }) {
            added = record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: same.id, quantity: same.quantity + line.quantity)))
        } else {
            added = record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line])))
        }
        if added { addTick &+= 1 }
    }

    /// 美業、課程：新加的服務預設給誰做（預約指定的人 → 這張單上一個服務的人 → 自己是可以排預約的人就給自己）
    func defaultPerformer(for t: Ticket) -> String? {
        if let id = t.appointmentId, let r = reservations.first(where: { $0.id == id }), let s = r.staffId { return s }
        if let last = t.activeLines.last(where: { $0.staffId != nil })?.staffId { return last }
        if let me = currentStaff, bookableStaff.contains(where: { $0.id == me.id }) { return me.id }
        return nil
    }

    /// 品號／條碼（掃到吊牌直接是那個顏色尺寸）
    func lookup(code: String) {
        guard let m = catalog.match(code: code) else {
            show("找不到品號 \(code)", tone: .warning)
            return
        }
        guard let v = m.variant else {
            Task { await tap(m.item) }
            return
        }
        guard isAvailable(m.item), v.isAvailable else {
            show("\(m.item.name) \(v.label) 今天不能賣", tone: .warning)
            return
        }
        if let stock = v.stock, stock <= 0 { show("\(m.item.name) \(v.label) 帳上沒有庫存，照樣加入", tone: .warning) }
        add(m.item, variant: v, quantity: keypad.takeQuantity(), modifiers: [], note: "")
    }

    /// 待機打了數字按「確定」（右側鍵盤的大鍵、外接鍵盤的 Enter）：對到品號 → 加品項；會員電話 → 掛會員；
    /// 沒有這個品號 → 就是多少錢，加一筆「其他」（見 TypedConfirm）
    func commitTyped(_ digits: String) {
        if cashModeActive {
            cashFromTyped(digits)
            return
        }
        switch TypedConfirm.classify(digits, catalog: catalog) {
        case .product?:
            lookup(code: digits)
        case .member(let phone)?:
            Task { _ = await handleScan(phone, context: .member) }
        case .amount(let price)?:
            addAmount(price)
        case .notFound(let code)?:
            show("找不到品號 \(code)", tone: .warning)
        case nil:
            break
        }
    }

    /// 手機：叫出鍵盤打品號或金額（iPad 的右側鍵盤一直都在；手機要用的時候才叫，點餐頁下面那條旁邊的鍵）。
    /// 按下大鍵和 iPad 一樣（commitTyped）；找不到品號、又不像金額的留在鍵盤上說
    func askTyped() async {
        touch()
        let spec = KeypadSpec(kind: .code(minLength: 1, maxLength: 13), title: "品號・金額",
                              subtitle: "打品號加品項；沒有這個品號就是多少錢，加一筆「\(Self.amountLineName)」", confirmLabel: "加入")
        guard let e = await keypad.ask(spec, validate: { [weak self] e in
            guard let self, case .notFound? = TypedConfirm.classify(e.digits, catalog: self.catalog) else { return nil }
            return "找不到品號 \(e.digits)"
        }, confirmTitle: { [weak self] e in
            e.digits.isEmpty ? "加入" : (self?.typedConfirmTitle(e.digits) ?? "加入")
        }) else { return }
        commitTyped(e.digits)
    }

    /// 現金模式：打的數字一律是金額 → 加一筆「其他」、整張單收現金結帳（單上已經點的品項一起）
    private func cashFromTyped(_ digits: String) {
        switch TypedConfirm.classify(digits, catalog: catalog, matchesProducts: false) {
        case .amount(let price)?:
            guard let t = addAmount(price) else { return }
            Task { await cashCheckout(t) }
        case .member(let phone)?:
            Task { _ = await handleScan(phone, context: .member) }
        case .notFound(let code)?:
            show("\(code) 不是金額：最多 \(TypedConfirm.maxAmountDigits) 位數、不能 0 開頭", tone: .warning)
        case .product?, nil:
            break
        }
    }

    /// 大鍵上的字：按下去會怎樣（「加入 鴨胸」「加 NT$120」；現金模式「收現金 NT$120」）
    func typedConfirmTitle(_ digits: String) -> String {
        if cashModeActive {
            guard case .amount(let price)? = TypedConfirm.classify(digits, catalog: catalog, matchesProducts: false) else {
                return digits.hasPrefix("09") ? "查會員" : "收現金"
            }
            return "收現金 \(((selectedTicket?.totals.balance ?? .zero) + price).formatted)"
        }
        switch TypedConfirm.classify(digits, catalog: catalog) {
        case .product(let m)?:
            let name = m.variant.map { "\(m.item.name) \($0.label)" } ?? m.item.name
            return "加入 \(name)"
        case .member?:
            return "查會員"
        case .amount(let price)?:
            return "加 \(price.formatted)"
        case .notFound?, nil:
            return "品號"
        }
    }

    /// 鍵盤直接打的金額：一筆「其他」（菜單上沒有、臨時的價錢；應稅）。回加到的那張單
    @discardableResult
    func addAmount(_ price: Money) -> Ticket? {
        guard let t = ensureTicket(), let me = currentStaff else { return nil }
        let line = TicketLine(id: newID(), itemId: nil, name: Self.amountLineName, unitPrice: price, addedAt: Date(), addedBy: me.id)
        guard record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line]))) else { return nil }
        addTick &+= 1
        return state.tickets[t.id]
    }

    /// 鍵盤直接打金額加的那一筆叫什麼（單子、收據、發票上都是這個名字）
    static let amountLineName = "其他"

    /// 自訂品項（菜單上沒有的：「開瓶費」「外送費」）
    func addCustom(name: String) async {
        guard let price = await keypad.askMoney(KeypadSpec(kind: .money, title: "金額", subtitle: name, confirmLabel: "加入", minValue: 1)),
              let t = ensureTicket(), let me = currentStaff else { return }
        let line = TicketLine(id: newID(), itemId: nil, name: name, unitPrice: price, addedAt: Date(), addedBy: me.id)
        if record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line]))) { addTick &+= 1 }
    }

    // MARK: 改一行

    /// 這一行改成 q 個（右側鍵盤問的；q ≥ 1，0 是刪除／作廢，由單子欄決定怎麼問）。
    /// 已經送廚房的：減少要主管（等於作廢一部分）。用課程卡抵的：卡的次數不夠就不改
    func setQuantity(_ line: TicketLine, to q: Int, in t: Ticket) async {
        guard q >= 1, q != line.quantity else { return }
        if let problem = redeemProblem(line, quantity: q, in: t) {
            show(problem, tone: .warning)
            return
        }
        if line.isSent && q < line.quantity {
            guard await authorize(.voidSentItem, detail: "\(line.name) 已出單") != nil else { return }
        }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, quantity: q)))
    }

    /// −1／+1（單子上往右滑、菜單卡的「少一份」）：減到 0＝刪除（還沒送出的直接拿掉；送出去的要作廢、要主管）
    func stepQuantity(_ line: TicketLine, in t: Ticket, by delta: Int) {
        let q = line.quantity + delta
        if q < 1 {
            if line.isSent {
                Task { await void([line], in: t) }
            } else {
                removeLines([line], in: t)
            }
            return
        }
        // 用課程卡抵的：卡的次數不夠就不能再加
        if delta > 0, let problem = redeemProblem(line, quantity: q, in: t) {
            show(problem, tone: .warning)
            return
        }
        if delta < 0 && line.isSent {
            Task {
                guard await authorize(.voidSentItem, detail: "\(line.name) 已出單") != nil else { return }
                record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, quantity: q)))
            }
            return
        }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, quantity: q)))
    }

    func changePrice(_ line: TicketLine, in t: Ticket) async {
        guard let auth = await authorize(.priceOverride, detail: line.name),
              let price = await keypad.askMoney(.price(name: line.name, current: line.unitPrice)) else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, unitPrice: price, authorizedBy: auth.authorizerId)))
    }

    func discount(_ line: TicketLine, in t: Ticket, kind: Discount.Kind) async {
        guard let d = await askDiscount(kind: kind, base: line.gross) else { return }
        guard let auth = await authorizeDiscount(d, base: line.gross, what: line.name) else { return }
        var final = d
        final.authorizedBy = auth.authorizerId
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, discount: final, authorizedBy: auth.authorizerId)))
    }

    func clearDiscount(_ line: TicketLine, in t: Ticket) {
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, clearDiscount: true)))
    }

    /// 一行或好幾行（單子上「選取」勾起來的）用同一個備註：同一次記（一起成功、一起不成功）
    func setNote(_ note: String, for lines: [TicketLine], in t: Ticket) {
        let bodies = lines.filter(\.isActive).map { EventBody.lineUpdated(LineUpdated(ticketId: t.id, lineId: $0.id, note: note)) }
        guard !bodies.isEmpty else { return }
        record(bodies)
    }

    /// 好幾行打一樣的折扣（單子上「選取」的「整筆折扣」）：鍵盤問一次、授權一次（照折得最多的那一行算，和一行的折扣同一個上限），
    /// 每一行各記一筆、同一次記。折價（元）是每一行折一樣多，最多是最便宜那一行的金額
    func discount(_ lines: [TicketLine], in t: Ticket, kind: Discount.Kind) async {
        let targets = lines.filter { $0.isActive && $0.gross.cents > 0 }
        guard let base = targets.map(\.gross).min() else { return }
        guard var d = await askDiscount(kind: kind, base: base) else { return }
        guard let auth = await authorizeDiscount(d, base: base, what: "\(targets.count) 項") else { return }
        d.authorizedBy = auth.authorizerId
        let bodies = targets.map { EventBody.lineUpdated(LineUpdated(ticketId: t.id, lineId: $0.id, discount: d, authorizedBy: auth.authorizerId)) }
        guard record(bodies) else { return }
        show("\(targets.count) 項都是 \(d.label)", tone: .neutral)
    }

    /// 好幾行一起取消折扣（回到原價）
    func clearDiscount(_ lines: [TicketLine], in t: Ticket) {
        let bodies = lines.filter { $0.isActive && $0.discount != nil }
            .map { EventBody.lineUpdated(LineUpdated(ticketId: t.id, lineId: $0.id, clearDiscount: true)) }
        guard !bodies.isEmpty else { return }
        record(bodies)
    }

    func setCourse(_ course: Int, for line: TicketLine, in t: Ticket) {
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, course: course)))
    }

    func setSeat(_ line: TicketLine, in t: Ticket) async {
        guard let seat = await keypad.askNumber(KeypadSpec(kind: .count, title: "座位", subtitle: "\(line.name)・第幾位客人（0＝不分）", initial: line.seat.map(String.init) ?? "", confirmLabel: "設定", maxValue: 99)) else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, seat: seat)))
    }

    /// 刪除／作廢：還沒送出的直接拿掉（不留紀錄）；送出去的要原因、要主管，廚房印作廢單
    func void(_ lines: [TicketLine], in t: Ticket, reason: String? = nil) async {
        let unsent = lines.filter { $0.isActive && !$0.isSent }
        let sent = lines.filter { $0.isActive && $0.isSent }
        if !unsent.isEmpty { removeLines(unsent, in: t) }
        guard !sent.isEmpty else { return }
        guard let auth = await authorize(.voidSentItem, detail: sent.map(\.name).joined(separator: "、")) else { return }
        record(.linesVoided(LinesVoided(ticketId: t.id, lineIds: sent.map(\.id), reason: reason ?? "客人取消", authorizedBy: auth.authorizerId)))
        if settings.printKitchenTickets {
            printKitchen(t, lines: sent, mode: .void)
        }
    }

    /// 刪掉還沒送出的品項：直接從單子拿掉，不留紀錄（lines.removed；廚房還不知道有這一項，報表也不算作廢）。
    /// 下面跳一句「已刪除 拿鐵・復原」：按「復原」原樣加回去
    func removeLines(_ lines: [TicketLine], in t: Ticket) {
        let unsent = lines.filter { $0.isActive && !$0.isSent }
        guard !unsent.isEmpty else { return }
        guard record(.linesRemoved(LinesRemoved(ticketId: t.id, lineIds: unsent.map(\.id)))) else { return }
        let name = unsent.count == 1 ? unsent[0].displayName : "\(unsent.count) 項"
        let ticketId = t.id
        toast = Toast(text: "已刪除 \(name)", tone: .neutral, action: ToastAction(title: "復原") { [weak self] in
            self?.restoreLines(unsent, to: ticketId)
        })
    }

    /// 復原剛剛刪掉的：照原樣（數量、加料、備註、折扣）加回同一張單的最後面（用新的 id，和刪掉的那一筆分開）
    func restoreLines(_ lines: [TicketLine], to ticketId: String) {
        guard let t = state.tickets[ticketId], t.isOpen else {
            show("這張單已經結帳或作廢，復原不了", tone: .warning)
            return
        }
        let copies = lines.map { l -> TicketLine in
            var c = l
            c.id = newID()
            return c
        }
        guard record(.linesAdded(LinesAdded(ticketId: ticketId, lines: copies))) else { return }
        selectedTicketId = ticketId
    }

    // MARK: 整張單

    func discountTicket(_ t: Ticket, kind: Discount.Kind, reason: String = "") async {
        let base = t.totals.subtotal
        guard var d = await askDiscount(kind: kind, base: base) else { return }
        d.reason = reason
        guard let auth = await authorizeDiscount(d, base: base, what: "整張單") else { return }
        d.authorizedBy = auth.authorizerId
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, discount: d)))
    }

    func clearTicketDiscount(_ t: Ticket) {
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, clearDiscount: true)))
    }

    func setGuests(_ t: Ticket) async {
        guard let g = await keypad.askNumber(.guests(current: t.guests)) else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, guests: g)))
    }

    /// 換用餐方式（服務費跟著換）。改成外帶、外送而且單子在桌上：桌子空出來（ticket.moved 到沒有桌子，和換用餐方式同一次記）。
    /// 要不要先問由畫面決定（單子欄頁首：「A2 的桌子會空出來」）
    func setOrderType(_ type: OrderType, for t: Ticket) {
        guard type != t.orderType else { return }
        let freed = type == .dineIn ? [] : t.tableIds
        var bodies: [EventBody] = [.ticketUpdated(TicketUpdated(ticketId: t.id, orderType: type, serviceChargeBps: store.serviceChargeBps(for: type)))]
        if !freed.isEmpty { bodies.append(.ticketMoved(TicketMoved(ticketId: t.id, tableIds: []))) }
        // 外帶改內用：已經取的取餐號碼放回去（內用照桌號）
        let dropsNumber = type == .dineIn && t.orderType != .dineIn && t.queueNumber != nil && queueForTakeout
        if dropsNumber { bodies.append(.ticketUpdated(TicketUpdated(ticketId: t.id, queueNumber: 0))) }
        guard record(bodies) else { return }
        if dropsNumber { releaseNumber(of: t) }
        guard !freed.isEmpty else { return }
        show("\(orderNumber(t) ?? "這張單") 改成\(type.label)・\(floor.tableNames(freed)) 空出來了", tone: .neutral)
    }

    func setTicketNote(_ note: String, for t: Ticket) {
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, note: note)))
    }

    func setCustomerName(_ name: String, for t: Ticket) {
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, customerName: name)))
    }

    /// 免收服務費（店長）
    func waiveServiceCharge(_ t: Ticket) async {
        guard await authorize(.discount, detail: "免收服務費") != nil else { return }
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, serviceChargeBps: 0)))
    }

    func voidTicket(_ t: Ticket, reason: String) async {
        let needsAuth = t.lines.contains { $0.isSent } || !t.approvedPayments.isEmpty
        var auth: Authorization = .allowed
        if needsAuth {
            guard let a = await authorize(.voidTicket, detail: "作廢 \(t.number)") else { return }
            auth = a
        }
        guard t.approvedPayments.isEmpty else {
            show("這張單已經收了錢，請先退回付款再作廢", tone: .danger)
            return
        }
        guard record(.ticketVoided(TicketVoided(ticketId: t.id, reason: reason, authorizedBy: auth.authorizerId))) else { return }
        // 外帶單已經取了號碼（一進結帳就取）：放回去，叫號螢幕不再列它
        releaseNumber(of: t)
        if t.lines.contains(where: \.isSent), settings.printKitchenTickets {
            printKitchen(t, lines: t.activeLines.filter(\.isSent), mode: .void)
        }
        selectedTicketId = nil
        show("已作廢 \(orderNumber(t) ?? orderTitle(t) + "單")", tone: .neutral)
    }

    // MARK: 廚房

    /// 送單：還沒送出的（第 0 道＝馬上做）送到廚房；第 2、3 道等「催菜」
    func send(_ t: Ticket) {
        send(t.unsentLines.filter { $0.course <= 1 }, in: t)
    }

    /// 只送這幾行（整張單的「送單」、單子上「選取」勾起來的「送廚房」；勾了第 2、3 道也一起送，等於先催）。已經送出的不再送
    func send(_ lines: [TicketLine], in t: Ticket) {
        let ids = Set(lines.map(\.id))
        let toSend = t.unsentLines.filter { ids.contains($0.id) }
        guard !toSend.isEmpty else {
            show("沒有新的品項要送", tone: .neutral)
            return
        }
        let first = !t.lines.contains(where: \.isSent)
        let printHere = settings.printKitchenTickets && mode.usesKitchen
        // 這台沒有廚房出單機（前場的手機）：事件上註記，櫃台的 iPad 幫忙印（POSModel+KitchenRelay）
        let relay = printHere && !printers.hasKitchenPrinter
        guard record(.linesSent(LinesSent(ticketId: t.id, lineIds: toSend.map(\.id), relayPrint: relay ? (first ? "new" : "add") : nil))) else { return }
        if printHere && !relay { printKitchen(t, lines: toSend, mode: first ? .new : .add) }
        show("已送出 \(toSend.reduce(0) { $0 + $1.quantity }) 項")
    }

    /// 催菜：第 n 道開始做
    func fire(course: Int, of t: Ticket) {
        let lines = t.unsentLines.filter { $0.course == course }
        guard !lines.isEmpty else { return }
        let relay = settings.printKitchenTickets && !printers.hasKitchenPrinter
        record(.linesSent(LinesSent(ticketId: t.id, lineIds: lines.map(\.id), relayPrint: relay ? "fire" : nil)))
        if settings.printKitchenTickets && !relay { printKitchen(t, lines: lines, mode: .fire) }
        show("第 \(course) 道開始做")
    }

    func kitchen(_ status: KitchenStatus, lines: [TicketLine], in t: Ticket) {
        record(.kitchenUpdated(KitchenUpdated(ticketId: t.id, lineIds: lines.map(\.id), status: status)))
    }

    func printKitchen(_ t: Ticket, lines: [TicketLine], mode: Templates.KitchenMode) {
        let byStation = Dictionary(grouping: lines) { $0.station ?? "" }
        for (station, ls) in byStation {
            let r = Templates.kitchenTicket(t, lines: ls, station: station.isEmpty ? nil : station, mode: mode, floor: floor, at: Date())
            printers.print(r, role: .kitchen, station: station.isEmpty ? nil : station)
        }
    }

    // MARK: 桌子

    func printBill(_ t: Ticket) {
        record(.billPrinted(TicketRef(ticketId: t.id)))
        printers.print(Templates.bill(t, store: store, floor: floor), role: .receipt)
    }

    func move(_ t: Ticket, to tableIds: [String]) {
        record(.ticketMoved(TicketMoved(ticketId: t.id, tableIds: tableIds)))
        show("\(t.number) 換到 \(floor.tableNames(tableIds))")
    }

    func merge(_ source: Ticket, into target: Ticket) {
        record(.ticketsMerged(TicketsMerged(targetId: target.id, sourceId: source.id)))
        selectedTicketId = target.id
        show("\(source.title(floor: floor)) 併到 \(target.title(floor: floor))")
    }

    /// 拆單：選好的品項（與數量）搬到一張新單
    func split(_ t: Ticket, moving: [String: Int]) {
        let moves = moving.filter { $0.value > 0 }.map { SplitMove(lineId: $0.key, quantity: $0.value, newLineId: newID()) }
        guard !moves.isEmpty else { return }
        let opened = TicketOpened(ticketId: newID(), number: state.nextTicketNumber(deviceCode: device.code, businessDate: businessDate),
                                  orderType: t.orderType, tableIds: t.tableIds, guests: 0, serviceChargeBps: t.serviceChargeBps,
                                  businessDate: businessDate, customerName: t.customerName)
        record(.ticketSplit(TicketSplit(sourceId: t.id, opened: opened, moves: moves)))
        selectedTicketId = opened.ticketId
        show("拆出 \(opened.number)")
    }

    func clean(table: DiningTable) {
        record(.tableCleaned(TableRef(tableId: table.id)))
    }

    // MARK: 菜單

    func toggleAvailability(_ item: MenuItem) {
        let now = !isAvailable(item)
        record(.itemAvailability(ItemAvailability(itemId: item.id, available: now)))
        show(now ? "\(item.name) 恢復供應" : "\(item.name) 已標示賣完", tone: now ? .active : .warning)
    }

    // MARK: 會員

    /// 右側鍵盤打電話查會員；查不到可以當場加入
    func attachMember(to t: Ticket) async {
        guard let api else { return }
        var problem: String? = nil
        while true {
            guard let entry = await keypad.ask(.phone, error: problem) else { return }
            do {
                if let m = try await api.member(phone: entry.digits) {
                    remember(m)
                    attach(m.ref, memberId: m.id, to: t)
                    show("會員 \(m.name ?? m.ref.maskedPhone)\(m.tierName.map { "・\($0)" } ?? "")")
                    return
                }
                let created = try await api.createMember(MemberCreate(phone: entry.digits, name: nil))
                remember(created)
                attach(created.ref, memberId: created.id, to: t)
                show("新會員 \(created.ref.maskedPhone) 加入了")
                return
            } catch let e as APIError {
                if case .offline = e {
                    // 離線：先記電話，後台結帳時再對到會員
                    attach(MemberRef(phone: entry.digits), memberId: nil, to: t)
                    show("離線，先記下電話 \(MemberRef(phone: entry.digits).maskedPhone)", tone: .warning)
                    return
                }
                problem = e.userMessage
            } catch {
                problem = "查不到，請再試一次"
            }
        }
    }

    /// 把會員掛到這張單（打電話查到的、掃會員卡的）：換了會員的話，前一位的課程卡抵的行一起取消
    @discardableResult
    func attach(_ ref: MemberRef, memberId: String?, to t: Ticket) -> Bool {
        record([EventBody.ticketUpdated(TicketUpdated(ticketId: t.id, member: ref))] + redemptionsToClear(in: t, newMemberId: memberId))
    }

    /// 拿掉會員：用他的課程卡抵的行一起取消（沒有會員就扣不了卡）
    func detachMember(from t: Ticket) {
        record([EventBody.ticketUpdated(TicketUpdated(ticketId: t.id, clearMember: true))] + redemptionsToClear(in: t, newMemberId: nil, always: true))
    }

    /// 換了會員：前一位的課程卡抵的行要取消（同一位會員就不動）
    private func redemptionsToClear(in t: Ticket, newMemberId: String?, always: Bool = false) -> [EventBody] {
        let current = state.tickets[t.id] ?? t
        if !always && current.member?.id == newMemberId { return [] }
        return current.activeLines.filter { $0.redeem != nil }.map { l in
            EventBody.lineUpdated(LineUpdated(ticketId: t.id, lineId: l.id, clearRedeem: true))
        }
    }

    // MARK: 業績算給誰（服飾的銷售人員、美業的設計師與助理、課程的教練）

    /// 服飾：整張單的業績算給誰（nil＝拿掉，回到開單的人）。行上沒有另外指定人的，抽成跟著換
    func setSalesperson(_ staffId: String?, for t: Ticket) {
        let id = staffId.flatMap { $0.isEmpty ? nil : $0 }
        guard id != t.salespersonId else { return }
        var bodies: [EventBody] = [.ticketUpdated(TicketUpdated(ticketId: t.id, salespersonId: id ?? ""))]
        let who = id ?? t.openedBy
        for l in t.activeLines where l.staffId == nil {
            let item = l.itemId.flatMap { catalog.item($0) }
            if let bps = commissionBps(item: item, staffId: who), bps != l.commissionBps {
                bodies.append(.lineUpdated(LineUpdated(ticketId: t.id, lineId: l.id, commissionBps: bps)))
            }
        }
        guard record(bodies) else { return }
        show(id.map { "銷售：\(staffName($0))" } ?? "不指定銷售人員：業績算給開單的 \(staffName(t.openedBy))", tone: .neutral)
    }

    /// 美業、課程：這一行（服務）給誰做；抽成照新的人重算（品項有設就用品項的）
    func setPerformer(_ line: TicketLine, staffId: String?, in t: Ticket) {
        let id = staffId.flatMap { $0.isEmpty ? nil : $0 }
        guard id != line.staffId else { return }
        let item = line.itemId.flatMap { catalog.item($0) }
        let bps = commissionBps(item: item, staffId: id ?? t.salespersonId ?? t.openedBy)
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, staffId: id ?? "", commissionBps: bps)))
    }

    /// 助理（洗髮、吹整）；nil＝不用助理
    func setAssistant(_ line: TicketLine, staffId: String?, in t: Ticket) {
        let id = staffId.flatMap { $0.isEmpty ? nil : $0 }
        guard id != line.assistantId else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, assistantId: id ?? "")))
    }

    // MARK: 用課程卡抵

    /// 這張卡在還沒結帳的單上已經抵了幾次（excluding：不算這一行）
    func openPassUses(_ passId: String, excluding lineId: String? = nil) -> Int {
        state.openTickets.reduce(0) { sum, t in
            sum + t.activeLines.filter { $0.redeem?.passId == passId && $0.id != lineId }.reduce(0) { $0 + $1.quantity }
        }
    }

    /// 次數卡還能抵幾次（帳戶上的剩餘次數，扣掉還沒結帳的單上已經抵的）；期間會籍不限次數是 nil
    func visitsLeft(on pass: MemberPass, excluding lineId: String? = nil) -> Int? {
        guard pass.spec.kind == .visits else { return nil }
        return (pass.remaining ?? 0) - openPassUses(pass.id, excluding: lineId)
    }

    /// 這一行可以用客人的哪些卡抵（有會員、查得到帳戶、卡能抵這個品項；次數不夠的也列出來，選了再說不夠）
    func redeemablePasses(for line: TicketLine, in t: Ticket) -> [MemberPass] {
        guard line.isActive, line.redeem == nil, line.itemId != nil, !line.itemKind.needsMember,
              t.member?.id != nil, let acct = account(for: t.member) else { return [] }
        return acct.passes(covering: line.itemId, categoryId: line.categoryId, at: Date())
    }

    /// 用卡抵的那一行要變成 quantity 個：卡的次數夠不夠（不夠回一句話；查不到帳戶就不擋）
    func redeemProblem(_ line: TicketLine, quantity: Int, in t: Ticket) -> String? {
        guard let r = line.redeem, let pass = account(for: t.member)?.passes.first(where: { $0.id == r.passId }),
              let left = visitsLeft(on: pass, excluding: line.id) else { return nil }
        guard quantity > left else { return nil }
        return left > 0 ? "\(pass.name) 只剩 \(left) 次可以抵" : "\(pass.name) 已經沒有次數了"
    }

    /// 這一行用客人的課程卡抵（不收錢、不開發票；業績照每次的價值算）。同一張卡在還沒結帳的單上抵掉的也算，不會超用
    func redeem(_ line: TicketLine, with pass: MemberPass, in t: Ticket) {
        guard t.member?.id != nil else {
            show("先找會員才能用課程卡", tone: .warning)
            return
        }
        guard line.isActive, line.redeem == nil else { return }
        guard pass.isUsable(at: Date()), pass.spec.covers(itemId: line.itemId, categoryId: line.categoryId) else {
            show("\(pass.name) 不能抵 \(line.name)", tone: .warning)
            return
        }
        let left = visitsLeft(on: pass, excluding: line.id)
        if let left, left < line.quantity {
            show(left > 0 ? "\(pass.name) 只剩 \(left) 次，不夠抵 \(line.quantity) 個" : "\(pass.name) 的次數都排在還沒結帳的單上了", tone: .warning)
            return
        }
        let r = PassRedemption(passId: pass.id, name: pass.name, value: pass.unitValue)
        guard record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, redeem: r))) else { return }
        if let left {
            show("\(line.name) 用\(pass.name)抵・剩 \(left - line.quantity) 次")
        } else {
            show("\(line.name) 用\(pass.name)抵")
        }
    }

    /// 取消用卡抵（回到照價收錢）
    func unredeem(_ line: TicketLine, in t: Ticket) {
        guard line.redeem != nil else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, clearRedeem: true)))
    }

    // MARK: 換規格（結帳前）

    /// 還沒結帳的那一行換顏色、尺寸：照菜單價格的換成新規格的價格；改過價（主管授權過）的維持原價
    func changeVariant(_ line: TicketLine, to v: ItemVariant, in t: Ticket) {
        guard line.isActive, !line.isSent, v.id != line.skuId, let item = line.itemId.flatMap({ catalog.item($0) }) else { return }
        guard v.isAvailable else {
            show("\(item.name) \(v.label) 今天不能賣", tone: .warning)
            return
        }
        let listed = item.price(of: item.variant(line.skuId))
        let fresh = item.price(of: v)
        let price: Money? = line.unitPrice == listed && fresh != line.unitPrice ? fresh : nil
        guard record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, unitPrice: price, skuId: v.id, variantName: v.label,
                                              variantId: v.productVariantId ?? item.variantId))) else { return }
        if let stock = v.stock, stock <= 0 {
            show("\(item.name) 換成 \(v.label)・帳上沒有庫存，照樣換了", tone: .warning)
        } else {
            show("\(item.name) 換成 \(v.label)" + (price.map { "・\($0.formatted)" } ?? ""), tone: .neutral)
        }
    }

    // MARK: 折扣的共用

    private func askDiscount(kind: Discount.Kind, base: Money) async -> Discount? {
        switch kind {
        case .percent:
            guard let pct = await keypad.askNumber(.discountPercent(presets: store.discountPresetsBps), validate: { $0 < 1 ? "至少 1%" : ($0 > 100 ? "不能超過 100%" : nil) }) else { return nil }
            return .percent(pct * 100)
        case .amount:
            guard let m = await keypad.askMoney(.discountAmount(max: base)), m.cents > 0 else { return nil }
            return .amount(m)
        }
    }

    private func authorizeDiscount(_ d: Discount, base: Money, what: String) async -> Authorization? {
        let large = d.bps(on: base) > store.discountLimitBps
        return await authorize(large ? .largeDiscount : .discount, detail: "\(what) \(d.label)")
    }
}

extension KeypadSpec {
    /// 換掉小字（同一個題目、不同的情境）
    func with(subtitle: String) -> KeypadSpec {
        var s = self
        s.subtitle = subtitle
        return s
    }
}
