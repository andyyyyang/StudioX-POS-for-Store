import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範：服飾「Lumi 選物」（虛構）。款式選顏色 × 尺寸、每個規格自己的吊牌條碼與庫存（有賣完、剩最後一件的），
/// 幾樣沒有規格的配件；整張單的業績算給店員；今天已經賣了幾張（有會員折扣、載具、統編）。
extension DemoStore {
    static func apparelBootstrap(now: Date) -> Bootstrap {
        let address = "台北市大安區溫州街 18 巷 3 號 1 樓"
        return Bootstrap(
            version: "demo-apparel", serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "Lumi 選物", legalName: "路米選物有限公司", taxId: "53180603", address: address, phone: "02-2368-0000",
                receiptFooter: "14 天內憑明細換貨（吊牌未拆）・IG @lumi.select", serviceChargeBps: 0, serviceChargeOn: [], tipsEnabled: false,
                defaultOrderType: .takeout, tableTimeLimitMinutes: 0, businessDayCutoffHour: 4, discountLimitBps: 1000,
                discountPresetsBps: [500, 1000, 1500, 2000], serviceModes: [.apparel, .retail], defaultServiceMode: .apparel, exchangeDays: 14
            ),
            features: FeatureFlags(seating: false, kitchen: false, reservations: false, invoice: true, members: true, waitlistSMS: false,
                                   appointments: true, accounts: true, commission: true),
            catalog: apparelCatalog,
            floor: .empty,
            staff: apparelStaff,
            invoice: demoInvoice(taxId: "53180603", name: "路米選物有限公司", address: address, now: now, tracks: ("YA", "YB", "YC")),
            mesh: MeshConfig(key: String(repeating: "6e", count: 32), enabled: false)
        )
    }

    // MARK: 商品

    static let apparelCatalog: Catalog = {
        let categories = [
            MenuCategory(id: "c-tops", name: "上衣", swatch: .sky, sortOrder: 1),
            MenuCategory(id: "c-bottoms", name: "褲裙", swatch: .sand, sortOrder: 2),
            MenuCategory(id: "c-outer", name: "外套", swatch: .sage, sortOrder: 3),
            MenuCategory(id: "c-acc", name: "配件", swatch: .rose, sortOrder: 4),
        ]
        func colorCode(_ c: String) -> String {
            switch c {
            case "黑": "BK"
            case "白": "WH"
            case "燕麥": "OT"
            case "丹寧": "DN"
            default: "XX"
            }
        }
        var serial = 0
        /// 一個款式：顏色 × 尺寸（沒有尺寸就只分顏色）。key 寫「黑M」：soldOut 賣完、low 剩一兩件、discontinued 不再賣
        func style(_ id: String, _ cat: String, _ name: String, _ price: Int, plu: String, sku: String, colors: [String], sizes: [String],
                   soldOut: Set<String> = [], low: Set<String> = [], discontinued: Set<String> = [], plusPrice: Int? = nil) -> MenuItem {
            var variants: [ItemVariant] = []
            for (ci, color) in colors.enumerated() {
                for (si, size) in (sizes.isEmpty ? [""] : sizes).enumerated() {
                    serial += 1
                    let key = color + size
                    let code = size.isEmpty ? colorCode(color) : "\(colorCode(color))-\(size)"
                    let stock = soldOut.contains(key) ? 0 : (low.contains(key) ? 1 + (ci + si) % 2 : 3 + (ci * 3 + si * 2 + serial) % 7)
                    variants.append(ItemVariant(
                        id: "\(id)-\(code.lowercased())", options: size.isEmpty ? [color] : [color, size], sku: "\(sku)-\(code)",
                        barcode: DemoStore.ean13("4710886" + String(format: "%05d", serial)),
                        price: size == "XL" ? plusPrice.map { Money(dollars: $0) } : nil,
                        stock: stock, isAvailable: !discontinued.contains(key)
                    ))
                }
            }
            return MenuItem(id: id, categoryId: cat, name: name, price: Money(dollars: price), plu: plu, unit: "件", sortOrder: Int(plu) ?? 0,
                            optionNames: sizes.isEmpty ? ["顏色"] : ["顏色", "尺寸"], variants: variants)
        }
        /// 沒有規格的配件（一個條碼、一個庫存）
        func accessory(_ id: String, _ name: String, _ price: Int, plu: String, stock: Int?, unit: String = "個") -> MenuItem {
            serial += 1
            return MenuItem(id: id, categoryId: "c-acc", name: name, price: Money(dollars: price),
                            barcode: DemoStore.ean13("4710886" + String(format: "%05d", 90_000 + serial)), plu: plu, unit: unit,
                            sortOrder: Int(plu) ?? 0, stock: stock)
        }
        let items: [MenuItem] = [
            style("ap-oxford", "c-tops", "牛津布寬版襯衫", 1_680, plu: "101", sku: "LM-SH01", colors: ["白", "丹寧", "燕麥"], sizes: ["S", "M", "L", "XL"],
                  soldOut: ["白M"], low: ["丹寧S", "燕麥XL"]),
            style("ap-tee", "c-tops", "有機棉圓領 T", 590, plu: "102", sku: "LM-TS02", colors: ["黑", "白", "燕麥"], sizes: ["S", "M", "L", "XL"],
                  low: ["白S"]),
            style("ap-knit", "c-tops", "羊毛混紡針織衫", 1_980, plu: "103", sku: "LM-KN03", colors: ["黑", "燕麥"], sizes: ["S", "M", "L"],
                  soldOut: ["燕麥M"], low: ["黑L"]),
            style("ap-sweat", "c-tops", "重磅大學 T", 1_280, plu: "104", sku: "LM-SW04", colors: ["黑", "燕麥", "白"], sizes: ["M", "L", "XL"],
                  plusPrice: 1_380),
            style("ap-straight", "c-bottoms", "經典直筒褲", 1_480, plu: "201", sku: "LM-PT01", colors: ["黑", "丹寧"], sizes: ["S", "M", "L", "XL"],
                  low: ["黑M"]),
            style("ap-wide", "c-bottoms", "打褶寬褲", 1_580, plu: "202", sku: "LM-PT02", colors: ["黑", "燕麥"], sizes: ["S", "M", "L"],
                  soldOut: ["黑S"]),
            style("ap-skirt", "c-bottoms", "丹寧 A 字裙", 1_280, plu: "203", sku: "LM-SK03", colors: ["丹寧", "黑"], sizes: ["S", "M", "L"],
                  discontinued: ["黑L"]),
            style("ap-trench", "c-outer", "短版風衣", 3_480, plu: "301", sku: "LM-OT01", colors: ["燕麥", "黑"], sizes: ["S", "M", "L"],
                  low: ["燕麥S"]),
            style("ap-denim", "c-outer", "丹寧外套", 2_680, plu: "302", sku: "LM-OT02", colors: ["丹寧"], sizes: ["S", "M", "L", "XL"],
                  soldOut: ["丹寧XL"]),
            style("ap-cardigan", "c-outer", "針織開襟外套", 2_280, plu: "303", sku: "LM-OT03", colors: ["燕麥", "白", "黑"], sizes: ["S", "M", "L"]),
            style("ap-cap", "c-acc", "水洗棒球帽", 680, plu: "401", sku: "LM-AC01", colors: ["黑", "燕麥", "丹寧"], sizes: []),
            accessory("ap-tote", "帆布托特包", 890, plu: "402", stock: 12),
            accessory("ap-socks", "羅紋中筒襪", 220, plu: "403", stock: 40, unit: "雙"),
            accessory("ap-scarf", "羊毛圍巾", 1_180, plu: "404", stock: 0, unit: "條"),
            accessory("ap-bag", "購物紙袋", 2, plu: "405", stock: nil),
        ]
        return Catalog(categories: categories, items: items)
    }()

    // MARK: 人員

    static let apparelStaff: [StaffMember] = [
        person("s-leslie", "Leslie K.", .manager, "1234", .lavender, title: "店長", commissionBps: 200),
        person("s-cameron", "Cameron W.", .cashier, "2580", .mint, title: "銷售", commissionBps: 300),
        person("s-jacob", "Jacob J.", .supervisor, "1111", .rose, title: "銷售", commissionBps: 300),
        person("s-owner", "王小美", .owner, "0000", .peach, title: "負責人"),
    ]

    // MARK: 會員（後台的）

    static func apparelMembers(now: Date) -> [Member] {
        [
            Member(id: "demo-am1", phone: "0912876543", name: "李思妤", tierName: "VIP", lifetimeSpend: Money(dollars: 32_460), visits: 18,
                   lastVisitAt: daysAgo(12, now), note: "上衣 M、褲子 S（腰 25）；喜歡大地色、寬版。新品到貨傳 LINE 給她",
                   accountEventIds: [],
                   recentVisits: [
                       visit("am1-a", "A031", daysAgo: 12, now: now, total: 3_060, items: ["短版風衣 燕麥・S"], staff: ["Jacob J."]),
                       visit("am1-b", "A012", daysAgo: 41, now: now, total: 2_170, items: ["有機棉圓領 T 白・M", "打褶寬褲 燕麥・S"], staff: ["Cameron W."]),
                       visit("am1-c", "A044", daysAgo: 77, now: now, total: 1_980, items: ["羊毛混紡針織衫 燕麥・M"], staff: ["Leslie K."]),
                   ],
                   birthday: "03-02"),
            Member(id: "demo-am2", phone: "0921555666", name: "周承翰", tierName: "一般會員", lifetimeSpend: Money(dollars: 6_830), visits: 5,
                   lastVisitAt: daysAgo(30, now), note: "褲長要修短 3 公分（免費修改，三天後取）",
                   accountEventIds: [],
                   recentVisits: [
                       visit("am2-a", "A027", daysAgo: 30, now: now, total: 2_760, items: ["經典直筒褲 丹寧・L", "重磅大學 T 黑・L"], staff: ["Jacob J."],
                             note: "直筒褲修短 3 公分"),
                   ]),
            Member(id: "demo-am3", phone: "0938111222", name: "楊欣怡", tierName: "金卡", lifetimeSpend: Money(dollars: 18_920), visits: 11,
                   lastVisitAt: daysAgo(19, now), note: "常買給媽媽：上衣 L；不喜歡亮色",
                   accountEventIds: [],
                   recentVisits: [
                       visit("am3-a", "A019", daysAgo: 19, now: now, total: 4_118, items: ["針織開襟外套 燕麥・L", "牛津布寬版襯衫 白・L"], staff: ["Leslie K."]),
                       visit("am3-b", "A008", daysAgo: 63, now: now, total: 890, items: ["帆布托特包"], staff: ["Cameron W."]),
                   ],
                   birthday: birthdayThisMonth(9, now: now)),
            Member(id: "demo-am4", phone: "0965432100", name: "許雅筑", tierName: "一般會員", lifetimeSpend: Money(dollars: 1_280), visits: 1,
                   lastVisitAt: daysAgo(4, now), note: nil, accountEventIds: [],
                   recentVisits: [visit("am4-a", "A052", daysAgo: 4, now: now, total: 1_280, items: ["丹寧 A 字裙 丹寧・S"], staff: ["Cameron W."])]),
        ]
    }

    // MARK: 今天

    /// 早上開班、三個人上班、今天賣了八張（有規格、會員九折、手機條碼、統編）
    func seedApparel(into ledger: Ledger) throws {
        let now = createdAt
        let s = DemoSeeder(ledger: ledger, bootstrap: bootstrap, now: now)
        let leslie = "s-leslie", cameron = "s-cameron", jacob = "s-jacob"
        try s.openShift(by: leslie, clockIn: [leslie, cameron, jacob], cash: Money(dollars: 5_000), at: now.addingTimeInterval(-6.6 * 3600))
        let members = Self.apparelMembers(now: now)
        func ref(_ phone: String?) -> MemberRef? {
            guard let phone else { return nil }
            return members.first { $0.phone == phone }?.ref
        }

        var n = 0
        /// 一張單：items 是（品項, 規格, 件數）
        func sale(_ minutesAgo: Double, seller: String, member phone: String? = nil, _ items: [(String, String?, Int)], pay: [DemoPay],
                  buyer: InvoiceBuyer? = nil, memberDiscount: Bool = false) throws {
            n += 1
            let at = now.addingTimeInterval(-minutesAgo * 60)
            let id = "demo-apparel-sale-\(n)"
            let lines = items.map { s.line($0.0, $0.2, variant: $0.1, seller: seller, by: seller, at: at) }
            try s.open(id, at: at, by: seller, mode: .apparel, member: ref(phone), salespersonId: seller, lines: lines)
            if memberDiscount {
                try s.discount(id, .percent(1000, reason: "會員九折"), by: seller, at: at.addingTimeInterval(120))
            }
            try s.close(id, at: at.addingTimeInterval(240), by: seller, pay: pay, buyer: buyer)
        }

        try sale(372, seller: cameron, member: "0912876543", [("ap-tee", "ap-tee-wh-m", 2), ("ap-straight", "ap-straight-bk-m", 1)],
                 pay: [DemoPay(.card)], memberDiscount: true)
        try sale(331, seller: jacob, [("ap-trench", "ap-trench-ot-s", 1)], pay: [DemoPay(.linePay)],
                 buyer: .consumer(carrier: .mobileBarcode("/LM8+2QK")))
        try sale(287, seller: cameron, [("ap-tote", nil, 1), ("ap-socks", nil, 3), ("ap-bag", nil, 1)], pay: [DemoPay(.cash)])
        try sale(236, seller: leslie, member: "0938111222", [("ap-oxford", "ap-oxford-dn-l", 1), ("ap-wide", "ap-wide-bk-m", 1)],
                 pay: [DemoPay(.card)], memberDiscount: true)
        try sale(174, seller: jacob, [("ap-knit", "ap-knit-bk-m", 1)], pay: [DemoPay(.jkoPay)])
        try sale(121, seller: cameron, [("ap-sweat", "ap-sweat-ot-l", 1), ("ap-cap", "ap-cap-bk", 1)], pay: [DemoPay(.cash)])
        try sale(68, seller: leslie, [("ap-denim", "ap-denim-dn-m", 2)], pay: [DemoPay(.card)],
                 buyer: .business(taxId: "91540603", title: "光點設計有限公司"))
        try sale(23, seller: jacob, member: "0921555666", [("ap-skirt", "ap-skirt-dn-s", 1), ("ap-tee", "ap-tee-bk-s", 1)],
                 pay: [DemoPay(.voucher, Money(dollars: 500)), DemoPay(.pxPay)])

        // 正在試穿的客人：先放進單子
        let fitting = now.addingTimeInterval(-6 * 60)
        try s.open("demo-apparel-open-1", at: fitting, by: cameron, mode: .apparel, salespersonId: cameron, lines: [
            s.line("ap-cardigan", 1, variant: "ap-cardigan-wh-m", seller: cameron, by: cameron, at: fitting),
            s.line("ap-wide", 1, variant: "ap-wide-ot-m", seller: cameron, by: cameron, at: fitting),
        ])
    }
}
