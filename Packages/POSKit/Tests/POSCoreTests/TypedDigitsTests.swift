import Foundation
import Testing
@testable import POSCore

/// 右側鍵盤待機打的數字：數量、會員電話、統編、品號（打完停一下就自動做）
struct TypedDigitsTests {
    private let catalog = Catalog(
        categories: [MenuCategory(id: "c", name: "飲料")],
        items: [
            MenuItem(id: "latte", categoryId: "c", name: "拿鐵", price: Money(dollars: 120), barcode: "4710088123456", plu: "1001"),
            MenuItem(id: "mocha", categoryId: "c", name: "摩卡", price: Money(dollars: 130), plu: "10011"),
            MenuItem(id: "duck", categoryId: "c", name: "鴨胸", price: Money(dollars: 140), plu: "2001"),
            MenuItem(id: "odd", categoryId: "c", name: "電話一樣的品號", price: Money(dollars: 10), plu: "0911111111"),
        ]
    )

    private func kind(_ d: String, checkout: Bool = false) -> TypedDigits? {
        TypedDigits.classify(d, catalog: catalog, atCheckout: checkout)
    }

    @Test func shortDigitsAreQuantity() {
        #expect(kind("3") == .quantity(3))
        #expect(kind("120") == .quantity(120))
        #expect(kind("3")?.actsOnPause == false)
        #expect(kind("") == nil)
    }

    @Test func phoneNumbersBecomeMembers() {
        #expect(kind("09") == .partialPhone("09"))
        #expect(kind("091234") == .partialPhone("091234"))
        #expect(kind("0912345678") == .member(phone: "0912345678"))
        #expect(kind("0912345678")?.actsOnPause == true)
        // 菜單剛好有這個品號：算商品
        if case .product(let m) = kind("0911111111") { #expect(m.item.id == "odd") } else { Issue.record("品號優先") }
    }

    @Test func exactUniqueCodesAddProducts() {
        if case .product(let m) = kind("2001") { #expect(m.item.id == "duck") } else { Issue.record("2001 是鴨胸") }
        if case .product(let m) = kind("4710088123456") { #expect(m.item.id == "latte") } else { Issue.record("條碼") }
        // 1001 對到拿鐵，但還有 10011（摩卡）：還不能確定，等打完
        #expect(kind("1001") == .code("1001"))
        if case .product(let m) = kind("10011") { #expect(m.item.id == "mocha") } else { Issue.record("10011 是摩卡") }
        #expect(kind("5555") == .code("5555"))
    }

    @Test func taxIdOnlyAtCheckout() {
        // 04595257 是檢查碼對的統編
        #expect(kind("04595257", checkout: true) == .taxId("04595257"))
        #expect(kind("04595257", checkout: false) == .code("04595257"))
        #expect(kind("12345678", checkout: true) == .code("12345678"))
    }

    // MARK: 按「確定」

    private func confirm(_ d: String) -> TypedConfirm? {
        TypedConfirm.classify(d, catalog: catalog)
    }

    @Test func confirmWithoutCodeIsAmount() {
        #expect(confirm("120") == .amount(Money(dollars: 120)))
        #expect(confirm("5") == .amount(Money(dollars: 5)))
        #expect(confirm("5555") == .amount(Money(dollars: 5555)))
        #expect(confirm("999999") == .amount(Money(dollars: 999_999)))
        #expect(confirm("") == nil)
    }

    @Test func confirmPrefersProducts() {
        // 1001 也是更長的 10011 的開頭：按了確定就是拿鐵（打完了）
        if case .product(let m) = confirm("1001") { #expect(m.item.id == "latte") } else { Issue.record("1001 是拿鐵") }
        if case .product(let m) = confirm("2001") { #expect(m.item.id == "duck") } else { Issue.record("2001 是鴨胸") }
        if case .product(let m) = confirm("0911111111") { #expect(m.item.id == "odd") } else { Issue.record("品號優先") }
    }

    @Test func confirmDoesNotTurnCodesIntoMoney() {
        #expect(confirm("0912345678") == .member(phone: "0912345678"))
        // 0 開頭、7 碼以上：打錯的品號或條碼，不當錢
        #expect(confirm("0120") == .notFound("0120"))
        #expect(confirm("1234567") == .notFound("1234567"))
        #expect(confirm("4710088999999") == .notFound("4710088999999"))
    }
}
