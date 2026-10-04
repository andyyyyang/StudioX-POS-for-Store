import Foundation
import Testing
@testable import POSCore

/// 掃碼：一個鍵，照內容判斷是載具、商品、會員還是折價券（docs/API.md「掃碼」）
struct ScanCodeTests {
    private let catalog = Catalog(
        categories: [MenuCategory(id: "c", name: "上衣", swatch: .sand)],
        items: [
            MenuItem(id: "latte", categoryId: "c", name: "拿鐵", price: Money(dollars: 120), barcode: "4710088123456", plu: "101"),
            MenuItem(id: "tee", categoryId: "c", name: "重磅素T", price: Money(dollars: 690), optionNames: ["顏色", "尺寸"], variants: [
                ItemVariant(id: "tee-blk-m", options: ["黑", "M"], sku: "TEE-BLK-M", barcode: "4710912345678"),
            ]),
        ]
    )

    @Test func carriers() {
        #expect(ScanCode.classify("/ABC+123", catalog: catalog) == .carrier(.mobileBarcode("/ABC+123")))
        // 掃描器打成小寫、前後有空白
        #expect(ScanCode.classify(" /abc.12-\n", catalog: catalog) == .carrier(.mobileBarcode("/ABC.12-")))
        #expect(ScanCode.classify("AB12345678901234", catalog: catalog) == .carrier(.citizenCertificate("AB12345678901234")))
        // 少一碼的不是載具（照樣當折價券查）
        #expect(ScanCode.carrier(in: "/ABC+12") == nil)
    }

    @Test func membersFromCardsAndLinks() {
        #expect(ScanCode.classify("0912345678", catalog: catalog) == .member(phone: "0912345678"))
        #expect(ScanCode.memberPhone(in: "0912-345-678") == "0912345678")
        #expect(ScanCode.memberPhone(in: "+886 912 345 678") == "0912345678")
        #expect(ScanCode.memberPhone(in: "https://yellowgirl.tw/member?phone=0912345678&ref=card") == "0912345678")
        #expect(ScanCode.memberPhone(in: "https://shop.tw/m?phone=%2B886912345678") == "0912345678")
        #expect(ScanCode.memberPhone(in: "member:0922111333") == "0922111333")
        // 前後還連著數字的不是電話（商品條碼裡剛好有 09…）
        #expect(ScanCode.memberPhone(in: "4710912345679") == nil)
        #expect(ScanCode.memberPhone(in: "09123456789") == nil)
        #expect(ScanCode.memberPhone(in: "0812345678") == nil)
        #expect(ScanCode.memberPhone(in: "") == nil)
    }

    @Test func productsWinOverEverythingButCarriers() {
        guard case .product(let m) = ScanCode.classify("4710088123456", catalog: catalog) else {
            Issue.record("條碼應該是商品")
            return
        }
        #expect(m.item.id == "latte" && m.variant == nil)
        #expect(ScanCode.classify("101", catalog: catalog) == .product(Catalog.Match(item: catalog.items[0], variant: nil)))
        // 吊牌的條碼裡剛好有 0912345678：菜單對得到，算商品
        guard case .product(let tee) = ScanCode.classify("4710912345678", catalog: catalog) else {
            Issue.record("吊牌條碼應該是商品")
            return
        }
        #expect(tee.variant?.id == "tee-blk-m")
        // SKU 也像折價券代碼：菜單對得到就是商品
        guard case .product = ScanCode.classify("TEE-BLK-M", catalog: catalog) else {
            Issue.record("SKU 應該是商品")
            return
        }
    }

    @Test func couponsAreEverythingElseThatLooksLikeACode() {
        #expect(ScanCode.classify("yg-a3b2c1", catalog: catalog) == .coupon(code: "YG-A3B2C1"))
        #expect(ScanCode.classify("WELCOME100", catalog: catalog) == .coupon(code: "WELCOME100"))
        // 對不到菜單的數字也照折價券查（查不到後台會說）
        #expect(ScanCode.classify("4710000000000", catalog: catalog) == .coupon(code: "4710000000000"))
        #expect(ScanCode.couponCode(in: "ABC") == nil)
        #expect(ScanCode.couponCode(in: String(repeating: "A", count: 33)) == nil)
        #expect(ScanCode.couponCode(in: "----") == nil)
        #expect(ScanCode.couponCode(in: "折價券") == nil)
        #expect(ScanCode.classify("新會員", catalog: catalog) == .unknown("新會員"))
        #expect(ScanCode.classify("https://example.tw/x", catalog: catalog) == .unknown("https://example.tw/x"))
    }
}

/// 折價券的整單折扣：帶著代碼與最低消費；沒有代碼的折扣 JSON 跟以前一模一樣
struct CouponDiscountTests {
    @Test func couponCodeIsOptionalAndOmitted() throws {
        let enc = EventCoding.encoder()
        let plain = String(decoding: try enc.encode(Discount.percent(1000, reason: "熟客")), as: UTF8.self)
        #expect(plain == #"{"kind":"percent","reason":"熟客","value":1000}"#)

        let coupon = Discount(kind: .amount, value: 10_000, reason: "折價券 新會員 100 元", couponCode: "YG-A3B2C1", minimumOrder: Money(dollars: 300))
        let json = String(decoding: try enc.encode(coupon), as: UTF8.self)
        #expect(json == #"{"couponCode":"YG-A3B2C1","kind":"amount","minimumOrder":30000,"reason":"折價券 新會員 100 元","value":10000}"#)
        #expect(try EventCoding.decoder().decode(Discount.self, from: Data(json.utf8)) == coupon)
        // 舊版 App 記的折扣（沒有這兩個欄位）照樣讀得進來
        let old = try EventCoding.decoder().decode(Discount.self, from: Data(#"{"kind":"amount","value":5000,"reason":"招待"}"#.utf8))
        #expect(old.couponCode == nil && old.minimumOrder == nil && !old.isCoupon)
    }

    @Test func minimumOrderShortfall() {
        let d = Discount(kind: .amount, value: 10_000, reason: "折價券", couponCode: "WELCOME100", minimumOrder: Money(dollars: 300))
        #expect(d.shortfall(subtotal: Money(dollars: 299)) == Money(dollars: 1))
        #expect(d.shortfall(subtotal: Money(dollars: 300)) == nil)
        #expect(Discount.percent(1000).shortfall(subtotal: .zero) == nil)
    }

    /// ticket.updated 帶折價券 → 單子上的整單折扣；結帳的 sale 帶 couponCode（後台記一筆使用）
    @Test func couponFlowsIntoTheSale() throws {
        var dev = Device("dev-a")
        var state = StoreState()
        let opened = TicketOpened(ticketId: "t1", number: "A012", orderType: .takeout, businessDate: "2026-09-21")
        state.apply(dev.emit(.ticketOpened(opened)))
        state.apply(dev.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "滷味拼盤", 180, qty: 2)]))))
        let coupon = Discount(kind: .amount, value: 10_000, reason: "折價券 新會員 100 元", couponCode: "YG-A3B2C1", minimumOrder: Money(dollars: 300))
        state.apply(dev.emit(.ticketUpdated(TicketUpdated(ticketId: "t1", discount: coupon))))
        let t = try #require(state.tickets["t1"])
        #expect(t.discount?.couponCode == "YG-A3B2C1")
        #expect(t.totals.orderDiscount == Money(dollars: 100))
        #expect(t.totals.total == Money(dollars: 260))
        #expect(t.discount?.shortfall(subtotal: t.totals.subtotal) == nil)

        let sale = SaleRecord(ticket: t, closedOn: "dev-a", shiftId: nil, closedAt: Fixture.now, closedBy: "s1", staffName: "阿珠", floor: FloorPlan())
        #expect(sale.couponCode == "YG-A3B2C1")
        #expect(sale.discountReason == "折價券 新會員 100 元")
        #expect(sale.discount == Money(dollars: 100))
        #expect(sale.orderDiscount == Money(dollars: 100))
        let json = String(decoding: try EventCoding.encoder().encode(sale), as: UTF8.self)
        #expect(json.contains(#""couponCode":"YG-A3B2C1""#))
        #expect(json.contains(#""orderDiscount":10000"#))

        // 一行自己的折扣＋折價券：sale.discount 是兩個加起來，orderDiscount 只有折價券的（後台記折價券折了多少用這個）
        var mixed = t
        mixed.lines[0].discount = .amount(Money(dollars: 20))
        let mixedSale = SaleRecord(ticket: mixed, closedOn: "dev-a", shiftId: nil, closedAt: Fixture.now, closedBy: "s1", staffName: "阿珠", floor: FloorPlan())
        #expect(mixedSale.discount == Money(dollars: 120) && mixedSale.orderDiscount == Money(dollars: 100))

        // 舊版 App 記的 sale（沒有這兩個欄位）照樣讀得進來
        var legacy = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        legacy.removeValue(forKey: "couponCode")
        legacy.removeValue(forKey: "orderDiscount")
        let old = try EventCoding.decoder().decode(SaleRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.couponCode == nil && old.orderDiscount == nil && old.discount == Money(dollars: 100))

        // 一般的折扣：sale 沒有 couponCode（JSON 裡不出現）
        var plain = t
        plain.discount = .percent(1000, reason: "熟客")
        let plainSale = SaleRecord(ticket: plain, closedOn: "dev-a", shiftId: nil, closedAt: Fixture.now, closedBy: "s1", staffName: "阿珠", floor: FloorPlan())
        #expect(plainSale.couponCode == nil && plainSale.orderDiscount == Money(dollars: 36))
        #expect(!String(decoding: try EventCoding.encoder().encode(plainSale), as: UTF8.self).contains("couponCode"))

        // 沒有整單折扣：orderDiscount 不出現
        var none = t
        none.discount = nil
        let noneJSON = String(decoding: try EventCoding.encoder().encode(SaleRecord(ticket: none, closedOn: "dev-a", shiftId: nil, closedAt: Fixture.now,
                                                                                   closedBy: "s1", staffName: "阿珠", floor: FloorPlan())), as: UTF8.self)
        #expect(!noneJSON.contains("orderDiscount") && !noneJSON.contains("couponCode"))

        // 拿掉折價券（未達最低消費、換成別的折扣）
        state.apply(dev.emit(.ticketUpdated(TicketUpdated(ticketId: "t1", clearDiscount: true))))
        #expect(state.tickets["t1"]?.discount == nil)
    }
}
