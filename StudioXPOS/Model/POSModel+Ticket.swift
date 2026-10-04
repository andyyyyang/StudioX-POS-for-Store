import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 點餐：開單、加品項、改數量／價格／折扣、作廢、送廚房、換桌併桌拆單、會員
extension POSModel {
    // MARK: 開單

    /// 開一張新單（內用帶桌號與人數；外帶、外送可以帶稱呼）
    @discardableResult
    func openTicket(type: OrderType, tableIds: [String] = [], guests: Int = 0, customerName: String? = nil) -> Ticket? {
        let id = newID()
        let number = state.nextTicketNumber(deviceCode: device.code, businessDate: businessDate)
        let opened = TicketOpened(ticketId: id, number: number, orderType: type, tableIds: tableIds, guests: guests,
                                  serviceChargeBps: store.serviceChargeBps(for: type), businessDate: businessDate, customerName: customerName)
        guard record(.ticketOpened(opened)) else { return nil }
        selectedTicketId = id
        return state.tickets[id]
    }

    /// 帶位：點空桌 → 右側鍵盤問人數 → 開單、跳到點餐
    func seat(table: DiningTable) async {
        if let existing = state.openTickets(at: table.id).first {
            selectedTicketId = existing.id
            section = .order
            return
        }
        guard let guests = await keypad.askNumber(.guests(current: 0).with(subtitle: "\(table.name)・\(table.seats) 人桌"), validate: { $0 < 1 ? "至少 1 位" : nil }) else { return }
        if let t = openTicket(type: .dineIn, tableIds: [table.id], guests: guests) {
            selectedTicketId = t.id
            section = .order
        }
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
        if !catalog.groups(for: item).isEmpty {
            modifierItem = item
            return
        }
        let qty = keypad.takeQuantity()
        var price: Money? = nil
        if item.openPrice {
            guard let p = await keypad.askMoney(.openPrice(name: item.name)) else { return }
            price = p
        }
        add(item, quantity: qty, modifiers: [], note: "", price: price)
    }

    /// 加進目前的單（同樣的品項、同樣的加料、還沒送出就加數量，不另起一行）
    func add(_ item: MenuItem, quantity: Int, modifiers: [AppliedModifier], note: String, price: Money? = nil) {
        guard let t = ensureTicket(), let me = currentStaff else { return }
        let category = catalog.category(item.categoryId)
        let line = TicketLine(
            id: newID(), itemId: item.id, name: item.name, categoryId: item.categoryId, categoryName: category?.name,
            unitPrice: price ?? item.price, modifiers: modifiers, quantity: max(quantity, 1), note: note,
            station: catalog.station(for: item), taxKind: item.taxKind, addedAt: Date(), addedBy: me.id,
            productId: item.productId, variantId: item.variantId
        )
        if let same = t.lines.last(where: { $0.canMerge(with: line) }) {
            record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: same.id, quantity: same.quantity + line.quantity)))
        } else {
            record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line])))
        }
    }

    /// 品號／條碼
    func lookup(code: String) {
        guard let item = catalog.lookup(code: code) else {
            show("找不到品號 \(code)", tone: .warning)
            return
        }
        Task { await tap(item) }
    }

    /// 自訂品項（菜單上沒有的：「開瓶費」「外送費」）
    func addCustom(name: String) async {
        guard let price = await keypad.askMoney(KeypadSpec(kind: .money, title: "金額", subtitle: name, confirmLabel: "加入", minValue: 1)),
              let t = ensureTicket(), let me = currentStaff else { return }
        let line = TicketLine(id: newID(), itemId: nil, name: name, unitPrice: price, addedAt: Date(), addedBy: me.id)
        record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line])))
    }

    // MARK: 改一行

    func changeQuantity(_ line: TicketLine, in t: Ticket) async {
        if line.isSent {
            // 已經送廚房的：減少要主管（等於作廢一部分）
            guard let q = await keypad.askNumber(.quantity(name: line.name, current: line.quantity), validate: { $0 < 1 ? "數量至少 1；不要了請按「作廢」" : nil }) else { return }
            if q < line.quantity {
                guard let auth = await authorize(.voidSentItem, detail: "\(line.name) 已出單") else { return }
                _ = auth
            }
            record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, quantity: q)))
            return
        }
        guard let q = await keypad.askNumber(.quantity(name: line.name, current: line.quantity), validate: { $0 < 1 ? "數量至少 1；不要了請按「刪除」" : nil }) else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, quantity: q)))
    }

    func stepQuantity(_ line: TicketLine, in t: Ticket, by delta: Int) {
        let q = line.quantity + delta
        if q < 1 {
            Task { await void([line], in: t) }
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

    func setNote(_ note: String, for line: TicketLine, in t: Ticket) {
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, note: note)))
    }

    func setCourse(_ course: Int, for line: TicketLine, in t: Ticket) {
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, course: course)))
    }

    func setSeat(_ line: TicketLine, in t: Ticket) async {
        guard let seat = await keypad.askNumber(KeypadSpec(kind: .count, title: "座位", subtitle: "\(line.name)・第幾位客人（0＝不分）", initial: line.seat.map(String.init) ?? "", confirmLabel: "設定", maxValue: 99)) else { return }
        record(.lineUpdated(LineUpdated(ticketId: t.id, lineId: line.id, seat: seat)))
    }

    /// 刪除／作廢：還沒送出的直接刪；送出去的要原因、要主管
    func void(_ lines: [TicketLine], in t: Ticket, reason: String? = nil) async {
        let sent = lines.filter(\.isSent)
        var auth: Authorization = .allowed
        if !sent.isEmpty {
            guard let a = await authorize(.voidSentItem, detail: sent.map(\.name).joined(separator: "、")) else { return }
            auth = a
        }
        let why = reason ?? (sent.isEmpty ? "點錯" : "客人取消")
        record(.linesVoided(LinesVoided(ticketId: t.id, lineIds: lines.map(\.id), reason: why, authorizedBy: auth.authorizerId)))
        if !sent.isEmpty, settings.printKitchenTickets {
            printKitchen(t, lines: sent, mode: .void)
        }
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

    func setOrderType(_ type: OrderType, for t: Ticket) {
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, orderType: type, serviceChargeBps: store.serviceChargeBps(for: type))))
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
        record(.ticketVoided(TicketVoided(ticketId: t.id, reason: reason, authorizedBy: auth.authorizerId)))
        if t.lines.contains(where: \.isSent), settings.printKitchenTickets {
            printKitchen(t, lines: t.activeLines.filter(\.isSent), mode: .void)
        }
        selectedTicketId = nil
        show("已作廢 \(t.number)", tone: .neutral)
    }

    // MARK: 廚房

    /// 送單：還沒送出的（第 0 道＝馬上做）送到廚房；第 2、3 道等「催菜」
    func send(_ t: Ticket) {
        let lines = t.unsentLines.filter { $0.course <= 1 }
        guard !lines.isEmpty else {
            show("沒有新的品項要送", tone: .neutral)
            return
        }
        let first = !t.lines.contains(where: \.isSent)
        record(.linesSent(LinesSent(ticketId: t.id, lineIds: lines.map(\.id))))
        if settings.printKitchenTickets && mode.usesKitchen { printKitchen(t, lines: lines, mode: first ? .new : .add) }
        show("已送出 \(lines.reduce(0) { $0 + $1.quantity }) 項")
    }

    /// 催菜：第 n 道開始做
    func fire(course: Int, of t: Ticket) {
        let lines = t.unsentLines.filter { $0.course == course }
        guard !lines.isEmpty else { return }
        record(.linesSent(LinesSent(ticketId: t.id, lineIds: lines.map(\.id))))
        if settings.printKitchenTickets { printKitchen(t, lines: lines, mode: .fire) }
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
                    record(.ticketUpdated(TicketUpdated(ticketId: t.id, member: m.ref)))
                    show("會員 \(m.name ?? m.ref.maskedPhone)\(m.tierName.map { "・\($0)" } ?? "")")
                    return
                }
                let created = try await api.createMember(MemberCreate(phone: entry.digits, name: nil))
                record(.ticketUpdated(TicketUpdated(ticketId: t.id, member: created.ref)))
                show("新會員 \(created.ref.maskedPhone) 加入了")
                return
            } catch let e as APIError {
                if case .offline = e {
                    // 離線：先記電話，後台結帳時再對到會員
                    record(.ticketUpdated(TicketUpdated(ticketId: t.id, member: MemberRef(phone: entry.digits))))
                    show("離線，先記下電話 \(MemberRef(phone: entry.digits).maskedPhone)", tone: .warning)
                    return
                }
                problem = e.userMessage
            } catch {
                problem = "查不到，請再試一次"
            }
        }
    }

    func detachMember(from t: Ticket) {
        record(.ticketUpdated(TicketUpdated(ticketId: t.id, clearMember: true)))
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
