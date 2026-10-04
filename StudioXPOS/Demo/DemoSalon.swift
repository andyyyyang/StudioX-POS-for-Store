import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範：美髮沙龍「Mori Hair」（虛構）。三位設計師的預約表（做完的、服務中的、已到店在等的、等一下要來的、取消的），
/// 服務照設計師算業績與抽成、助理幫忙洗染；會員有儲值金（儲 10,000 送 1,000）、剪髮次數卡、護髮次數卡、染髮配方的備註。
extension DemoStore {
    static func salonBootstrap(now: Date) -> Bootstrap {
        let address = "台中市西區美村路一段 116 號"
        return Bootstrap(
            version: "demo-salon", serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "Mori Hair", legalName: "森里髮藝有限公司", taxId: "83270270", address: address, phone: "04-2301-0000",
                receiptFooter: "預約、改期請傳 LINE：@morihair", serviceChargeBps: 0, serviceChargeOn: [], tipsEnabled: false,
                defaultOrderType: .takeout, tableTimeLimitMinutes: 0, businessDayCutoffHour: 4, discountLimitBps: 1000,
                discountPresetsBps: [500, 1000, 1500, 2000], serviceModes: [.salon, .retail], defaultServiceMode: .salon,
                prepaidInvoicing: .atTopUp, exchangeDays: 7, bookingSlotMinutes: 15
            ),
            features: FeatureFlags(seating: false, kitchen: false, reservations: false, invoice: true, members: true, waitlistSMS: false,
                                   appointments: true, accounts: true, commission: true),
            catalog: salonCatalog,
            floor: .empty,
            staff: salonStaff,
            invoice: demoInvoice(taxId: "83270270", name: "森里髮藝有限公司", address: address, now: now, tracks: ("YD", "YE", "YF")),
            mesh: MeshConfig(key: String(repeating: "7a", count: 32), enabled: false)
        )
    }

    // MARK: 服務、商品、次數卡、儲值

    static let salonCatalog: Catalog = {
        let length = ModifierGroup(id: "g-length", name: "髮長", minSelect: 1, maxSelect: 1, options: [
            ModifierOption(id: "len-short", name: "短髮", isDefault: true),
            ModifierOption(id: "len-mid", name: "中長髮", priceDelta: Money(dollars: 300)),
            ModifierOption(id: "len-long", name: "長髮", priceDelta: Money(dollars: 600)),
        ], sortOrder: 1)
        let categories = [
            MenuCategory(id: "c-hair", name: "剪髮・造型", swatch: .peach, sortOrder: 1),
            MenuCategory(id: "c-chem", name: "染燙", swatch: .lavender, sortOrder: 2),
            MenuCategory(id: "c-care", name: "護髮", swatch: .mint, sortOrder: 3),
            MenuCategory(id: "c-retail", name: "居家保養", swatch: .sand, sortOrder: 4),
            MenuCategory(id: "c-pass", name: "次數卡", swatch: .sky, sortOrder: 5),
            MenuCategory(id: "c-topup", name: "儲值", swatch: .butter, sortOrder: 6),
        ]
        /// 服務：時間長度、設計師抽三成
        func service(_ id: String, _ cat: String, _ name: String, _ price: Int, minutes: Int, plu: String, groups: [String] = []) -> MenuItem {
            MenuItem(id: id, categoryId: cat, name: name, price: Money(dollars: price), plu: plu, modifierGroupIds: groups, unit: "次",
                     sortOrder: Int(plu) ?? 0, kind: .service, durationMinutes: minutes, commissionBps: 3000)
        }
        func goods(_ id: String, _ name: String, _ price: Int, plu: String, barcode: String, stock: Int) -> MenuItem {
            MenuItem(id: id, categoryId: "c-retail", name: name, price: Money(dollars: price), barcode: DemoStore.ean13(barcode), plu: plu,
                     unit: "瓶", sortOrder: Int(plu) ?? 0, stock: stock)
        }
        let items: [MenuItem] = [
            service("svc-cut", "c-hair", "剪髮", 600, minutes: 60, plu: "101"),
            service("svc-washcut", "c-hair", "洗剪", 800, minutes: 75, plu: "102"),
            service("svc-wash", "c-hair", "洗髮造型", 400, minutes: 30, plu: "103"),
            service("svc-color", "c-chem", "染髮", 2_500, minutes: 120, plu: "201", groups: ["g-length"]),
            service("svc-perm", "c-chem", "燙髮", 3_200, minutes: 150, plu: "202", groups: ["g-length"]),
            service("svc-treat", "c-care", "護髮", 1_200, minutes: 45, plu: "301"),
            service("svc-scalp", "c-care", "頭皮淨化", 1_500, minutes: 60, plu: "302"),
            goods("retail-shampoo", "胺基酸洗髮精 500ml", 480, plu: "401", barcode: "471077100401", stock: 18),
            goods("retail-oil", "摩洛哥護髮油 100ml", 880, plu: "402", barcode: "471077100402", stock: 9),
            goods("retail-mask", "深層修護髮膜", 650, plu: "403", barcode: "471077100403", stock: 2),
            goods("retail-spray", "輕盈定型噴霧", 420, plu: "404", barcode: "471077100404", stock: 14),
            MenuItem(id: "pass-cut10", categoryId: "c-pass", name: "剪髮 10 次卡", price: Money(dollars: 5_000), plu: "501", unit: "張", sortOrder: 501,
                     kind: .pass, pass: PassSpec(kind: .visits, visits: 10, validDays: 365, itemIds: ["svc-cut", "svc-washcut"])),
            MenuItem(id: "pass-treat5", categoryId: "c-pass", name: "護髮 5 次卡", price: Money(dollars: 5_000), plu: "502", unit: "張", sortOrder: 502,
                     kind: .pass, pass: PassSpec(kind: .visits, visits: 5, validDays: 180, itemIds: ["svc-treat"])),
            MenuItem(id: "topup-10000", categoryId: "c-topup", name: "儲值 10,000 送 1,000", price: Money(dollars: 10_000), plu: "601", unit: "筆",
                     sortOrder: 601, kind: .storedValue, credit: Money(dollars: 11_000)),
            MenuItem(id: "topup-5000", categoryId: "c-topup", name: "儲值 5,000 送 300", price: Money(dollars: 5_000), plu: "602", unit: "筆",
                     sortOrder: 602, kind: .storedValue, credit: Money(dollars: 5_300)),
            MenuItem(id: "topup-custom", categoryId: "c-topup", name: "自訂儲值", price: .zero, openPrice: true, plu: "603", unit: "筆",
                     sortOrder: 603, kind: .storedValue),
        ]
        return Catalog(categories: categories, items: items, modifierGroups: [length])
    }()

    // MARK: 人員

    static let salonStaff: [StaffMember] = [
        person("s-leslie", "Leslie K.", .manager, "1234", .lavender, title: "總監", bookable: true, commissionBps: 1000),
        person("s-cameron", "Cameron W.", .cashier, "2580", .mint, title: "助理", commissionBps: 500),
        person("s-jacob", "Jacob J.", .supervisor, "1111", .rose, title: "設計師", bookable: true, commissionBps: 1000),
        person("s-owner", "王小美", .owner, "0000", .peach, title: "負責人"),
        person("s-mia", "Mia 陳", .cashier, "5678", .sky, title: "設計師", bookable: true, commissionBps: 1000),
    ]

    // MARK: 會員（後台的：開店時的儲值金、次數卡；今天在這台的儲值、扣卡由 iPad 補上）

    static func salonMembers(now: Date) -> [Member] {
        let cat = salonCatalog
        let cut10 = cat.item("pass-cut10"), treat5 = cat.item("pass-treat5")
        return [
            Member(id: "demo-sm1", phone: "0911222333", name: "陳怡君", tierName: "金卡會員", lifetimeSpend: Money(dollars: 48_600), visits: 31,
                   lastVisitAt: daysAgo(35, now),
                   note: "上次 6N+7.1 1:1（雙氧 6%）停 30 分鐘。頭皮敏感，避開含酒精的產品。瀏海喜歡短一點、不要打太薄。",
                   wallet: Money(dollars: 8_200),
                   passes: [heldPass("demo-sp-sm1-cut10", cut10, boughtDaysAgo: 160, remaining: 7, now: now)].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [
                       visit("sm1-a", "A014", daysAgo: 35, now: now, total: 2_800, items: ["洗剪（剪髮 10 次卡）", "染髮 6N+7.1・中長髮"], staff: ["Jacob J."],
                             note: "6N+7.1 1:1 停 30 分"),
                       visit("sm1-b", "A009", daysAgo: 71, now: now, total: 1_200, items: ["洗剪（剪髮 10 次卡）", "護髮"], staff: ["Jacob J.", "Cameron W."]),
                       visit("sm1-c", "A021", daysAgo: 118, now: now, total: 4_080, items: ["燙髮・中長髮", "摩洛哥護髮油 100ml"], staff: ["Leslie K."]),
                       visit("sm1-d", "A006", daysAgo: 160, now: now, total: 15_000, items: ["儲值 10,000 送 1,000", "剪髮 10 次卡"], staff: ["Jacob J."]),
                   ],
                   birthday: birthdayThisMonth(18, now: now)),
            Member(id: "demo-sm2", phone: "0922333444", name: "黃柏翰", tierName: "一般會員", lifetimeSpend: Money(dollars: 9_600), visits: 14,
                   lastVisitAt: daysAgo(28, now), note: "只剪不洗；兩側推 6mm、上面留 4 公分。不喜歡抓太多髮蠟。",
                   wallet: Money(dollars: 1_200), passes: [], accountEventIds: [],
                   recentVisits: [
                       visit("sm2-a", "A011", daysAgo: 28, now: now, total: 600, items: ["剪髮"], staff: ["Mia 陳"]),
                       visit("sm2-b", "A017", daysAgo: 57, now: now, total: 600, items: ["剪髮"], staff: ["Mia 陳"]),
                   ],
                   birthday: "11-03"),
            Member(id: "demo-sm3", phone: "0933444555", name: "林佳穎", tierName: "白金會員", lifetimeSpend: Money(dollars: 86_300), visits: 42,
                   lastVisitAt: daysAgo(21, now), note: "燙髮：沙宣捲 2 號棒、軟化 12 分鐘。對香味敏感，護髮用無香的。習慣喝溫水。",
                   wallet: Money(dollars: 4_600),
                   passes: [
                       heldPass("demo-sp-sm3-treat5", treat5, boughtDaysAgo: 168, remaining: 2, now: now),
                       heldPass("demo-sp-sm3-cut10-old", cut10, boughtDaysAgo: 400, remaining: 1, now: now),
                   ].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [
                       visit("sm3-a", "A004", daysAgo: 21, now: now, total: 1_200, items: ["頭皮淨化", "護髮（護髮 5 次卡）"], staff: ["Leslie K."]),
                       visit("sm3-b", "A019", daysAgo: 64, now: now, total: 3_800, items: ["燙髮・長髮"], staff: ["Leslie K.", "Cameron W."],
                             note: "沙宣捲 2 號棒"),
                   ],
                   birthday: "07-21"),
            Member(id: "demo-sm4", phone: "0955666777", name: "張雅婷", tierName: "一般會員", lifetimeSpend: Money(dollars: 12_400), visits: 16,
                   lastVisitAt: daysAgo(47, now), note: nil, wallet: .zero,
                   passes: [heldPass("demo-sp-sm4-cut10", cut10, boughtDaysAgo: 300, remaining: 0, now: now)].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [visit("sm4-a", "A022", daysAgo: 47, now: now, total: 0, items: ["剪髮（剪髮 10 次卡）"], staff: ["Mia 陳"])]),
            Member(id: "demo-sm5", phone: "0966777888", name: "王冠宇", tierName: "新客", lifetimeSpend: Money(dollars: 600), visits: 1,
                   lastVisitAt: daysAgo(40, now), note: "朋友介紹（陳怡君）。頭頂有髮旋，不要剪太短。", wallet: .zero, passes: [], accountEventIds: [],
                   recentVisits: [visit("sm5-a", "A015", daysAgo: 40, now: now, total: 600, items: ["剪髮"], staff: ["Jacob J."])]),
            Member(id: "demo-sm6", phone: "0975123456", name: "蔡宜蓁", tierName: "一般會員", lifetimeSpend: Money(dollars: 4_200), visits: 6,
                   lastVisitAt: daysAgo(33, now), note: "髮量多，打薄時不要剪太短。", wallet: .zero, passes: [], accountEventIds: [],
                   recentVisits: [visit("sm6-a", "A010", daysAgo: 33, now: now, total: 800, items: ["洗剪"], staff: ["Mia 陳"])],
                   birthday: birthdayThisMonth(3, now: now)),
        ]
    }

    // MARK: 今天的預約（三位設計師；以「現在」為準，15 分鐘一格）

    static func salonReservations(now: Date) -> [Reservation] {
        let t0 = slot(now, minutes: 15)
        let cat = salonCatalog
        func r(_ id: String, _ name: String, _ phone: String, staff: String, _ services: [String], at minutes: Int, status: ReservationStatus = .booked,
               member: String? = nil, ticket: String? = nil, note: String = "", source: String = "web") -> Reservation {
            let booked: [BookedService] = services.compactMap { sid in
                cat.item(sid).map { BookedService(itemId: $0.id, name: $0.name, durationMinutes: $0.durationMinutes ?? 60, staffId: staff, price: $0.price) }
            }
            let minutesTotal = booked.reduce(0) { $0 + $1.durationMinutes }
            return Reservation(id: id, kind: .appointment, name: name, phone: phone, partySize: 1, startsAt: t0.addingTimeInterval(Double(minutes * 60)),
                               durationMinutes: max(minutesTotal, 30), status: status, note: note, source: source,
                               createdAt: now.addingTimeInterval(-3 * 86_400), staffId: staff, services: booked, memberId: member, ticketId: ticket)
        }
        return [
            r("demo-appt-11", "蔡宜蓁", "0975123456", staff: "s-mia", ["svc-cut"], at: -270, status: .seated, member: "demo-sm6", ticket: "demo-salon-sale-5"),
            r("demo-appt-1", "陳怡君", "0911222333", staff: "s-jacob", ["svc-washcut", "svc-color"], at: -210, status: .seated, member: "demo-sm1",
              ticket: "demo-salon-sale-1", note: "染髮：照上次 6N+7.1"),
            r("demo-appt-2", "黃柏翰", "0922333444", staff: "s-mia", ["svc-cut"], at: -150, status: .seated, member: "demo-sm2",
              ticket: "demo-salon-sale-2", source: "phone"),
            r("demo-appt-3", "林佳穎", "0933444555", staff: "s-leslie", ["svc-perm", "svc-treat"], at: -60, status: .seated, member: "demo-sm3",
              ticket: "demo-salon-open-1", note: "想燙捲一點"),
            r("demo-appt-4", "王冠宇", "0966777888", staff: "s-jacob", ["svc-cut"], at: -15, status: .arrived, member: "demo-sm5", note: "朋友介紹"),
            r("demo-appt-5", "張雅婷", "0955666777", staff: "s-mia", ["svc-color"], at: 15, status: .arrived, member: "demo-sm4", source: "phone"),
            r("demo-appt-7", "許志豪", "0987222333", staff: "s-jacob", ["svc-washcut"], at: 60, source: "phone"),
            r("demo-appt-6", "吳思妤", "0978111222", staff: "s-leslie", ["svc-cut"], at: 150),
            r("demo-appt-8", "周品妤", "0919333444", staff: "s-mia", ["svc-perm"], at: 150, note: "想燙大波浪，會帶參考照"),
            r("demo-appt-10", "劉子晴", "0937555666", staff: "s-jacob", ["svc-treat"], at: 180, status: .cancelled, source: "phone"),
            r("demo-appt-12", "何宜庭", "0926888999", staff: "s-jacob", ["svc-scalp"], at: 240),
            r("demo-appt-9", "鄭宇軒", "0928444555", staff: "s-leslie", ["svc-cut"], at: 240),
        ].sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: 今天

    /// 開班、四個人上班；做完結帳的（扣次數卡、儲值金付、買卡、儲值、買保養品、現場客）、林佳穎正在燙
    func seedSalon(into ledger: Ledger) throws {
        let now = createdAt
        let s = DemoSeeder(ledger: ledger, bootstrap: bootstrap, now: now)
        let desk = "s-cameron"
        let t0 = Self.slot(now, minutes: 15)
        try s.openShift(by: "s-leslie", clockIn: ["s-leslie", desk, "s-jacob", "s-mia"], cash: Money(dollars: 3_000), at: t0.addingTimeInterval(-6 * 3600))
        let members = Self.salonMembers(now: now)
        let appts = Self.salonReservations(now: now)
        func member(_ id: String) -> Member? { members.first { $0.id == id } }
        func appt(_ id: String) -> Reservation? { appts.first { $0.id == id } }
        func redeem(_ m: Member?, _ passId: String) -> PassRedemption? {
            guard let p = m?.passes?.first(where: { $0.id == passId }) else { return nil }
            return PassRedemption(passId: p.id, name: p.name, value: p.unitValue)
        }

        // 現場客：洗剪（一早）
        let walkIn = t0.addingTimeInterval(-330 * 60)
        try s.open("demo-salon-sale-6", at: walkIn, by: desk, mode: .salon, customerName: "現場客", lines: [
            s.line("svc-washcut", staffId: "s-jacob", assistantId: desk, by: desk, at: walkIn),
        ])
        try s.close("demo-salon-sale-6", at: walkIn.addingTimeInterval(80 * 60), by: desk, pay: [DemoPay(.cash)])

        // 蔡宜蓁：剪髮，順便買剪髮 10 次卡（下次開始用）
        if let r = appt("demo-appt-11"), let m = member("demo-sm6") {
            try s.open("demo-salon-sale-5", at: r.startsAt, by: desk, mode: .salon, member: m.ref, appointmentId: r.id, lines: [
                s.line("svc-cut", staffId: "s-mia", by: desk, at: r.startsAt),
                s.line("pass-cut10", seller: "s-mia", by: desk, at: r.endsAt),
            ])
            try s.close("demo-salon-sale-5", at: r.endsAt, by: desk, pay: [DemoPay(.card)])
        }

        // 陳怡君：洗剪扣剪髮卡、染髮用儲值金付、護髮油刷卡
        if let r = appt("demo-appt-1"), let m = member("demo-sm1") {
            try s.open("demo-salon-sale-1", at: r.startsAt, by: desk, mode: .salon, member: m.ref, appointmentId: r.id, lines: [
                s.line("svc-washcut", staffId: "s-jacob", assistantId: desk, redeem: redeem(m, "demo-sp-sm1-cut10"), by: desk, at: r.startsAt),
                s.line("svc-color", optionIds: ["len-mid"], staffId: "s-jacob", assistantId: desk, note: "6N+7.1 1:1", by: desk, at: r.startsAt),
                s.line("retail-oil", seller: "s-jacob", by: desk, at: r.endsAt),
            ])
            try s.close("demo-salon-sale-1", at: r.endsAt, by: desk, pay: [DemoPay(.prepaid, Money(dollars: 2_800)), DemoPay(.card)])
        }

        // 黃柏翰：剪髮付現
        if let r = appt("demo-appt-2"), let m = member("demo-sm2") {
            try s.open("demo-salon-sale-2", at: r.startsAt, by: desk, mode: .salon, member: m.ref, appointmentId: r.id, lines: [
                s.line("svc-cut", staffId: "s-mia", by: desk, at: r.startsAt),
            ])
            try s.close("demo-salon-sale-2", at: r.endsAt, by: desk, pay: [DemoPay(.cash)])
        }

        // 現場買保養品
        let shop = t0.addingTimeInterval(-120 * 60)
        try s.open("demo-salon-sale-4", at: shop, by: desk, mode: .salon, lines: [
            s.line("retail-shampoo", seller: desk, by: desk, at: shop),
            s.line("retail-spray", seller: desk, by: desk, at: shop),
        ])
        try s.close("demo-salon-sale-4", at: shop.addingTimeInterval(180), by: desk, pay: [DemoPay(.linePay)])

        // 林佳穎：來了先儲值 10,000 送 1,000，現在正在燙（長髮）＋護髮扣護髮卡
        if let r = appt("demo-appt-3"), let m = member("demo-sm3") {
            let topUp = r.startsAt.addingTimeInterval(-10 * 60)
            try s.open("demo-salon-sale-3", at: topUp, by: desk, mode: .salon, member: m.ref, lines: [
                s.line("topup-10000", seller: "s-leslie", by: desk, at: topUp),
            ])
            try s.close("demo-salon-sale-3", at: topUp.addingTimeInterval(240), by: desk, pay: [DemoPay(.card)])
            try s.open("demo-salon-open-1", at: r.startsAt, by: desk, mode: .salon, member: m.ref, appointmentId: r.id, lines: [
                s.line("svc-perm", optionIds: ["len-long"], staffId: "s-leslie", assistantId: desk, note: "沙宣捲 2 號棒", by: desk, at: r.startsAt),
                s.line("svc-treat", staffId: "s-leslie", redeem: redeem(m, "demo-sp-sm3-treat5"), by: desk, at: r.startsAt),
            ])
        }
    }
}
