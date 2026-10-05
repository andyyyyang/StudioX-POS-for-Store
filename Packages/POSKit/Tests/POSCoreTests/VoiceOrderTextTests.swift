import Foundation
import Testing
@testable import POSCore

/// 語音點餐：說的話對到菜單（黃毛丫頭的菜單：兩種價錢的鴨胸、一串的鴨心、三入的鴨腸）
struct VoiceOrderTextTests {
    private let catalog = Catalog(
        categories: [MenuCategory(id: "c", name: "太空鴨品")],
        items: [
            MenuItem(id: "breast", categoryId: "c", name: "鴨胸", price: Money(dollars: 140),
                     variants: [ItemVariant(id: "b140", options: ["140"], price: Money(dollars: 140)),
                                ItemVariant(id: "b150", options: ["150"], price: Money(dollars: 150))]),
            MenuItem(id: "heart", categoryId: "c", name: "鴨心", price: Money(dollars: 35), unit: "1串"),
            MenuItem(id: "gut", categoryId: "c", name: "鴨腸", price: Money(dollars: 40), unit: "3入"),
            MenuItem(id: "head", categoryId: "c", name: "鴨頭", price: Money(dollars: 60)),
            MenuItem(id: "neck", categoryId: "c", name: "鴨脖", price: Money(dollars: 40)),
        ]
    )

    @Test func numbersInChineseAndDigits() {
        #expect(VoiceOrderText.number("3") == 3)
        #expect(VoiceOrderText.number("３") == 3)
        #expect(VoiceOrderText.number("兩") == 2)
        #expect(VoiceOrderText.number("十") == 10)
        #expect(VoiceOrderText.number("十二") == 12)
        #expect(VoiceOrderText.number("二十五") == 25)
        #expect(VoiceOrderText.number("一百二十") == 120)
        #expect(VoiceOrderText.number("份") == nil)
        #expect(VoiceOrderText.number("") == nil)
    }

    @Test func namesMatchTheMenu() {
        #expect(VoiceOrderText.match(name: "鴨胸", in: catalog)?.id == "breast")
        #expect(VoiceOrderText.match(name: "鴨胸肉", in: catalog)?.id == "breast")
        #expect(VoiceOrderText.match(name: " 鴨 心 ", in: catalog)?.id == "heart")
        #expect(VoiceOrderText.match(name: "牛肉麵", in: catalog) == nil)
    }

    @Test func variantsByPrice() {
        let breast = catalog.items[0]
        #expect(VoiceOrderText.variant("150", of: breast)?.id == "b150")
        #expect(VoiceOrderText.variant("一百四", of: breast) == nil || VoiceOrderText.variant("一百四", of: breast)?.id == "b140")
        #expect(VoiceOrderText.variant("140元", of: breast)?.id == "b140")
        #expect(VoiceOrderText.variant("", of: breast) == nil)
    }

    @Test func parsesAWholeSentence() {
        let lines = VoiceOrderText.parse("鴨胸 140 兩份、鴨心一串，還有三個鴨頭", catalog: catalog)
        #expect(lines.map(\.item.id) == ["breast", "heart", "head"])
        #expect(lines[0].variant?.id == "b140" && lines[0].quantity == 2)
        #expect(lines[1].quantity == 1)
        #expect(lines[2].quantity == 3)
    }

    @Test func quantityBeforeTheName() {
        let lines = VoiceOrderText.parse("兩份鴨脖跟一個鴨腸", catalog: catalog)
        #expect(lines.map(\.item.id) == ["neck", "gut"])
        #expect(lines.map(\.quantity) == [2, 1])
    }

    @Test func priceAfterQuantity() {
        let lines = VoiceOrderText.parse("鴨胸兩份150", catalog: catalog)
        #expect(lines.count == 1)
        #expect(lines[0].variant?.id == "b150" && lines[0].quantity == 2)
    }

    @Test func missingVariantIsReported() {
        let lines = VoiceOrderText.parse("鴨胸一份", catalog: catalog)
        #expect(lines.count == 1 && lines[0].needsVariant)
    }

    @Test func nothingFromTheMenu() {
        #expect(VoiceOrderText.parse("今天天氣很好", catalog: catalog).isEmpty)
    }
}
