import Foundation
import Testing
@testable import POSCore

/// 語音點餐：聽寫的別字改回菜單上的名字、數字、規格（黃毛丫頭的菜單：兩種價錢的鴨胸、一串的鴨心）
struct VoiceOrderTextTests {
    /// 測試用的讀音（手機上用系統的拼音轉換）
    private static let readings: [Character: String] = [
        "鴨": "ya1", "壓": "ya1", "牙": "ya2", "胸": "xiong1", "兄": "xiong1", "心": "xin1", "腸": "chang2", "場": "chang3",
        "頭": "tou2", "脖": "bo2", "子": "zi5", "黃": "huang2", "金": "jin1", "豬": "zhu1", "租": "zu1", "血": "xie3", "糕": "gao1",
        "涼": "liang2", "粉": "fen3", "兩": "liang3", "份": "fen4", "蛋": "dan4", "但": "dan4", "是": "shi4", "一": "yi1",
        "個": "ge4", "串": "chuan4", "可": "ke3", "樂": "le4", "紅": "hong2", "茶": "cha2",
    ]

    private let catalog = Catalog(
        categories: [MenuCategory(id: "c", name: "太空鴨品"), MenuCategory(id: "d", name: "飲料"), MenuCategory(id: "s", name: "套餐")],
        items: [
            MenuItem(id: "breast", categoryId: "c", name: "鴨胸", price: Money(dollars: 140),
                     variants: [ItemVariant(id: "b140", options: ["140"], price: Money(dollars: 140)),
                                ItemVariant(id: "b150", options: ["150"], price: Money(dollars: 150))]),
            MenuItem(id: "heart", categoryId: "c", name: "鴨心", price: Money(dollars: 35), unit: "1串"),
            MenuItem(id: "gut", categoryId: "c", name: "鴨腸", price: Money(dollars: 40)),
            MenuItem(id: "head", categoryId: "c", name: "鴨頭", price: Money(dollars: 60)),
            MenuItem(id: "neck", categoryId: "c", name: "鴨脖", price: Money(dollars: 40)),
            MenuItem(id: "golden", categoryId: "c", name: "黃金鴨腸", price: Money(dollars: 80)),
            MenuItem(id: "cake", categoryId: "c", name: "豬血糕", price: Money(dollars: 30)),
            MenuItem(id: "jelly", categoryId: "c", name: "涼粉", price: Money(dollars: 30)),
            MenuItem(id: "egg", categoryId: "c", name: "蛋", price: Money(dollars: 15)),
            MenuItem(id: "tea", categoryId: "d", name: "紅茶", price: Money(dollars: 25)),
            MenuItem(id: "tea-set", categoryId: "s", name: "紅茶", price: Money(dollars: 0)),
        ]
    )

    private var menu: VoiceMenu {
        VoiceMenu(catalog: catalog, pronounce: { VoiceOrderTextTests.readings[$0] })
    }

    private func item(_ id: String) -> MenuItem { catalog.items.first { $0.id == id }! }

    // MARK: 改別字

    @Test func homophonesBecomeMenuNames() {
        #expect(menu.corrected("壓胸兩份") == "鴨胸兩份")
        #expect(menu.corrected("鴨兄一份") == "鴨胸一份")
        // 聲母 zh/z 不分
        #expect(menu.corrected("租血糕兩個") == "豬血糕兩個")
        // 四個字的名字：同音不同調也算
        #expect(menu.corrected("黃金壓場") == "黃金鴨腸")
    }

    @Test func quantitiesAndOtherWordsStay() {
        // 「兩份」和菜單上的「涼粉」同音，但數字、量詞不改
        #expect(menu.corrected("鴨胸兩份") == "鴨胸兩份")
        #expect(menu.corrected("兩份涼粉") == "兩份涼粉")
        // 一個字的名字只認一模一樣的（「但」不會變成「蛋」）
        #expect(menu.corrected("但是鴨頭") == "但是鴨頭")
        #expect(menu.corrected("A餐") == "A餐")
        #expect(menu.corrected("") == "")
    }

    @Test func modelChoicesMustBeHeard() {
        #expect(menu.mentions(item("breast"), in: "鴨胸兩份"))
        #expect(menu.mentions(item("neck"), in: "脖子兩份"))
        #expect(!menu.mentions(item("breast"), in: "可樂一個"))
    }

    @Test func labelsForTheModel() {
        let labels = menu.entries.map(\.label)
        #expect(labels.contains("紅茶（飲料）") && labels.contains("紅茶（套餐）"))
        #expect(menu.item(label: "紅茶（套餐）")?.id == "tea-set")
        #expect(menu.item(label: "鴨胸")?.id == "breast")
        #expect(menu.item(label: "可樂") == nil)
        #expect(menu.menuLine.hasPrefix("鴨胸(140/150)、鴨心、"))
        #expect(menu.vocabulary.contains("鴨胸") && !menu.vocabulary.contains("蛋"))
    }

    // MARK: 數字、規格

    @Test func numbersInChineseAndDigits() {
        #expect(VoiceOrderText.number("3") == 3)
        #expect(VoiceOrderText.number("３") == 3)
        #expect(VoiceOrderText.number("兩") == 2)
        #expect(VoiceOrderText.number("十") == 10)
        #expect(VoiceOrderText.number("十二") == 12)
        #expect(VoiceOrderText.number("二十五") == 25)
        #expect(VoiceOrderText.number("一百二十") == 120)
        #expect(VoiceOrderText.number("一百四") == 140)
        #expect(VoiceOrderText.number("份") == nil)
        #expect(VoiceOrderText.number("") == nil)
    }

    @Test func variantsByPriceOrLabel() {
        let breast = item("breast")
        #expect(VoiceOrderText.variant("150", of: breast)?.id == "b150")
        #expect(VoiceOrderText.variant("一百四", of: breast)?.id == "b140")
        #expect(VoiceOrderText.variant("140元", of: breast)?.id == "b140")
        #expect(VoiceOrderText.variant("", of: breast) == nil)
    }
}
