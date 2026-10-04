import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範：黃毛丫頭（夜市的滷味攤，全外帶＋叫號）。
///
/// 菜單照店裡的價目表（後台「攤位菜單」，2026-10-04 讀的）：太空鴨品、人氣推薦、厚滷特選三類 36 樣。
/// - 價目表寫兩個價格的（鴨胸 140/150）做成兩個規格「140」「150」：點的時候選（右欄的大鍵「加入 NT$150」），
///   單子、收據、廚房上是「鴨胸 150」。規格是菜單本來就有的（每個規格自己的價格），不用每次在鍵盤打時價
/// - 份量（3入、1串、5入…）寫在品項的單位（MenuItem.unit）
///
/// 營業模式是「櫃台點餐」（先結帳、印取餐號碼、出餐叫號），沒有內用、桌位、訂位、會員；
/// 有廚房螢幕（滷好了叫號），沒有分出單站、這台也沒有廚房出單機（不印廚房單）。夜市攤先不開發票（收據是交易明細）。
/// 叫號是後台存號碼（native），用在外帶取餐：客人夾好、結帳完成時自動取號、印號碼牌，滷好了在右欄叫號（先做好的先叫）。
/// 三個人：阿珠（店長，PIN 1234）、小翔（夾菜收銀，PIN 2580）、老闆娘（負責人，PIN 0000）。銷售紀錄、人名是編的。
extension DemoStore {
    static func yellowgirlBootstrap(now: Date) -> Bootstrap {
        Bootstrap(
            version: DemoHistory.yellowgirlVersion, serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "攤位收銀", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "黃毛丫頭", legalName: "黃毛丫頭", receiptFooter: "滷好了叫號・掃號碼牌上的 QR 看現在叫到幾號",
                serviceChargeBps: 0, serviceChargeOn: [], tipsEnabled: false, defaultOrderType: .takeout, tableTimeLimitMinutes: 0,
                businessDayCutoffHour: 4, discountLimitBps: 1000, discountPresetsBps: [500, 1000],
                serviceModes: [.counter], defaultServiceMode: .counter
            ),
            // 全外帶：沒有桌位、訂位、會員、預約、儲值；有廚房螢幕（滷好了叫號）與叫號
            features: FeatureFlags(seating: false, kitchen: true, reservations: false, invoice: false, members: false, waitlistSMS: false,
                                   appointments: false, accounts: false, commission: false, queue: true),
            catalog: yellowgirlCatalog,
            floor: .empty,
            staff: yellowgirlStaff,
            invoice: .disabled,
            mesh: MeshConfig(key: String(repeating: "7a", count: 32), enabled: false),
            queue: QueueConfig(mode: DemoQueue.mode, customerUrl: "https://cms.yellowgirl.tw/q?no={number}&waiting={waiting}",
                               ticket: QueueTicketLayout(), usage: [.takeout])
        )
    }

    // MARK: 菜單（店裡的價目表）

    static let yellowgirlCatalog: Catalog = {
        let categories = [
            MenuCategory(id: "yg-duck", name: "太空鴨品", swatch: .clay, sortOrder: 1),
            MenuCategory(id: "yg-popular", name: "人氣推薦", swatch: .butter, sortOrder: 2),
            MenuCategory(id: "yg-braised", name: "厚滷特選", swatch: .peach, sortOrder: 3),
        ]
        /// 一樣：名字、價格（max：價目表的第二個價格，做成兩個規格）、份量（單位）、品號
        func item(_ id: String, _ cat: String, _ name: String, _ price: Int, max: Int? = nil, note: String? = nil, plu: Int) -> MenuItem {
            let variants: [ItemVariant]? = max.map { hi in
                [price, hi].map { p in ItemVariant(id: "\(id)-\(p)", options: ["\(p)"], price: Money(dollars: p)) }
            }
            return MenuItem(id: id, categoryId: cat, name: name, price: Money(dollars: price), plu: String(plu), unit: note ?? "份",
                            sortOrder: plu, optionNames: max == nil ? nil : ["價位"], variants: variants)
        }
        let items: [MenuItem] = [
            // 太空鴨品
            item("yg-duck-breast", "yg-duck", "鴨胸", 140, max: 150, plu: 101),
            item("yg-duck-leg", "yg-duck", "鴨腿", 150, max: 160, plu: 102),
            item("yg-duck-head", "yg-duck", "鴨頭", 60, plu: 103),
            item("yg-duck-brains", "yg-duck", "頭粒", 30, plu: 104),
            item("yg-duck-neck", "yg-duck", "鴨脖", 40, plu: 105),
            item("yg-duck-wing", "yg-duck", "鴨翅", 40, plu: 106),
            item("yg-duck-gizzard", "yg-duck", "鴨腱", 35, max: 40, plu: 107),
            item("yg-duck-intestines", "yg-duck", "鴨腸", 40, note: "3入", plu: 108),
            item("yg-duck-tongue", "yg-duck", "鴨舌", 15, plu: 109),
            item("yg-duck-heart", "yg-duck", "鴨心", 35, note: "1串", plu: 110),
            item("yg-duck-skin", "yg-duck", "鴨皮", 20, plu: 111),
            item("yg-duck-feet", "yg-duck", "鴨腳", 15, note: "2入", plu: 112),
            // 人氣推薦
            item("yg-dried-tofu", "yg-popular", "豆干", 15, note: "5入", plu: 201),
            item("yg-seaweed", "yg-popular", "海帶", 30, note: "2入", plu: 202),
            item("yg-rice-blood", "yg-popular", "米血", 20, plu: 203),
            item("yg-rice-sausage", "yg-popular", "米腸", 35, plu: 204),
            item("yg-quail-eggs", "yg-popular", "鳥蛋", 25, note: "4入", plu: 205),
            item("yg-tofu-skin", "yg-popular", "豆包", 30, plu: 206),
            item("yg-knuckles", "yg-popular", "腳崙", 35, note: "5入", plu: 207),
            item("yg-tempura", "yg-popular", "甜不辣", 35, note: "2入", plu: 208),
            item("yg-duck-blood", "yg-popular", "鴨米血", 30, plu: 209),
            item("yg-big-tofu", "yg-popular", "大豆干", 40, plu: 210),
            item("yg-orchid-tofu", "yg-popular", "蘭花干", 40, plu: 211),
            item("yg-tofu", "yg-popular", "豆腐", 35, note: "特製", plu: 212),
            // 厚滷特選
            item("yg-pork-intestine", "yg-braised", "豬大腸", 45, plu: 301),
            item("yg-chicken-feet", "yg-braised", "雞腳", 15, note: "2入", plu: 302),
            item("yg-chicken-wing", "yg-braised", "雞翅", 25, note: "2入", plu: 303),
            item("yg-drumette", "yg-braised", "翅腿", 15, plu: 304),
            item("yg-pork-skin", "yg-braised", "豬皮", 35, plu: 305),
            item("yg-pork-heart", "yg-braised", "豬心", 30, plu: 306),
            item("yg-pork-tongue", "yg-braised", "豬舌", 55, max: 60, plu: 307),
            item("yg-cartilage", "yg-braised", "樓梯", 25, plu: 308),
            item("yg-chicken-heart", "yg-braised", "雞心", 15, note: "1串", plu: 309),
            item("yg-taro-cake", "yg-braised", "芋粿", 15, plu: 310),
            item("yg-chicken-butt", "yg-braised", "七里香", 25, note: "1串", plu: 311),
            item("yg-head-skin", "yg-braised", "豬頭皮", 35, plu: 312),
        ]
        return Catalog(categories: categories, items: items)
    }()

    // MARK: 人員

    static let yellowgirlStaff: [StaffMember] = [
        person("s-yg-zhu", "阿珠", .manager, "1234", .butter, title: "店長"),
        person("s-yg-xiang", "小翔", .cashier, "2580", .peach, title: "夾菜收銀"),
        person("s-yg-boss", "老闆娘", .owner, "0000", .rose, title: "負責人"),
    ]

    // MARK: 今天

    /// 傍晚開班、兩個人上班；今天結帳的外帶單照順序取了號碼（1–33）：前面的都拿走了，24 號過號，
    /// 現在叫到 27，28–33 在等（29 先滷好了、28 和 30 在滷、31–33 剛結帳）；攤位前還有兩張正在夾的單（還沒結帳、沒有號碼）
    func seedYellowgirl(into ledger: Ledger) throws {
        guard let plan = yellowgirl else { return }
        let now = createdAt
        let s = DemoSeeder(ledger: ledger, bootstrap: bootstrap, now: now)
        let zhu = "s-yg-zhu", xiang = "s-yg-xiang"
        try s.openShift(by: zhu, clockIn: [zhu, xiang], cash: Money(dollars: 3_000), at: now.addingTimeInterval(-3.3 * 3600))

        for o in plan.orders {
            let lines = o.picks.map { s.line($0.itemId, $0.quantity, variant: $0.variantId, by: o.cashier, at: o.openedAt) }
            try ledger.record(.ticketOpened(TicketOpened(ticketId: o.id, number: o.number, orderType: .takeout, serviceChargeBps: 0,
                                                         businessDate: s.businessDate, serviceMode: .counter)),
                              staffId: o.cashier, at: o.openedAt)
            try ledger.record(.linesAdded(LinesAdded(ticketId: o.id, lines: lines)), staffId: o.cashier, at: o.openedAt.addingTimeInterval(30))
            // 和收銀台結帳一樣：送進廚房和結帳一起（結帳之後的「送單」不算）→ 結帳完成才取號（號碼掛在已經結帳的單上）
            let ids = lines.map(\.id)
            try ledger.record(.linesSent(LinesSent(ticketId: o.id, lineIds: ids)), staffId: o.cashier, at: o.closedAt.addingTimeInterval(-6))
            try s.close(o.id, at: o.closedAt.addingTimeInterval(-5), by: o.cashier, pay: [DemoPay(o.tender)])
            try ledger.record(.ticketUpdated(TicketUpdated(ticketId: o.id, queueNumber: o.queue)), staffId: o.cashier, at: o.closedAt.addingTimeInterval(2))
            // 廚房（滷味台）的進度
            let readyAt = min(o.closedAt.addingTimeInterval(6 * 60), now.addingTimeInterval(-60))
            switch o.kitchen {
            case .served:
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: o.id, lineIds: ids, status: .ready)), staffId: zhu, at: readyAt)
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: o.id, lineIds: ids, status: .served)), staffId: zhu,
                                  at: min(readyAt.addingTimeInterval(3 * 60), now.addingTimeInterval(-30)))
            case .ready:
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: o.id, lineIds: ids, status: .ready)), staffId: zhu, at: readyAt)
            case .preparing:
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: o.id, lineIds: ids, status: .preparing)), staffId: zhu,
                                  at: min(o.closedAt.addingTimeInterval(60), now.addingTimeInterval(-20)))
            case .new, .sent:
                break
            }
        }

        // 攤位前正在夾的（還沒結帳）：一位現場的、一位打電話來訂等一下來拿
        for b in plan.baskets {
            let lines = b.picks.map { s.line($0.itemId, $0.quantity, variant: $0.variantId, by: b.cashier, at: b.openedAt) }
            try ledger.record(.ticketOpened(TicketOpened(ticketId: b.id, number: b.number, orderType: .takeout, serviceChargeBps: 0,
                                                         businessDate: s.businessDate, customerName: b.customerName, serviceMode: .counter)),
                              staffId: b.cashier, at: b.openedAt)
            try ledger.record(.linesAdded(LinesAdded(ticketId: b.id, lines: lines)), staffId: b.cashier, at: b.openedAt.addingTimeInterval(40))
        }
    }
}

/// 黃毛丫頭的「今天」：開示範時算一次，記進這台的單（DemoStore.seedYellowgirl）與示範後台的叫號（DemoQueue）用同一份，
/// 號碼、單號、哪一張單才對得起來。一籃怎麼夾（basket）後台的歷史也用
nonisolated struct YellowgirlToday: Sendable {
    /// 夾了一樣
    nonisolated struct Pick: Sendable {
        var itemId: String
        var quantity: Int
        var variantId: String?
    }

    /// 結帳了、取了號碼的外帶單
    nonisolated struct Order: Sendable {
        var id: String
        var number: String
        var queue: Int
        var openedAt: Date
        var closedAt: Date
        var cashier: String
        var picks: [Pick]
        var tender: Tender
        /// 廚房的進度：前面的都拿走了，最後幾張還在滷
        var kitchen: KitchenStatus

        var itemCount: Int { picks.reduce(0) { $0 + $1.quantity } }
        /// 號碼帶的一句話（和收銀台結帳時一樣：「A012・3 項」）
        var label: String { "\(number)・\(itemCount) 項" }
    }

    /// 正在夾、還沒結帳的
    nonisolated struct Basket: Sendable {
        var id: String
        var number: String
        var openedAt: Date
        var cashier: String
        var customerName: String?
        var picks: [Pick]
    }

    var orders: [Order]
    var baskets: [Basket]
    var current: Int
    var calledAt: Date
    var waiting: [Int]
    var missed: [Int]
    var served: Int
    var nextNo: Int

    /// 今天：33 張單（號碼 1–33），最後十張的時間排緊一點（廚房螢幕看得到還在做的）
    static func make(now: Date, catalog: Catalog) -> YellowgirlToday {
        var rng = SeededRandom(seed: 20261004)
        let count = 33
        // 幾分鐘前結帳：1–23 號平均分在 175–34 分鐘前，24–33 號照下面這一串
        let recent: [Double] = [27, 25, 22, 19, 16, 13, 10, 7, 4.5, 2]
        var orders: [Order] = []
        for k in 1...count {
            let minutesAgo: Double = k <= 23 ? 175 - Double(k - 1) * (141.0 / 22.0) : recent[k - 24]
            let closedAt = now.addingTimeInterval(-minutesAgo * 60 + Double(rng.next(40)))
            let openedAt = closedAt.addingTimeInterval(-Double(60 + rng.next(90)))
            let kitchen: KitchenStatus = switch k {
            case 24, 27, 29: .ready
            case 28, 30: .preparing
            case 31, 32, 33: .sent
            default: .served
            }
            let cashier = rng.weighted([("s-yg-xiang", 6), ("s-yg-zhu", 3)]) ?? "s-yg-xiang"
            let tender = rng.weighted([(Tender.cash, 62), (.linePay, 22), (.jkoPay, 16)]) ?? .cash
            orders.append(Order(id: "demo-yg-sale-\(k)", number: String(format: "A%03d", k), queue: k, openedAt: openedAt, closedAt: closedAt,
                                cashier: cashier, picks: basket(catalog, rng: &rng), tender: tender, kitchen: kitchen))
        }
        let baskets = [
            Basket(id: "demo-yg-open-1", number: String(format: "A%03d", count + 1), openedAt: now.addingTimeInterval(-90), cashier: "s-yg-xiang",
                   customerName: nil, picks: basket(catalog, rng: &rng)),
            Basket(id: "demo-yg-open-2", number: String(format: "A%03d", count + 2), openedAt: now.addingTimeInterval(-6 * 60), cashier: "s-yg-zhu",
                   customerName: "電話・陳小姐", picks: basket(catalog, rng: &rng)),
        ]
        return YellowgirlToday(orders: orders, baskets: baskets, current: 27, calledAt: now.addingTimeInterval(-90), waiting: Array(28...count),
                               missed: [24], served: 25, nextNo: count + 1)
    }

    /// 一籃：3–8 樣、NT$150–500 左右（鴨品、人氣、厚滷都夾一點；便宜的偶爾兩份；兩個價位的隨便選一個）
    static func basket(_ catalog: Catalog, rng: inout SeededRandom) -> [Pick] {
        let target = 150 + rng.next(351)
        var picks: [Pick] = []
        var used = Set<String>()
        var total = 0
        var tries = 0
        while picks.count < 8 && tries < 60 {
            tries += 1
            let category = rng.weighted([("yg-duck", 30), ("yg-popular", 45), ("yg-braised", 25)]) ?? "yg-popular"
            guard let item = rng.pick(catalog.items(in: category)), !used.contains(item.id) else { continue }
            let variant = item.hasVariants ? rng.pick(item.activeVariants) : nil
            let unit = item.price(of: variant).dollars
            let quantity = unit <= 20 && rng.chance(35) ? 2 : 1
            if picks.count >= 3 && total + unit * quantity > 500 {
                if total >= 150 { break }
                continue
            }
            picks.append(Pick(itemId: item.id, quantity: quantity, variantId: variant?.id))
            used.insert(item.id)
            total += unit * quantity
            if picks.count >= 3 && total >= target { break }
        }
        return picks
    }
}
