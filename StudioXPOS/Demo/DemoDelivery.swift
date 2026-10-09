import Foundation
import POSCore
import POSSync

/// 示範的外送平台：晨麥手作、黃毛丫頭串了 Uber Eats 與 foodpanda（假的），今天已經有幾張外送單（待接、製作中、等外送員）；
/// 設定頁的「來一張」在這台做一張新的。事件和後台（atelier-cms src/lib/delivery）寫的一樣：開單＋品項＋平台代收的付款
enum DemoDelivery {
    static func config(now: Date) -> DeliveryConfig {
        DeliveryConfig(platforms: [
            DeliveryPlatformState(platform: .ubereats, storeName: "Uber Eats", defaultPrepMinutes: 15, lastOrderAt: now.addingTimeInterval(-120)),
            DeliveryPlatformState(platform: .foodpanda, storeName: "foodpanda", defaultPrepMinutes: 12, lastOrderAt: now.addingTimeInterval(-300)),
        ])
    }

    /// 平台的抽成率（估的，萬分之幾）：Uber Eats 2026 年 7 月起約 32.5%、foodpanda 約 35%
    static func commissionBps(_ p: DeliveryPlatform) -> Int { p == .ubereats ? 3_250 : 3_500 }

    /// Uber Eats 11.5 分鐘內要接、foodpanda 8 分鐘（示範用；真的照平台給的）
    static func acceptWindow(_ p: DeliveryPlatform) -> TimeInterval { p == .ubereats ? 690 : 480 }

    /// 一張平台的單（還沒接）：開單、品項、平台代收的付款
    static func events(platform: DeliveryPlatform, ticketId: String, code: String, lines: [TicketLine], businessDate: String, placedAt: Date,
                       customer: String?, note: String?, kind: DeliveryKind = .delivery) -> [EventBody] {
        let subtotal = Money.sum(lines.map(\.gross))
        let commission = subtotal.applying(bps: commissionBps(platform))
        let order = DeliveryOrder(
            platform: platform, orderId: "demo-\(platform.rawValue)-\(code)", code: code, kind: kind, placedAt: placedAt,
            acceptBy: placedAt.addingTimeInterval(acceptWindow(platform)), customerName: customer, customerNote: note,
            subtotal: subtotal, commission: commission, payout: subtotal - commission, estimated: true
        )
        let opened = TicketOpened(ticketId: ticketId, number: "\(platform.prefix)-\(code)", orderType: kind == .pickup ? .takeout : .delivery,
                                  businessDate: businessDate, customerName: customer, delivery: order)
        let payment = Payment(id: "pay-\(ticketId)", tender: .platform, amount: subtotal, reference: "\(platform.label) #\(code)", at: placedAt, by: "delivery")
        return [.ticketOpened(opened), .linesAdded(LinesAdded(ticketId: ticketId, lines: lines)), .paymentAdded(PaymentAdded(ticketId: ticketId, payment: payment))]
    }

    /// 今天已經有的外送單：兩張待接（一張快到期）、一張製作中、一張做好了等外送員
    static func seed(into ledger: Ledger, bootstrap b: Bootstrap, now: Date) throws {
        let cat = b.catalog
        let biz = TaipeiTime.businessDate(now, cutoffHour: b.store.businessDayCutoffHour)
        let picks = cat.items.filter(\.isAvailable)
        guard picks.count >= 4 else { return }
        func lines(_ idx: [(Int, Int)], at: Date) -> [TicketLine] { idx.map { line(cat, picks[$0.0 % picks.count], qty: $0.1, at: at) } }
        let staffId = b.staff.first?.id ?? "delivery"
        let device = b.device.id

        // 製作中（9 分鐘前接的、答應 18 分鐘）、等外送員（做好了）：接單就結帳（平台已經收了錢）
        let accepted: [(DeliveryPlatform, String, [(Int, Int)], Double, DeliveryStatus, String?, String?)] = [
            (.ubereats, "7C4D2", [(0, 2), (3, 1)], 9, .accepted, "陳先生", nil),
            (.foodpanda, "k3m9", [(1, 1), (5, 2)], 22, .ready, "林小姐", "不要辣"),
        ]
        for (p, code, idx, minutesAgo, status, customer, note) in accepted {
            let placed = now.addingTimeInterval(-minutesAgo * 60 - 60)
            let id = "demo-delivery-\(code)"
            let ls = lines(idx, at: placed)
            try ledger.record(events(platform: p, ticketId: id, code: code, lines: ls, businessDate: biz, placedAt: placed, customer: customer, note: note),
                              staffId: "delivery", at: placed)
            let acceptedAt = placed.addingTimeInterval(50)
            try ledger.record([.deliveryUpdated(DeliveryUpdated(ticketId: id, status: .accepted, readyAt: acceptedAt.addingTimeInterval(18 * 60),
                                                                prepMinutes: 18, acceptedBy: device)),
                               .linesSent(LinesSent(ticketId: id, lineIds: ls.map(\.id)))], staffId: staffId, at: acceptedAt)
            if let t = ledger.state.tickets[id] {
                let sale = SaleRecord(ticket: t, closedOn: device, shiftId: ledger.state.openShift(on: device)?.id, closedAt: acceptedAt,
                                      closedBy: staffId, staffName: b.staff.first?.name ?? "", floor: b.floor)
                try ledger.record(.ticketClosed(TicketClosed(ticketId: id, sale: sale)), staffId: staffId, at: acceptedAt.addingTimeInterval(1))
            }
            if status == .ready {
                let doneAt = now.addingTimeInterval(-90)
                try ledger.record([.kitchenUpdated(KitchenUpdated(ticketId: id, lineIds: ls.map(\.id), status: .ready)),
                                   .deliveryUpdated(DeliveryUpdated(ticketId: id, status: .ready,
                                                                    courier: Courier(name: "王大明", status: .arriving, eta: now.addingTimeInterval(4 * 60))))],
                                  staffId: staffId, at: doneAt)
            } else {
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: id, lineIds: [ls[0].id], status: .preparing)), staffId: staffId, at: now.addingTimeInterval(-240))
            }
        }

        // 待接單：剛進來的 Uber Eats、快到期的 foodpanda
        let pending: [(DeliveryPlatform, String, [(Int, Int)], Double, String?, String?)] = [
            (.ubereats, "3F2A1", [(2, 2), (4, 1), (6, 1)], 1.5, "王小姐", "不要香菜，餐具不用"),
            (.foodpanda, "a8x2", [(7, 3)], 5.5, "張先生", nil),
        ]
        for (p, code, idx, minutesAgo, customer, note) in pending {
            let placed = now.addingTimeInterval(-minutesAgo * 60)
            try ledger.record(events(platform: p, ticketId: "demo-delivery-\(code)", code: code, lines: lines(idx, at: placed), businessDate: biz,
                                     placedAt: placed, customer: customer, note: note),
                              staffId: "delivery", at: placed)
        }
    }

    /// 設定頁「來一張」：在這台做一張新的待接單（響一聲、出現在訂單最上面）
    @MainActor
    static func place(platform: DeliveryPlatform, in model: POSModel) {
        let picks = model.catalog.items.filter(\.isAvailable)
        guard !picks.isEmpty else { return }
        let now = Date()
        let n = Int(now.timeIntervalSince1970) % 997
        let idx = [(n, 1 + n % 2), (n * 7 + 3, 1)]
        let ls = idx.map { line(model.catalog, picks[$0.0 % picks.count], qty: $0.1, at: now) }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<5).map { i in alphabet[(n * (i + 3) + i * 11) % alphabet.count] })
        let names = ["周先生", "蔡小姐", "許小姐", "郭先生"]
        model.record(events(platform: platform, ticketId: UUID().uuidString.lowercased(), code: platform == .foodpanda ? code.lowercased().prefix(4).description : code,
                            lines: ls, businessDate: model.businessDate, placedAt: now, customer: names[n % names.count], note: n % 3 == 0 ? "多一份餐具" : nil))
    }

    private static func line(_ cat: Catalog, _ item: MenuItem, qty: Int, at: Date) -> TicketLine {
        TicketLine(id: UUID().uuidString.lowercased(), itemId: item.id, name: item.name, categoryId: item.categoryId,
                   categoryName: cat.category(item.categoryId)?.name, unitPrice: item.price, modifiers: [], quantity: qty,
                   station: cat.station(for: item), taxKind: item.taxKind, addedAt: at, addedBy: "delivery")
    }
}
