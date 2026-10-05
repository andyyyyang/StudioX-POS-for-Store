import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範的店：配對畫面「先看看示範」選一家（或啟動參數 `-demo`、`-demo apparel|salon|fitness|yellowgirl`）。
enum DemoKind: String, CaseIterable, Identifiable, Hashable {
    /// 餐廳咖啡「晨麥手作」：桌位、廚房出單、訂位候位
    case cafe
    /// 服飾「Lumi 選物」：顏色尺寸、掃吊牌、業績算給店員
    case apparel
    /// 美業「Mori Hair」：設計師的預約表、儲值金與次數卡
    case salon
    /// 健身「Pulse 健身」：入場報到、會籍與堂數、團課與私人教練
    case fitness
    /// 夜市滷味攤「黃毛丫頭」：店裡真的菜單，全外帶，結帳自動取號、滷好了叫號
    case yellowgirl

    var id: String { rawValue }

    /// 行業（卡片上的小字）
    var industry: String {
        switch self {
        case .cafe: "餐廳咖啡"
        case .apparel: "服飾選物"
        case .salon: "美髮沙龍"
        case .fitness: "健身會館"
        case .yellowgirl: "夜市外帶＋叫號"
        }
    }

    var storeName: String {
        switch self {
        case .cafe: "晨麥手作"
        case .apparel: "Lumi 選物"
        case .salon: "Mori Hair"
        case .fitness: "Pulse 健身"
        case .yellowgirl: "黃毛丫頭"
        }
    }

    /// 一句話：這家示範看得到什麼
    var summary: String {
        switch self {
        case .cafe: "三層樓的桌位、廚房出單、訂位與候位，今天已經有十幾張單"
        case .apparel: "顏色尺寸、掃吊牌條碼、會員折扣，業績算給每位店員"
        case .salon: "設計師的預約表、到店開單，儲值金與剪髮次數卡"
        case .fitness: "入場報到、月卡與堂數、團課名單與私人教練"
        case .yellowgirl: "店裡的滷味菜單，全外帶：結帳完成自動取號、印號碼牌，滷好了在右欄叫號"
        }
    }

    /// 三個重點（卡片下面的小標籤）
    var highlights: [String] {
        switch self {
        case .cafe: ["桌位", "廚房", "訂位"]
        case .apparel: ["規格", "條碼", "業績"]
        case .salon: ["預約", "儲值", "次數卡"]
        case .fitness: ["報到", "會籍", "課表"]
        case .yellowgirl: ["外帶", "叫號", "號碼牌"]
        }
    }

    /// 鎖定畫面上的示範 PIN（README 的四位＋這家多的人）
    var pinHint: String {
        let base = "Leslie 1234・Cameron 2580・Jacob 1111・王小美 0000"
        switch self {
        case .cafe, .apparel: return base
        case .salon: return base + "・Mia 5678"
        case .fitness: return base + "・Kevin 5678・Ivy 2468"
        case .yellowgirl: return "阿珠 1234・小翔 2580・老闆娘 0000"
        }
    }

    /// 這家示範主要的營業模式（卡片上的「適合哪些店」）
    var mode: ServiceMode {
        switch self {
        case .cafe: .cafe
        case .apparel: .apparel
        case .salon: .salon
        case .fitness: .fitness
        case .yellowgirl: .counter
        }
    }

    /// 圖示（和營業模式同一套）
    var icon: String {
        switch self {
        case .cafe: "cake"
        case .apparel: "swatch"
        case .salon: "scissors"
        case .fitness: "bolt"
        case .yellowgirl: "ticket"
        }
    }

    var swatch: Swatch {
        switch self {
        case .cafe: .butter
        case .apparel: .sky
        case .salon: .rose
        case .fitness: .mint
        case .yellowgirl: .peach
        }
    }

    /// 啟動參數：沒有 `-demo` 是 nil；`-demo` 後面沒寫（或看不懂）是晨麥手作；`-demo salon` 開美業（也認 fashion、beauty、gym 這些說法）；
    /// `-demo yellowgirl` 開黃毛丫頭
    static func fromLaunchArguments() -> DemoKind? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo") else { return nil }
        guard i + 1 < args.count else { return .cafe }
        return DemoKind(argument: args[i + 1]) ?? .cafe
    }

    init?(argument: String) {
        switch argument.lowercased() {
        case "cafe", "café", "restaurant", "food": self = .cafe
        case "apparel", "fashion", "clothing", "retail": self = .apparel
        case "salon", "beauty", "hair": self = .salon
        case "fitness", "gym", "studio": self = .fitness
        case "yellowgirl", "yg", "stall", "nightmarket", "takeout", "黃毛丫頭": self = .yellowgirl
        default: return nil
        }
    }
}

/// 示範模式：不用配對、資料只在這次開著的時候。五家（DemoKind）：
///   - 餐廳咖啡「晨麥手作」（台南的咖啡、早午餐、甜點、麵包）：這個檔案
///   - 服飾「Lumi 選物」、美業「Mori Hair」、健身「Pulse 健身」：DemoApparel、DemoSalon、DemoFitness（虛構的店）
///   - 夜市滷味攤「黃毛丫頭」：DemoYellowgirl（菜單照店裡的價目表；銷售紀錄、人名是編的。人和 PIN 是自己的三位）
/// 前四家都有同樣的四個人、同樣的 PIN（README 寫的）：Leslie K.（店長，PIN 1234）、Cameron W.（收銀，PIN 2580）、
/// Jacob J.（領班，PIN 1111）、王小美（負責人，PIN 0000）；職稱照各行各業（總監、設計師、銷售、教練…）。
/// 美業、健身多幾位排進預約表的人（都是收銀權限）：Mia 陳（設計師，PIN 5678）；Kevin 吳（教練，PIN 5678）、Ivy 黃（教練，PIN 2468）。
/// 人名、電話、統編、地址都是編的。
struct DemoStore {
    /// 這次開哪一家：配對畫面選的（POSModel.startDemo(kind:) 先設好），沒選就看啟動參數
    static var kind: DemoKind = DemoKind.fromLaunchArguments() ?? .cafe

    let kind: DemoKind
    /// 這家示範打開的時間（預約、課表、今天的單都以這一刻為準）
    let createdAt: Date
    let bootstrap: Bootstrap
    let api: DemoAPI
    /// 開幕到昨天的「後台歷史」（DemoAPI.history 與昨天記進這台的單用同一份）
    let past: DemoHistory
    /// 黃毛丫頭的今天（記進這台的單與示範後台的叫號用同一份）
    let yellowgirl: YellowgirlToday?

    init() { self.init(kind: Self.kind) }

    init(kind: DemoKind) {
        let now = Date()
        self.kind = kind
        createdAt = now
        var reservations: [Reservation] = []
        var classes: [ClassSession] = []
        var today: YellowgirlToday? = nil
        let members: [Member]
        switch kind {
        case .cafe:
            bootstrap = Self.cafeBootstrap(now: now)
            reservations = Self.reservations(now: now)
            members = Self.cafeMembers(now: now)
        case .apparel:
            bootstrap = Self.apparelBootstrap(now: now)
            members = Self.apparelMembers(now: now)
        case .salon:
            bootstrap = Self.salonBootstrap(now: now)
            reservations = Self.salonReservations(now: now)
            members = Self.salonMembers(now: now)
        case .fitness:
            bootstrap = Self.fitnessBootstrap(now: now)
            classes = Self.fitnessClasses(now: now)
            reservations = Self.fitnessReservations(now: now, classes: classes)
            members = Self.fitnessMembers(now: now)
        case .yellowgirl:
            bootstrap = Self.yellowgirlBootstrap(now: now)
            members = []
            today = YellowgirlToday.make(now: now, catalog: bootstrap.catalog)
        }
        yellowgirl = today
        past = DemoHistory(base: bootstrap, regulars: DemoHistory.regulars(members, catalog: bootstrap.catalog))
        api = DemoAPI(bootstrap: bootstrap, reservations: reservations, members: members, classes: classes, history: past,
                      queue: today.map { DemoQueue(yellowgirl: $0, now: now) }, coupons: Self.coupons(kind: kind, now: now))
    }

    /// 昨天的單（照後台歷史）＋今天已經發生的事（開班、打卡、結帳的單、正在服務的、報到）
    func seed(into ledger: Ledger) throws {
        let cutoff = bootstrap.store.businessDayCutoffHour
        let yesterday = TaipeiTime.businessDate(createdAt.addingTimeInterval(-86_400), cutoffHour: cutoff)
        if let day = past.day(yesterday) {
            try DemoSeeder(ledger: ledger, bootstrap: bootstrap, now: createdAt).replay(day)
        }
        switch kind {
        case .cafe: try seedCafe(into: ledger)
        case .apparel: try seedApparel(into: ledger)
        case .salon: try seedSalon(into: ledger)
        case .fitness: try seedFitness(into: ledger)
        case .yellowgirl: try seedYellowgirl(into: ledger)
        }
    }

    /// 今天的訂位、候位、預約、課程報名（和 DemoAPI 手上的一樣）
    func reservations() -> [Reservation] {
        switch kind {
        case .cafe: Self.reservations(now: Date())
        case .apparel: []
        case .salon: Self.salonReservations(now: createdAt)
        case .fitness: Self.fitnessReservations(now: createdAt, classes: Self.fitnessClasses(now: createdAt))
        case .yellowgirl: []
        }
    }

    /// 今天的團體課（健身）
    func classes() -> [ClassSession] {
        kind == .fitness ? Self.fitnessClasses(now: createdAt) : []
    }

    /// 示範的門市折價券（DemoAPI.coupon；掃碼或在折扣面板打代碼）：
    ///   WELCOME100  新會員 100 元（滿 NT$300）      VIP10   VIP 9 折
    ///   EXPIRED     已經過期（9/30）                 ONLINE  只能在網路商店用
    ///   黃毛丫頭多一張 YG-A3B2C1（新會員 50 元）
    static func coupons(kind: DemoKind, now: Date) -> [String: DemoCoupon] {
        let month = now.addingTimeInterval(30 * 86_400)
        var list = [
            DemoCoupon(coupon: Coupon(code: "WELCOME100", name: "新會員 100 元", description: "加入會員送的，門市與網路商店都能用", type: .fixed, value: 10_000,
                                      minimumOrder: Money(dollars: 300), expiresAt: month, usesLeft: 1)),
            DemoCoupon(coupon: Coupon(code: "VIP10", name: "VIP 9 折", description: "金卡會員每次都能用", type: .percentage, value: 1000)),
            DemoCoupon(coupon: Coupon(code: "EXPIRED", name: "中秋節 50 元", type: .fixed, value: 5000, expiresAt: now.addingTimeInterval(-4 * 86_400)),
                       problem: "已經過期（9/30）"),
            DemoCoupon(coupon: Coupon(code: "ONLINE", name: "網路限定 8 折", type: .percentage, value: 2000), problem: "只能在網路商店用"),
        ]
        if kind == .yellowgirl {
            list.append(DemoCoupon(coupon: Coupon(code: "YG-A3B2C1", name: "新會員 50 元", description: "黃毛丫頭網站加入會員送的", type: .fixed, value: 5000,
                                                  expiresAt: month, usesLeft: 1)))
        }
        return Dictionary(list.map { ($0.coupon.code, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - 晨麥手作（餐廳咖啡）

    static func cafeBootstrap(now: Date) -> Bootstrap {
        let period = InvoicePeriod(date: now)
        let invoice = InvoiceSettings(
            enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", sellerAddress: "台南市中西區民族路二段1號",
            qrKey: "6E8B2A1C4D5F70819A2B3C4D5E6F7081",
            rolls: [
                // 示範的單往回 6 個多小時（還有昨天的單）：剛換期的時候會落在上一期，所以上一期也給一段
                InvoiceRoll(id: "demo-roll-0", period: period.previous.code, track: "XC", start: 2345600, end: 2345799),
                InvoiceRoll(id: "demo-roll-1", period: period.code, track: "XD", start: 12345600, end: 12345899),
                InvoiceRoll(id: "demo-roll-2", period: period.next.code, track: "XF", start: 22345600, end: 22345649),
            ]
        )
        return Bootstrap(
            version: "demo", serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "晨麥手作", legalName: "晨麥手作有限公司", taxId: "04595257", address: "台南市中西區民族路二段1號", phone: "06-222-0000",
                receiptFooter: "謝謝光臨・Wi-Fi：chenmai / 22200000", serviceChargeBps: 1000, serviceChargeOn: [.dineIn], tipsEnabled: false,
                defaultOrderType: .dineIn, tableTimeLimitMinutes: 90, businessDayCutoffHour: 4, discountLimitBps: 1000,
                serviceModes: [.tableService, .counter, .cafe], defaultServiceMode: .tableService
            ),
            // 餐飲：沒有預約表、儲值與課程卡、抽成（會員只查電話、累積消費）；有叫號（號碼牌）
            features: FeatureFlags(seating: true, kitchen: true, reservations: true, invoice: true, members: true, waitlistSMS: true,
                                   appointments: false, accounts: false, commission: false, queue: true),
            catalog: Self.catalog,
            floor: Self.floor,
            staff: Self.staff,
            invoice: invoice,
            mesh: MeshConfig(key: String(repeating: "5d", count: 32), enabled: false),
            // 號碼存在示範的「後台」（DemoQueue）；號碼牌用 iPad 的預設版面（沒有背景圖）
            queue: QueueConfig(mode: DemoQueue.mode, customerUrl: "https://chenmai.example.tw/q?no={number}&waiting={waiting}", ticket: QueueTicketLayout()),
            // 單據樣式：麥穗店標＋店家自己的字（圖在 iPad 上畫：DemoPrintArt）
            printStyle: DemoPrintArt.cafeStyle
        )
    }

    static func cafeMembers(now: Date) -> [Member] {
        [
            Member(id: "demo-m1", phone: "0912345678", name: "林小涵", tierName: "金卡會員", lifetimeSpend: Money(dollars: 18_640), visits: 23,
                   lastVisitAt: now.addingTimeInterval(-6 * 86_400), note: "不吃香菜",
                   recentVisits: [
                       visit("m1-a", "A027", daysAgo: 6, now: now, total: 642, items: ["拿鐵 ×2", "酥皮鬆餅"], staff: ["Cameron W."]),
                       visit("m1-b", "A013", daysAgo: 19, now: now, total: 1_210, items: ["炙燒鮭魚貝果 ×2", "卡布奇諾 ×2", "巴斯克乳酪蛋糕"],
                             staff: ["Jacob J."], note: "四位，靠窗"),
                       visit("m1-c", "A031", daysAgo: 33, now: now, total: 286, items: ["小白咖啡", "檸檬塔"], staff: ["Cameron W."]),
                   ],
                   birthday: birthdayThisMonth(12, now: now)),
            Member(id: "demo-m2", phone: "0922111333", name: "陳柏宇", tierName: "一般會員", lifetimeSpend: Money(dollars: 2_380), visits: 4,
                   lastVisitAt: now.addingTimeInterval(-20 * 86_400), note: nil,
                   recentVisits: [visit("m2-a", "A008", daysAgo: 20, now: now, total: 495, items: ["歐姆蛋盤", "美式咖啡"], staff: ["Leslie K."])]),
        ]
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
    func seedCafe(into ledger: Ledger) throws {
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

/// 示範的「後台」：收什麼都說好；會員、訂位與預約、課表放在記憶體（這次開著的時候）
actor DemoAPI: POSAPI {
    let base: Bootstrap
    private var reservations: [String: Reservation] = [:]
    private var rollCounter = 0
    /// 會員（用手機號碼查）
    private var members: [String: Member] = [:]
    /// 今天的團體課；別天照同一張課表排
    private let timetable: [ClassSession]
    /// 課表的「今天」（營業日）
    private let today: String
    /// 每一堂後來在 iPad 上多報名（＋）、取消（−）的人數
    private var bookingDelta: [String: Int] = [:]
    /// 開幕到昨天的歷史（要哪天才產生，產生過的記著）
    private let past: DemoHistory?
    private var pastDays: [String: DayHistory] = [:]
    /// 叫號（後台開了才有）：號碼存在這裡，每 20 秒左右有人自己取號
    private var line: DemoQueue?
    /// 門市折價券（代碼 → 券）
    private let coupons: [String: DemoCoupon]
    /// 主管授權打錯 PIN 的時間（和後台一樣：10 分鐘錯 5 次鎖 10 分鐘）
    private var pinFailures: [Date] = []
    private var pinLockedUntil: Date?

    /// queue：這家示範的叫號一打開的樣子（黃毛丫頭的號碼對著今天的單）；沒給是晨麥手作那一套
    init(bootstrap: Bootstrap, reservations: [Reservation], members: [Member] = [], classes: [ClassSession] = [], history: DemoHistory? = nil,
         queue: DemoQueue? = nil, coupons: [String: DemoCoupon] = [:]) {
        base = bootstrap
        self.reservations = Dictionary(reservations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.members = Dictionary(members.map { ($0.phone, $0) }, uniquingKeysWith: { first, _ in first })
        timetable = classes
        today = TaipeiTime.businessDate(bootstrap.serverTime, cutoffHour: bootstrap.store.businessDayCutoffHour)
        past = history
        line = bootstrap.features.queue ? (queue ?? DemoQueue(now: bootstrap.serverTime)) : nil
        self.coupons = coupons
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

    // MARK: 會員

    /// 示範的後台記的是開店時的餘額（accountEventIds 是空的）：今天在這台記的儲值、扣卡、報到由 iPad 自己補上
    func member(phone: String) async throws -> Member? { members[phone.filter(\.isNumber)] }

    func createMember(_ m: MemberCreate) async throws -> Member {
        if let existing = members[m.phone] { return existing }
        let accounts = base.features.accounts
        let new = Member(id: "demo-m-\(m.phone)", phone: m.phone, name: m.name, tierName: "一般會員", lifetimeSpend: .zero, visits: 0, lastVisitAt: nil, note: nil,
                         wallet: accounts ? .zero : nil, passes: accounts ? [] : nil, accountEventIds: [], recentVisits: [])
        members[m.phone] = new
        return new
    }

    func updateMember(id: String, _ update: MemberUpdate) async throws -> Member {
        guard var m = members.values.first(where: { $0.id == id }) else {
            throw APIError.http(status: 404, code: "not_found", message: "找不到這位會員")
        }
        if let v = update.name { m.name = v.isEmpty ? nil : v }
        if let v = update.note { m.note = v.isEmpty ? nil : v }
        if let v = update.birthday { m.birthday = v.isEmpty ? nil : v }
        members[m.phone] = m
        return m
    }

    // MARK: 訂位、預約、課程報名

    func reservations(date: String) async throws -> [Reservation] {
        let cutoff = base.store.businessDayCutoffHour
        return reservations.values
            .filter { TaipeiTime.businessDate($0.startsAt, cutoffHour: cutoff) == date }
            .sorted { $0.startsAt < $1.startsAt }
    }

    func createReservation(_ input: ReservationInput) async throws -> Reservation {
        let kind = input.kind ?? .reservation
        if kind == .classBooking, let sid = input.sessionId, let s = timetable.first(where: { $0.id == sid }),
           s.capacity > 0, s.booked + (bookingDelta[sid] ?? 0) >= s.capacity {
            throw APIError.http(status: 409, code: "class_full", message: "\(s.name) 額滿了")
        }
        let queue = kind == .waitlist ? (reservations.values.compactMap(\.queueNumber).max() ?? 13) + 1 : nil
        let serviceMinutes = (input.services ?? []).reduce(0) { $0 + $1.durationMinutes }
        let single = kind == .appointment || kind == .classBooking
        let r = Reservation(id: UUID().uuidString.lowercased(), kind: kind, name: input.name ?? "", phone: input.phone ?? "",
                            partySize: input.partySize ?? (single ? 1 : 2), startsAt: input.startsAt ?? Date(),
                            durationMinutes: input.durationMinutes ?? (serviceMinutes > 0 ? serviceMinutes : 90),
                            tableIds: input.tableIds ?? [], status: input.status ?? .booked, note: input.note ?? "", source: "pos",
                            queueNumber: queue, createdAt: Date(), staffId: input.staffId, services: input.services, memberId: input.memberId,
                            sessionId: input.sessionId, ticketId: input.ticketId)
        if r.kind == .classBooking, let sid = r.sessionId, r.status != .cancelled { bookingDelta[sid, default: 0] += 1 }
        reservations[r.id] = r
        return r
    }

    func updateReservation(id: String, _ input: ReservationInput) async throws -> Reservation {
        var r = reservations[id] ?? Reservation(id: id, kind: input.kind ?? .reservation, name: input.name ?? "", phone: input.phone ?? "",
                                                 partySize: input.partySize ?? 2, startsAt: input.startsAt ?? Date(), createdAt: Date())
        let heldSeat = r.status != .cancelled
        if let v = input.kind { r.kind = v }
        if let v = input.name { r.name = v }
        if let v = input.phone { r.phone = v }
        if let v = input.partySize { r.partySize = v }
        if let v = input.startsAt { r.startsAt = v }
        if let v = input.durationMinutes { r.durationMinutes = v }
        if let v = input.tableIds { r.tableIds = v }
        if let v = input.status { r.status = v }
        if let v = input.note { r.note = v }
        if let v = input.staffId { r.staffId = v.isEmpty ? nil : v }
        if let v = input.services { r.services = v }
        if let v = input.memberId { r.memberId = v.isEmpty ? nil : v }
        if let v = input.sessionId { r.sessionId = v.isEmpty ? nil : v }
        if let v = input.ticketId { r.ticketId = v.isEmpty ? nil : v }
        // 課程報名：取消就空出一個名額（報到、未到都還算報名過）
        if r.kind == .classBooking, let sid = r.sessionId, heldSeat != (r.status != .cancelled) {
            bookingDelta[sid, default: 0] += heldSeat ? -1 : 1
        }
        reservations[id] = r
        return r
    }

    func notifyReservation(id: String) async throws {}

    func saveFloor(_ update: FloorUpdate) async throws -> FloorResponse { FloorResponse(floor: FloorPlan(areas: update.areas), version: "demo") }

    // MARK: 歷史

    /// 某個營業日的結帳、退款、作廢、報到（開幕前、今天以後是空的；同一天每次都一樣）
    func history(date: String) async throws -> DayHistory {
        if let cached = pastDays[date] { return cached }
        let day = past?.history(date) ?? DayHistory(businessDate: date)
        pastDays[date] = day
        return day
    }

    // MARK: 叫號

    func queue() async throws -> QueueState {
        guard var q = line else { throw APIError.http(status: 409, code: "queue_off", message: "後台沒有開叫號") }
        let now = Date()
        q.tick(now: now)
        line = q
        return q.state(now: now)
    }

    func queue(_ action: QueueAction) async throws -> QueueState {
        guard var q = line else { throw APIError.http(status: 409, code: "queue_off", message: "後台沒有開叫號") }
        let now = Date()
        q.tick(now: now)
        var numbers: [Int]?
        switch action {
        case .take(let count, let requestId):
            numbers = q.take(count: count, requestId: requestId, at: now)
        case .next:
            q.next(at: now)
        case .miss:
            q.miss(at: now)
        case .previous:
            guard q.current != nil else { throw APIError.http(status: 400, code: "nothing_called", message: "現在沒有在叫號") }
            q.previous()
        case .recall(let n):
            guard q.missed.contains(n) else { throw APIError.http(status: 404, code: "not_found", message: "\(n) 號不在過號清單裡") }
            q.recall(n, at: now)
        case .unmiss(let n):
            q.unmiss(n)
        case .mark(let n):
            if !q.marked.contains(n) { q.marked.append(n) }
        case .unmark(let n):
            q.marked.removeAll { $0 == n }
        case .reset:
            q.reset(at: now)
        case .takeOne(let entry, let requestId):
            numbers = q.take(count: 1, requestId: requestId, entry: entry, at: now)
        case .call(let n, _):
            // 叫指定的號碼（外帶：先做好的先叫）；已經是現在叫的就不動
            guard q.current != n else { break }
            guard q.waiting.contains(n) else { throw APIError.http(status: 404, code: "not_found", message: "\(n) 號不在等候中") }
            q.call(n, at: now)
        case .cancel(let n, _):
            // 作廢的單放回號碼（已經不在了也算成功：重送不會出錯）
            q.cancel(n)
        }
        line = q
        var s = q.state(now: now)
        s.numbers = numbers
        return s
    }

    // MARK: 折價券

    /// 和後台一樣：不能用的給原因（過期、只能網路用、未達最低消費）；沒有這張＝nil（404）
    func coupon(code: String, subtotal: Money, memberId: String?) async throws -> CouponLookup? {
        guard let c = coupons[code.uppercased()] else { return nil }
        if let problem = c.problem { return CouponLookup(coupon: c.coupon, problem: problem) }
        if let minimum = c.coupon.minimumOrder, minimum.cents > 0, subtotal < minimum {
            return CouponLookup(coupon: c.coupon, problem: "未達最低消費 \(minimum.formatted)")
        }
        return CouponLookup(coupon: c.coupon)
    }

    // MARK: 主管授權

    /// 和後台的 POST /staff/verify-pin 一樣（-personal 的示範手機用；示範的人員在這台有 PIN 雜湊，這裡照樣在本機比對）：
    /// 只看啟用中的人，沒給 staffId 時兩個人一樣取職能最高的；錯了 401 wrong_pin；10 分鐘錯 5 次鎖 10 分鐘（對了不歸零）
    func verifyPin(staffId: String?, pin: String, purpose: String) async throws -> VerifiedStaff {
        let now = Date()
        if let until = pinLockedUntil, until > now {
            throw APIError.http(status: 429, code: "rate_limited", message: APIError.pinRateLimitedMessage)
        }
        let pool = base.staff.filter { $0.isActive && (staffId == nil || $0.id == staffId) }
        // max(by:) 職能一樣時留名單上前面的那位（後台的名單照名字排，也是取前面的）
        guard let m = pool.filter({ $0.verify(pin: pin) }).max(by: { $0.role < $1.role }) else {
            pinFailures = pinFailures.filter { now.timeIntervalSince($0) < 600 } + [now]
            if pinFailures.count >= 5 {
                pinFailures = []
                pinLockedUntil = now.addingTimeInterval(600)
            }
            throw APIError.http(status: 401, code: APIError.wrongPinCode, message: APIError.wrongPinMessage)
        }
        return VerifiedStaff(id: m.id, name: m.name, role: m.role.rawValue)
    }

    // MARK: 課表

    /// 今天的課表；別天照同一張表（以前的照原本的人數，之後的越後面報名的人越少）
    func classes(date: String) async throws -> [ClassSession] {
        guard !timetable.isEmpty, let days = dayOffset(to: date) else { return [] }
        return timetable.map { template in
            var s = template
            if days != 0 {
                s.id = "\(template.id)@\(date)"
                s.startsAt = template.startsAt.addingTimeInterval(TimeInterval(days * 86_400))
                s.booked = days < 0 ? template.booked : max(template.booked - days * 3, 0)
            }
            s.booked = max(s.booked + (bookingDelta[s.id] ?? 0), 0)
            return s
        }
    }

    /// 從課表的「今天」到 date 差幾天（yyyy-MM-dd；看不懂是 nil）
    private func dayOffset(to date: String) -> Int? {
        guard let from = day(today), let to = day(date) else { return nil }
        return TaipeiTime.calendar.dateComponents([.day], from: from, to: to).day
    }

    private func day(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TaipeiTime.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// 示範店的叫號：和原本的叫號伺服器一樣的規則（取號加到最後、下一號、過號自動叫下一號、
/// 返回前一號放回最前面、號碼到 1000 從 1 開始），另外記取號、叫號的時間與號碼的附帶資料（幾位、哪一張單），
/// 所以畫面上看得到等了幾分、今天服務幾位；也可以叫指定的號碼（外帶：先做好的先叫）。
/// - 晨麥手作一打開：今天服務了 22 位，現在叫到 23，24–31 在等（26 標了星號），19、21 過號；之後每 20 秒左右有人取號（最多排 14 位）
/// - 黃毛丫頭：號碼對著今天結帳的外帶單（YellowgirlToday）；號碼只在收銀台結帳時取（不會自己多出來）
nonisolated struct DemoQueue: Sendable {
    /// 示範用後台自己的號碼（看得到等候時間、今天的數字、過號可以再叫一次）；改成 .legacy 就是原本叫號伺服器的樣子
    static let mode: QueueMode = .native

    var current: Int?
    var waiting: [Int]
    var missed: [Int]
    var marked: [Int]
    var nextNo: Int
    var calledAt: Date?
    var takenAt: [Int: Date]
    var served: Int
    /// 上一次有人自己取號
    var lastAuto: Date
    /// 取號的 requestId（重送不再取）
    var requests: [String: [Int]] = [:]
    var rng = SeededRandom(seed: 2310)
    /// 號碼的附帶資料（幾位、哪一張單）
    var entries: [Int: QueueEntry] = [:]
    /// 店裡有客人自己取號（晨麥手作的號碼機）；黃毛丫頭的號碼只在結帳時取
    var autoTake = true

    init(now: Date) {
        current = 23
        calledAt = now.addingTimeInterval(-70)
        waiting = Array(24...31)
        missed = [19, 21]
        marked = [26]
        nextNo = 32
        served = 22
        lastAuto = now
        let minutesAgo = [17, 15, 12, 10, 8, 5, 3, 1]
        var taken: [Int: Date] = [:]
        for (n, m) in zip(waiting, minutesAgo) { taken[n] = now.addingTimeInterval(TimeInterval(-m * 60 - 20)) }
        takenAt = taken
        // 排隊等內用的人數（晨麥手作的後台沒開 dineIn 時畫面不會用到）
        let guests = [2, 4, 2, 3, 1, 2, 5, 2]
        for (n, g) in zip(waiting, guests) { entries[n] = QueueEntry(guests: g) }
    }

    /// 黃毛丫頭：今天結帳的外帶單照順序取的號碼（現在叫的、等候中、過號都對著那張單）
    init(yellowgirl plan: YellowgirlToday, now: Date) {
        current = plan.current
        calledAt = plan.calledAt
        waiting = plan.waiting
        missed = plan.missed
        marked = []
        nextNo = plan.nextNo
        served = plan.served
        lastAuto = now
        autoTake = false
        var taken: [Int: Date] = [:]
        var info: [Int: QueueEntry] = [:]
        for o in plan.orders {
            taken[o.queue] = o.closedAt
            info[o.queue] = QueueEntry(ticketId: o.id, label: o.label)
        }
        takenAt = taken
        entries = info
    }

    /// 店裡有客人：每 16–24 秒有人取一張（排太長就先不取）
    mutating func tick(now: Date) {
        guard autoTake else { return }
        while now.timeIntervalSince(lastAuto) >= 20 {
            lastAuto = lastAuto.addingTimeInterval(TimeInterval(16 + rng.next(9)))
            if waiting.count < 14 { append(1, at: lastAuto) }
        }
    }

    /// 取號；只取一張時可以帶附帶資料（幾位、哪一張單）
    mutating func take(count: Int, requestId: String, entry: QueueEntry? = nil, at now: Date) -> [Int] {
        if let done = requests[requestId] { return done }
        let numbers = append(min(max(count, 1), 20), at: now)
        requests[requestId] = numbers
        if let entry, numbers.count == 1, let n = numbers.first { entries[n] = entry }
        return numbers
    }

    /// 叫指定的號碼：等候中的那一號變成現在叫的（原本的算服務完了）
    mutating func call(_ n: Int, at now: Date) {
        guard waiting.contains(n) else { return }
        finishCurrent()
        waiting.removeAll { $0 == n }
        current = n
        calledAt = now
    }

    @discardableResult
    private mutating func append(_ count: Int, at now: Date) -> [Int] {
        var out: [Int] = []
        for _ in 0..<count {
            out.append(nextNo)
            waiting.append(nextNo)
            takenAt[nextNo] = now
            nextNo = nextNo >= 999 ? 1 : nextNo + 1
        }
        return out
    }

    /// 下一號：原本叫的算服務完了（取消標記）；沒有人在等就清掉
    mutating func next(at now: Date) {
        finishCurrent()
        callFirst(at: now)
    }

    /// 過號：現在叫的移到過號，自動叫下一號
    mutating func miss(at now: Date) {
        guard let c = current else { return }
        missed.append(c)
        current = nil
        calledAt = nil
        callFirst(at: now)
    }

    /// 返回前一號：現在叫的放回等候的最前面
    mutating func previous() {
        guard let c = current else { return }
        waiting.insert(c, at: 0)
        missed.removeAll { $0 == c }
        takenAt[c] = takenAt[c] ?? Date()
        current = nil
        calledAt = nil
    }

    /// 再叫一次過號的
    mutating func recall(_ n: Int, at now: Date) {
        finishCurrent()
        missed.removeAll { $0 == n }
        current = n
        calledAt = now
    }

    mutating func unmiss(_ n: Int) {
        missed.removeAll { $0 == n }
        marked.removeAll { $0 == n }
    }

    /// 放回號碼（單子作廢）：哪裡都拿掉；正在叫的就停（不算服務完）
    mutating func cancel(_ n: Int) {
        waiting.removeAll { $0 == n }
        missed.removeAll { $0 == n }
        marked.removeAll { $0 == n }
        if current == n {
            current = nil
            calledAt = nil
        }
        takenAt[n] = nil
        entries[n] = nil
    }

    mutating func reset(at now: Date) {
        current = nil
        calledAt = nil
        waiting = []
        missed = []
        marked = []
        takenAt = [:]
        entries = [:]
        nextNo = 1
        served = 0
        lastAuto = now
    }

    private mutating func finishCurrent() {
        guard let c = current else { return }
        served += 1
        marked.removeAll { $0 == c }
    }

    private mutating func callFirst(at now: Date) {
        if waiting.isEmpty {
            current = nil
            calledAt = nil
        } else {
            let n = waiting.removeFirst()
            current = n
            calledAt = now
        }
    }

    func state(now: Date) -> QueueState {
        let native = Self.mode == .native
        var taken: [String: Date] = [:]
        if native { for n in waiting { if let at = takenAt[n] { taken[String(n)] = at } } }
        // 附帶資料：現在叫的、等候中、過號的（原本的叫號伺服器沒有）
        var info: [String: QueueEntry] = [:]
        if native {
            for n in waiting + missed + (current.map { [$0] } ?? []) {
                if let e = entries[n] { info[String(n)] = e }
            }
        }
        return QueueState(mode: Self.mode, current: current, waiting: waiting, missed: missed, marked: marked, nextNo: nextNo,
                          calledAt: native ? calledAt : nil, updatedAt: now, takenAt: taken, servedToday: native ? served : nil,
                          entries: info)
    }
}

/// 示範資料用的亂數（同一個種子每次都一樣；後台歷史在 DemoAPI 裡產生，所以不綁主執行緒）
nonisolated struct SeededRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ upper: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(max(upper, 1)))
    }

    /// 0–99 小於 percent 的機率
    mutating func chance(_ percent: Int) -> Bool { next(100) < percent }

    mutating func pick<T>(_ list: [T]) -> T? {
        list.isEmpty ? nil : list[next(list.count)]
    }

    /// 照權重挑一個
    mutating func weighted<T>(_ list: [(T, Int)]) -> T? {
        let total = list.reduce(0) { $0 + max($1.1, 0) }
        guard total > 0 else { return list.first?.0 }
        var r = next(total)
        for (value, weight) in list {
            let w = max(weight, 0)
            if r < w { return value }
            r -= w
        }
        return list.last?.0
    }
}

/// 示範後台的一張折價券（不能用的帶原因）
nonisolated struct DemoCoupon: Sendable {
    var coupon: Coupon
    var problem: String? = nil
}
