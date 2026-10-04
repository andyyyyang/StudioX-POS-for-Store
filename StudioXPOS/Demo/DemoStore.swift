import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 示範模式：虛構的「晨麥手作」（台南的咖啡、早午餐、甜點、麵包），不用配對、資料只在這次開著的時候。
/// 人員：Leslie K.（店長，PIN 1234）、Cameron W.（收銀，PIN 2580）、Jacob J.（領班，PIN 1111）、王小美（負責人，PIN 0000）
struct DemoStore {
    let bootstrap: Bootstrap
    let api: DemoAPI

    init() {
        let now = Date()
        let period = InvoicePeriod(date: now)
        let invoice = InvoiceSettings(
            enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", sellerAddress: "台南市中西區民族路二段1號",
            qrKey: "6E8B2A1C4D5F70819A2B3C4D5E6F7081",
            rolls: [
                // 示範的單往回 6 個多小時：剛換期的時候會落在上一期，所以上一期也給一段
                InvoiceRoll(id: "demo-roll-0", period: period.previous.code, track: "XC", start: 2345600, end: 2345649),
                InvoiceRoll(id: "demo-roll-1", period: period.code, track: "XD", start: 12345600, end: 12345699),
                InvoiceRoll(id: "demo-roll-2", period: period.next.code, track: "XF", start: 22345600, end: 22345649),
            ]
        )
        bootstrap = Bootstrap(
            version: "demo", serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "晨麥手作", legalName: "晨麥手作有限公司", taxId: "04595257", address: "台南市中西區民族路二段1號", phone: "06-222-0000",
                receiptFooter: "謝謝光臨・Wi-Fi：chenmai / 22200000", serviceChargeBps: 1000, serviceChargeOn: [.dineIn], tipsEnabled: false,
                defaultOrderType: .dineIn, tableTimeLimitMinutes: 90, businessDayCutoffHour: 4, discountLimitBps: 1000
            ),
            features: FeatureFlags(seating: true, kitchen: true, reservations: true, invoice: true, members: true, waitlistSMS: true),
            catalog: Self.catalog,
            floor: Self.floor,
            staff: Self.staff,
            invoice: invoice,
            mesh: MeshConfig(key: String(repeating: "5d", count: 32), enabled: false)
        )
        api = DemoAPI(bootstrap: bootstrap, reservations: Self.reservations(now: now))
    }

    // MARK: 菜單

    static let catalog: Catalog = {
        let sugar = ModifierGroup(id: "g-sugar", name: "甜度", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "s-full", name: "正常甜", isDefault: true), ModifierOption(id: "s-less", name: "少糖"),
            ModifierOption(id: "s-half", name: "半糖"), ModifierOption(id: "s-light", name: "微糖"), ModifierOption(id: "s-none", name: "無糖"),
        ], sortOrder: 1)
        let ice = ModifierGroup(id: "g-ice", name: "冰塊", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "i-full", name: "正常冰", isDefault: true), ModifierOption(id: "i-less", name: "少冰"),
            ModifierOption(id: "i-light", name: "微冰"), ModifierOption(id: "i-none", name: "去冰"),
            ModifierOption(id: "i-warm", name: "溫"), ModifierOption(id: "i-hot", name: "熱"),
        ], sortOrder: 2)
        let toppings = ModifierGroup(id: "g-top", name: "加料", minSelect: 0, maxSelect: 3, options: [
            ModifierOption(id: "t-pearl", name: "珍珠", priceDelta: Money(dollars: 10)), ModifierOption(id: "t-coco", name: "椰果", priceDelta: Money(dollars: 10)),
            ModifierOption(id: "t-pudding", name: "布丁", priceDelta: Money(dollars: 15)), ModifierOption(id: "t-grass", name: "仙草凍", priceDelta: Money(dollars: 10)),
        ], sortOrder: 3)
        let temp = ModifierGroup(id: "g-temp", name: "溫度", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "c-hot", name: "熱", isDefault: true), ModifierOption(id: "c-iced", name: "冰"),
        ], sortOrder: 1)
        let milk = ModifierGroup(id: "g-milk", name: "奶", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "m-dairy", name: "鮮奶", isDefault: true), ModifierOption(id: "m-oat", name: "燕麥奶", priceDelta: Money(dollars: 20)),
        ], sortOrder: 2)
        let shot = ModifierGroup(id: "g-shot", name: "加購", minSelect: 0, maxSelect: 2, options: [
            ModifierOption(id: "x-shot", name: "多一份濃縮", priceDelta: Money(dollars: 30)), ModifierOption(id: "x-syrup", name: "香草糖漿", priceDelta: Money(dollars: 15)),
        ], sortOrder: 3)
        let egg = ModifierGroup(id: "g-egg", name: "蛋", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "e-soft", name: "半熟", isDefault: true), ModifierOption(id: "e-hard", name: "全熟"),
        ], sortOrder: 1)
        let side = ModifierGroup(id: "g-side", name: "附餐", minSelect: 0, maxSelect: 1, options: [
            ModifierOption(id: "d-salad", name: "換沙拉"), ModifierOption(id: "d-fries", name: "換薯條", priceDelta: Money(dollars: 30)),
        ], sortOrder: 2)

        let categories = [
            MenuCategory(id: "c-coffee", name: "咖啡", swatch: .sand, sortOrder: 1, station: "吧台"),
            MenuCategory(id: "c-tea", name: "茶飲", swatch: .mint, sortOrder: 2, station: "吧台"),
            MenuCategory(id: "c-brunch", name: "早午餐", swatch: .peach, sortOrder: 3, station: "廚房"),
            MenuCategory(id: "c-dessert", name: "甜點", swatch: .rose, sortOrder: 4, station: "吧台"),
            MenuCategory(id: "c-bread", name: "麵包", swatch: .butter, sortOrder: 5),
            MenuCategory(id: "c-extra", name: "加購", swatch: .lavender, sortOrder: 6),
        ]
        func item(_ id: String, _ cat: String, _ name: String, _ price: Int, short: String? = nil, plu: String, groups: [String] = [], unit: String = "份", open: Bool = false, available: Bool = true, barcode: String? = nil) -> MenuItem {
            MenuItem(id: id, categoryId: cat, name: name, shortName: short, price: Money(dollars: price), openPrice: open, barcode: barcode, plu: plu,
                     modifierGroupIds: groups, isAvailable: available, unit: unit, sortOrder: Int(plu) ?? 0)
        }
        let items = [
            item("p-americano", "c-coffee", "美式咖啡", 90, short: "美式", plu: "101", groups: ["g-temp", "g-shot"], unit: "杯"),
            item("p-latte", "c-coffee", "拿鐵", 120, plu: "102", groups: ["g-temp", "g-milk", "g-shot"], unit: "杯"),
            item("p-cappuccino", "c-coffee", "卡布奇諾", 120, short: "卡布", plu: "103", groups: ["g-temp", "g-milk"], unit: "杯"),
            item("p-flatwhite", "c-coffee", "小白咖啡", 130, plu: "104", groups: ["g-milk"], unit: "杯"),
            item("p-pourover", "c-coffee", "手沖單品", 180, short: "手沖", plu: "105", unit: "杯", open: true),
            item("p-milktea", "c-tea", "珍珠奶茶", 70, short: "珍奶", plu: "201", groups: ["g-sugar", "g-ice", "g-top"], unit: "杯"),
            item("p-oolong", "c-tea", "四季春青茶", 50, short: "四季春", plu: "202", groups: ["g-sugar", "g-ice"], unit: "杯"),
            item("p-lemon", "c-tea", "蜂蜜檸檬", 75, plu: "203", groups: ["g-sugar", "g-ice"], unit: "杯"),
            item("p-wintermelon", "c-tea", "冬瓜檸檬", 60, plu: "204", groups: ["g-ice"], unit: "杯"),
            item("p-pancake", "c-brunch", "酥皮鬆餅", 220, plu: "301", groups: ["g-side"]),
            item("p-bagel", "c-brunch", "炙燒鮭魚貝果", 260, short: "鮭魚貝果", plu: "302", groups: ["g-egg", "g-side"]),
            item("p-croissant-egg", "c-brunch", "炒蛋可頌", 180, plu: "303", groups: ["g-egg"]),
            item("p-omelette", "c-brunch", "歐姆蛋盤", 240, plu: "304", groups: ["g-side"]),
            item("p-caesar", "c-brunch", "凱薩沙拉", 200, plu: "305"),
            item("p-basque", "c-dessert", "巴斯克乳酪蛋糕", 150, short: "巴斯克", plu: "401"),
            item("p-lemontart", "c-dessert", "檸檬塔", 130, plu: "402"),
            item("p-canele", "c-dessert", "可麗露", 80, plu: "403", available: false),
            item("p-tiramisu", "c-dessert", "提拉米蘇", 160, plu: "404"),
            item("p-butter-croissant", "c-bread", "原味可頌", 65, plu: "501", barcode: "4712345678901"),
            item("p-cinnamon", "c-bread", "肉桂捲", 85, plu: "502"),
            item("p-salt", "c-bread", "鹽可頌", 55, plu: "503"),
            item("p-toast", "c-bread", "手作吐司", 120, plu: "504", open: true),
            item("p-extra-shot", "c-extra", "加點濃縮", 30, plu: "601"),
            item("p-bag", "c-extra", "提袋", 2, plu: "602"),
        ]
        return Catalog(categories: categories, items: items, modifierGroups: [sugar, ice, toppings, temp, milk, shot, egg, side])
    }()

    // MARK: 桌位

    static let floor = FloorPlan(areas: [
        FloorArea(id: "f1", name: "1F", sortOrder: 1, tables: [
            DiningTable(id: "t-a1", areaId: "f1", name: "A1", seats: 4, shape: .square, x: 6, y: 10, width: 14, height: 18),
            DiningTable(id: "t-a2", areaId: "f1", name: "A2", seats: 4, shape: .square, x: 26, y: 10, width: 14, height: 18),
            DiningTable(id: "t-a3", areaId: "f1", name: "A3", seats: 4, shape: .square, x: 46, y: 10, width: 14, height: 18),
            DiningTable(id: "t-a4", areaId: "f1", name: "A4", seats: 6, shape: .rect, x: 6, y: 40, width: 26, height: 18),
            DiningTable(id: "t-a5", areaId: "f1", name: "A5", seats: 2, shape: .round, x: 40, y: 40, width: 12, height: 18),
            DiningTable(id: "t-a6", areaId: "f1", name: "A6", seats: 2, shape: .round, x: 56, y: 40, width: 12, height: 18),
            DiningTable(id: "t-b1", areaId: "f1", name: "吧台1", seats: 1, shape: .bar, x: 76, y: 8, width: 16, height: 10),
            DiningTable(id: "t-b2", areaId: "f1", name: "吧台2", seats: 1, shape: .bar, x: 76, y: 22, width: 16, height: 10),
            DiningTable(id: "t-b3", areaId: "f1", name: "吧台3", seats: 1, shape: .bar, x: 76, y: 36, width: 16, height: 10),
            DiningTable(id: "t-b4", areaId: "f1", name: "吧台4", seats: 1, shape: .bar, x: 76, y: 50, width: 16, height: 10),
            DiningTable(id: "t-a7", areaId: "f1", name: "A7", seats: 8, shape: .booth, x: 6, y: 70, width: 40, height: 20),
        ]),
        FloorArea(id: "f2", name: "2F", sortOrder: 2, tables: [
            DiningTable(id: "t-c1", areaId: "f2", name: "C1", seats: 4, shape: .square, x: 8, y: 12, width: 16, height: 20),
            DiningTable(id: "t-c2", areaId: "f2", name: "C2", seats: 4, shape: .square, x: 30, y: 12, width: 16, height: 20),
            DiningTable(id: "t-c3", areaId: "f2", name: "C3", seats: 6, shape: .rect, x: 54, y: 12, width: 28, height: 20),
            DiningTable(id: "t-c4", areaId: "f2", name: "C4", seats: 2, shape: .round, x: 8, y: 50, width: 14, height: 20),
            DiningTable(id: "t-c5", areaId: "f2", name: "C5", seats: 2, shape: .round, x: 28, y: 50, width: 14, height: 20),
            DiningTable(id: "t-c6", areaId: "f2", name: "C6", seats: 10, shape: .booth, x: 50, y: 50, width: 36, height: 28),
        ]),
        FloorArea(id: "f3", name: "戶外", sortOrder: 3, tables: [
            DiningTable(id: "t-d1", areaId: "f3", name: "D1", seats: 2, shape: .round, x: 10, y: 20, width: 14, height: 20),
            DiningTable(id: "t-d2", areaId: "f3", name: "D2", seats: 2, shape: .round, x: 34, y: 20, width: 14, height: 20),
            DiningTable(id: "t-d3", areaId: "f3", name: "D3", seats: 4, shape: .square, x: 58, y: 20, width: 16, height: 20),
        ]),
    ])

    // MARK: 人員

    static let staff: [StaffMember] = [
        member("s-leslie", "Leslie K.", .manager, "1234", .lavender),
        member("s-cameron", "Cameron W.", .cashier, "2580", .mint),
        member("s-jacob", "Jacob J.", .supervisor, "1111", .rose),
        member("s-owner", "王小美", .owner, "0000", .peach),
    ]

    static func member(_ id: String, _ name: String, _ role: StaffRole, _ pin: String, _ swatch: Swatch) -> StaffMember {
        // 示範用的少一點雜湊次數：每次開示範都要算
        let salt = "demo-\(id)"
        return StaffMember(id: id, name: name, role: role, pinHash: Staff.hash(pin: pin, salt: salt, iterations: 256), pinSalt: salt, pinIterations: 256, swatch: swatch)
    }

    // MARK: 今天已經發生的事

    /// 早上開班、十幾張已經結帳的單、幾桌正在吃、一桌待清
    func seed(into ledger: Ledger) throws {
        let now = Date()
        let cat = Self.catalog
        let staff = Self.staff
        let leslie = staff[0].id, cameron = staff[1].id
        let biz = TaipeiTime.businessDate(now, cutoffHour: 4)
        let shiftId = "demo-shift"
        try ledger.record(.shiftOpened(ShiftOpened(shiftId: shiftId, openingCash: Money(dollars: 3000), businessDate: biz)), staffId: leslie, at: now.addingTimeInterval(-7 * 3600))
        try ledger.record([.clockedIn(StaffRef(staffId: leslie)), .clockedIn(StaffRef(staffId: cameron)), .clockedIn(StaffRef(staffId: staff[2].id))], staffId: leslie, at: now.addingTimeInterval(-7 * 3600 + 60))

        var rng = SeededRandom(seed: 20261003)
        let orders: [[(String, Int, [String])]] = [
            [("p-latte", 2, ["c-iced", "m-oat"]), ("p-pancake", 1, [])],
            [("p-milktea", 3, ["s-half", "i-less", "t-pearl"])],
            [("p-americano", 1, ["c-hot"]), ("p-butter-croissant", 2, [])],
            [("p-bagel", 2, ["e-soft"]), ("p-cappuccino", 2, ["c-hot", "m-dairy"]), ("p-basque", 1, [])],
            [("p-oolong", 2, ["s-light", "i-none"]), ("p-cinnamon", 1, [])],
            [("p-omelette", 1, ["d-salad"]), ("p-flatwhite", 1, ["m-dairy"])],
            [("p-lemontart", 2, []), ("p-americano", 2, ["c-iced"])],
            [("p-croissant-egg", 3, ["e-hard"]), ("p-latte", 3, ["c-hot", "m-dairy"])],
            [("p-tiramisu", 1, []), ("p-lemon", 1, ["s-half", "i-less"])],
            [("p-salt", 4, []), ("p-bag", 1, [])],
            [("p-caesar", 2, []), ("p-wintermelon", 2, ["i-light"])],
            [("p-pancake", 2, ["d-fries"]), ("p-milktea", 2, ["s-less", "i-full", "t-pudding"])],
            [("p-latte", 1, ["c-iced", "m-oat", "x-shot"])],
            [("p-basque", 2, []), ("p-americano", 2, ["c-hot"])],
            [("p-bagel", 1, ["e-soft", "d-salad"]), ("p-oolong", 1, ["s-none", "i-less"])],
            [("p-cinnamon", 3, []), ("p-latte", 2, ["c-hot", "m-dairy"])],
            [("p-omelette", 2, []), ("p-cappuccino", 2, ["c-iced", "m-oat"])],
            [("p-milktea", 5, ["s-half", "i-less", "t-pearl"])],
        ]
        let tenders: [Tender] = [.cash, .card, .linePay, .cash, .jkoPay, .cash, .card, .cash, .pxPay]
        let span = 6.5 * 3600
        for (i, order) in orders.enumerated() {
            let at = now.addingTimeInterval(-span + span * Double(i) / Double(orders.count) + Double(rng.next(600)))
            let dineIn = i % 3 != 2
            let ticketId = "demo-sale-\(i)"
            let tableIds = dineIn ? [Self.floor.allTables[i % 9].id] : []
            let number = ledger.state.nextTicketNumber(deviceCode: "A", businessDate: biz)
            try ledger.record(.ticketOpened(TicketOpened(ticketId: ticketId, number: number, orderType: dineIn ? .dineIn : .takeout, tableIds: tableIds,
                                                         guests: dineIn ? 2 + i % 3 : 0, serviceChargeBps: dineIn ? 1000 : 0, businessDate: biz)),
                              staffId: cameron, at: at)
            let lines = order.map { line(cat, $0.0, $0.1, $0.2, by: cameron, at: at) }
            try ledger.record([.linesAdded(LinesAdded(ticketId: ticketId, lines: lines)), .linesSent(LinesSent(ticketId: ticketId, lineIds: lines.map(\.id)))],
                              staffId: cameron, at: at.addingTimeInterval(40))
            try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: ticketId, lineIds: lines.map(\.id), status: .served)), staffId: staff[2].id, at: at.addingTimeInterval(900))

            guard var t = ledger.state.tickets[ticketId] else { continue }
            if i == 4 { t.invoiceBuyer = .business(taxId: "22099131", title: "台灣積體電路製造股份有限公司") }
            if i == 7 { t.invoiceBuyer = .consumer(carrier: .mobileBarcode("/AB2+3CD")) }
            if i == 10 { t.invoiceBuyer = .donation(loveCode: "8455") }
            if t.invoiceBuyer != .paper {
                try ledger.record(.ticketUpdated(TicketUpdated(ticketId: ticketId, invoiceBuyer: t.invoiceBuyer)), staffId: cameron, at: at.addingTimeInterval(1500))
            }
            let due = t.totals.amountDue
            let tender = tenders[i % tenders.count]
            let pay = tender == .cash
                ? Payment.cash(id: "demo-pay-\(i)", tendered: Money(dollars: ((due.dollars + 99) / 100) * 100), due: due, at: at.addingTimeInterval(1800), by: cameron, shiftId: shiftId)
                : Payment(id: "demo-pay-\(i)", tender: tender, amount: due, reference: tender == .card ? nil : "\(100000 + i)", cardLast4: tender == .card ? "4\(i)21" : nil,
                          at: at.addingTimeInterval(1800), by: cameron, shiftId: shiftId)
            try ledger.record(.paymentAdded(PaymentAdded(ticketId: ticketId, payment: pay)), staffId: cameron, at: at.addingTimeInterval(1800))
            guard let paid = ledger.state.tickets[ticketId] else { continue }
            let closeAt = at.addingTimeInterval(1805)
            let invoice = try InvoiceBuilder.issue(ticket: paid, settings: bootstrap.invoice, allocator: InvoiceAllocator(rolls: bootstrap.invoice.rolls, state: ledger.state),
                                                   deviceId: "demo-register", at: closeAt)
            var closing = paid
            closing.invoice = invoice.stamp
            let sale = SaleRecord(ticket: closing, closedOn: "demo-register", shiftId: shiftId, closedAt: closeAt, closedBy: cameron, staffName: "Cameron W.", floor: Self.floor)
            try ledger.record([.invoiceIssued(InvoiceIssued(ticketId: ticketId, invoice: invoice)), .ticketClosed(TicketClosed(ticketId: ticketId, sale: sale))],
                              staffId: cameron, at: closeAt)
            if dineIn && i < orders.count - 3 {
                try ledger.record(.tableCleaned(TableRef(tableId: tableIds[0])), staffId: cameron, at: closeAt.addingTimeInterval(300))
            }
        }

        // 現在正在吃的
        func open(_ id: String, _ table: String, _ guests: Int, _ items: [(String, Int, [String])], minutesAgo: Double, sent: Bool, billed: Bool = false) throws {
            let at = now.addingTimeInterval(-minutesAgo * 60)
            let number = ledger.state.nextTicketNumber(deviceCode: "A", businessDate: biz)
            try ledger.record(.ticketOpened(TicketOpened(ticketId: id, number: number, orderType: .dineIn, tableIds: [table], guests: guests, serviceChargeBps: 1000, businessDate: biz)),
                              staffId: cameron, at: at)
            guard !items.isEmpty else { return }
            let lines = items.map { line(cat, $0.0, $0.1, $0.2, by: cameron, at: at) }
            try ledger.record(.linesAdded(LinesAdded(ticketId: id, lines: lines)), staffId: cameron, at: at.addingTimeInterval(120))
            if sent {
                try ledger.record(.linesSent(LinesSent(ticketId: id, lineIds: lines.map(\.id))), staffId: cameron, at: at.addingTimeInterval(150))
                try ledger.record(.kitchenUpdated(KitchenUpdated(ticketId: id, lineIds: [lines[0].id], status: .ready)), staffId: staff[2].id, at: at.addingTimeInterval(600))
            }
            if billed { try ledger.record(.billPrinted(TicketRef(ticketId: id)), staffId: cameron, at: now.addingTimeInterval(-120)) }
        }
        try open("demo-open-a2", "t-a2", 4, [("p-bagel", 2, ["e-soft"]), ("p-latte", 2, ["c-iced", "m-oat"]), ("p-pancake", 1, [])], minutesAgo: 34, sent: true)
        try open("demo-open-a5", "t-a5", 2, [], minutesAgo: 3, sent: false)
        try open("demo-open-c3", "t-c3", 5, [("p-omelette", 2, []), ("p-milktea", 3, ["s-half", "i-less", "t-pearl"]), ("p-basque", 2, [])], minutesAgo: 72, sent: true, billed: true)
        try open("demo-open-b1", "t-b1", 1, [("p-flatwhite", 1, ["m-dairy"]), ("p-canele", 1, [])], minutesAgo: 12, sent: true)
        try open("demo-open-d3", "t-d3", 3, [("p-caesar", 1, []), ("p-americano", 2, ["c-iced"])], minutesAgo: 95, sent: true)
    }

    private func line(_ cat: Catalog, _ itemId: String, _ qty: Int, _ optionIds: [String], by: String, at: Date) -> TicketLine {
        let item = cat.item(itemId)!
        let mods: [AppliedModifier] = cat.groups(for: item).flatMap { g in
            g.options.filter { optionIds.contains($0.id) }.map { AppliedModifier(groupId: g.id, groupName: g.name, optionId: $0.id, name: $0.name, priceDelta: $0.priceDelta) }
        }
        return TicketLine(id: UUID().uuidString.lowercased(), itemId: item.id, name: item.name, categoryId: item.categoryId,
                          categoryName: cat.category(item.categoryId)?.name, unitPrice: item.price, modifiers: mods, quantity: qty,
                          station: cat.station(for: item), taxKind: item.taxKind, addedAt: at, addedBy: by)
    }

    func reservations() -> [Reservation] { Self.reservations(now: Date()) }

    static func reservations(now: Date) -> [Reservation] {
        func r(_ id: String, _ kind: ReservationKind, _ name: String, _ phone: String, _ size: Int, _ minutes: Double, tables: [String] = [], status: ReservationStatus = .booked, note: String = "", queue: Int? = nil, source: String = "web") -> Reservation {
            Reservation(id: id, kind: kind, name: name, phone: phone, partySize: size, startsAt: now.addingTimeInterval(minutes * 60), tableIds: tables,
                        status: status, note: note, source: source, queueNumber: queue, createdAt: now.addingTimeInterval(-86_400))
        }
        return [
            r("demo-r1", .reservation, "林小涵", "0912345678", 4, 25, tables: ["t-a4"], note: "有一位吃素"),
            r("demo-r2", .reservation, "陳柏宇", "0922111333", 2, 70, tables: ["t-a6"], source: "phone"),
            r("demo-r3", .reservation, "黃冠廷", "0933222444", 8, 150, tables: ["t-c6"], note: "生日，會帶蛋糕"),
            r("demo-w1", .waitlist, "張家豪", "0955666777", 3, -18, queue: 12, source: "pos"),
            r("demo-w2", .waitlist, "李思妤", "0966777888", 2, -6, queue: 13, source: "pos"),
        ].sorted { $0.startsAt < $1.startsAt }
    }
}

/// 示範的「後台」：收什麼都說好，會員、訂位放在記憶體
actor DemoAPI: POSAPI {
    let base: Bootstrap
    private var reservations: [String: Reservation] = [:]
    private var rollCounter = 0
    private var members: [String: Member] = [
        "0912345678": Member(id: "demo-m1", phone: "0912345678", name: "林小涵", tierName: "金卡會員", lifetimeSpend: Money(dollars: 18_640), visits: 23, lastVisitAt: Date().addingTimeInterval(-6 * 86_400), note: "不吃香菜"),
        "0922111333": Member(id: "demo-m2", phone: "0922111333", name: "陳柏宇", tierName: "一般會員", lifetimeSpend: Money(dollars: 2_380), visits: 4, lastVisitAt: Date().addingTimeInterval(-20 * 86_400), note: nil),
    ]

    init(bootstrap: Bootstrap, reservations: [Reservation]) {
        base = bootstrap
        self.reservations = Dictionary(uniqueKeysWithValues: reservations.map { ($0.id, $0) })
    }

    func bootstrap(ifNoneMatch version: String?) async throws -> Bootstrap {
        if version == base.version { throw APIError.notModified }
        return base
    }

    func push(_ events: [POSEvent]) async throws -> EventsPushResult {
        EventsPushResult(accepted: events.map(\.id), duplicates: [], rejected: [], serverSeq: 0)
    }

    func pull(after serverSeq: Int, limit: Int) async throws -> EventsPage { EventsPage(events: [], next: serverSeq, hasMore: false) }

    func requestRoll(period: String, count: Int) async throws -> RollResponse {
        rollCounter += 1
        let start = 30_000_000 + rollCounter * 1000
        return RollResponse(roll: InvoiceRoll(id: "demo-roll-x\(rollCounter)", period: period, track: "XG", start: start, end: start + count - 1))
    }

    func heartbeat(_ h: Heartbeat) async throws -> HeartbeatResponse { HeartbeatResponse(serverTime: Date(), configVersion: base.version, serverSeq: 0) }

    func member(phone: String) async throws -> Member? { members[phone] }

    func createMember(_ m: MemberCreate) async throws -> Member {
        let new = Member(id: "demo-m-\(m.phone)", phone: m.phone, name: m.name, tierName: "一般會員", lifetimeSpend: .zero, visits: 0, lastVisitAt: nil, note: nil)
        members[m.phone] = new
        return new
    }

    func reservations(date: String) async throws -> [Reservation] { Array(reservations.values) }

    func createReservation(_ input: ReservationInput) async throws -> Reservation {
        let queue = input.kind == .waitlist ? (reservations.values.compactMap(\.queueNumber).max() ?? 13) + 1 : nil
        let r = Reservation(id: UUID().uuidString.lowercased(), kind: input.kind ?? .reservation, name: input.name ?? "", phone: input.phone ?? "",
                            partySize: input.partySize ?? 2, startsAt: input.startsAt ?? Date(), durationMinutes: input.durationMinutes ?? 90,
                            tableIds: input.tableIds ?? [], status: input.status ?? .booked, note: input.note ?? "", source: "pos",
                            queueNumber: queue, createdAt: Date())
        reservations[r.id] = r
        return r
    }

    func updateReservation(id: String, _ input: ReservationInput) async throws -> Reservation {
        var r = reservations[id] ?? Reservation(id: id, kind: input.kind ?? .reservation, name: input.name ?? "", phone: input.phone ?? "",
                                                 partySize: input.partySize ?? 2, startsAt: input.startsAt ?? Date(), createdAt: Date())
        if let v = input.name { r.name = v }
        if let v = input.phone { r.phone = v }
        if let v = input.partySize { r.partySize = v }
        if let v = input.startsAt { r.startsAt = v }
        if let v = input.durationMinutes { r.durationMinutes = v }
        if let v = input.tableIds { r.tableIds = v }
        if let v = input.status { r.status = v }
        if let v = input.note { r.note = v }
        reservations[id] = r
        return r
    }

    func notifyReservation(id: String) async throws {}

    func saveFloor(_ update: FloorUpdate) async throws -> FloorResponse { FloorResponse(floor: FloorPlan(areas: update.areas), version: "demo") }
}

/// 示範資料用的亂數（每次開都一樣）
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ upper: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(upper, 1)))
    }
}
