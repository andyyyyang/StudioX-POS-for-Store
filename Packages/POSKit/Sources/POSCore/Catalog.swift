import Foundation

// 菜單：後台「門市 POS → 菜單」編的，透過 bootstrap 傳到每台 iPad。
// 品項的名字與價格在加進單子的那一刻抄一份到單子上（TicketLine），之後菜單改價不影響已經點的。

/// 分類的色塊（點餐畫面的大方塊）。亮色、暗色由 App 決定實際色碼，這裡只存「哪一色」
public enum Swatch: String, Codable, Sendable, CaseIterable, Hashable {
    case peach, lavender, mint, sky, butter, rose, sage, sand, clay, slate
}

public struct MenuCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var swatch: Swatch
    public var sortOrder: Int
    /// 預設送到哪個出單站（「吧台」「廚房」）；品項可以自己覆寫
    public var station: String?

    public init(id: String, name: String, swatch: Swatch = .sand, sortOrder: Int = 0, station: String? = nil) {
        self.id = id; self.name = name; self.swatch = swatch; self.sortOrder = sortOrder; self.station = station
    }
}

/// 課稅別（電子發票的 TaxType）：1 應稅、2 零稅率、3 免稅
public enum TaxKind: Int, Codable, Sendable, Hashable {
    case taxable = 1, zeroRated = 2, exempt = 3
}

public struct MenuItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var categoryId: String
    public var name: String
    /// 廚房單、按鈕放不下時用的短名（「珍奶L」）
    public var shortName: String?
    public var price: Money
    /// 時價：點的時候在右側鍵盤輸入價格
    public var openPrice: Bool
    /// 國際條碼／店內條碼（掃描器掃到直接加）
    public var barcode: String?
    /// 店內品號（右側鍵盤輸入品號＋「品號」直接加）
    public var plu: String?
    public var modifierGroupIds: [String]
    public var station: String?
    public var taxKind: TaxKind
    /// 今天賣完（86）：按鈕變灰、不能加
    public var isAvailable: Bool
    public var unit: String
    public var imageURL: String?
    public var sortOrder: Int
    /// 連到網路商店的商品（賣出時扣同一份庫存）
    public var productId: String?
    public var variantId: String?
    /// 這個品項剩幾份（沒有連庫存就是 nil）
    public var stock: Int?

    public init(
        id: String, categoryId: String, name: String, shortName: String? = nil, price: Money, openPrice: Bool = false,
        barcode: String? = nil, plu: String? = nil, modifierGroupIds: [String] = [], station: String? = nil,
        taxKind: TaxKind = .taxable, isAvailable: Bool = true, unit: String = "份", imageURL: String? = nil,
        sortOrder: Int = 0, productId: String? = nil, variantId: String? = nil, stock: Int? = nil
    ) {
        self.id = id; self.categoryId = categoryId; self.name = name; self.shortName = shortName; self.price = price
        self.openPrice = openPrice; self.barcode = barcode; self.plu = plu; self.modifierGroupIds = modifierGroupIds
        self.station = station; self.taxKind = taxKind; self.isAvailable = isAvailable; self.unit = unit
        self.imageURL = imageURL; self.sortOrder = sortOrder; self.productId = productId; self.variantId = variantId; self.stock = stock
    }
}

/// 加料、甜度、冰塊、份量……一組選項
public struct ModifierGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// 至少選幾個（甜度：1）
    public var minSelect: Int
    /// 最多選幾個（加料：3；0 = 不限）
    public var maxSelect: Int
    public var options: [ModifierOption]
    public var sortOrder: Int

    public init(id: String, name: String, minSelect: Int = 0, maxSelect: Int = 1, options: [ModifierOption], sortOrder: Int = 0) {
        self.id = id; self.name = name; self.minSelect = minSelect; self.maxSelect = maxSelect; self.options = options; self.sortOrder = sortOrder
    }

    public var isRequired: Bool { minSelect > 0 }
    public var isSingleChoice: Bool { maxSelect == 1 }
    public var defaultOptionIds: [String] { options.filter(\.isDefault).map(\.id) }

    /// 選了這些選項合不合規則（回 nil＝可以）
    public func problem(selected: [String]) -> String? {
        let n = selected.count
        if n < minSelect { return minSelect == 1 ? "請選\(name)" : "\(name)至少選 \(minSelect) 項" }
        if maxSelect > 0 && n > maxSelect { return "\(name)最多選 \(maxSelect) 項" }
        return nil
    }
}

public struct ModifierOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var priceDelta: Money
    public var isDefault: Bool
    public var isAvailable: Bool

    public init(id: String, name: String, priceDelta: Money = .zero, isDefault: Bool = false, isAvailable: Bool = true) {
        self.id = id; self.name = name; self.priceDelta = priceDelta; self.isDefault = isDefault; self.isAvailable = isAvailable
    }
}

/// 一整份菜單與查詢索引
public struct Catalog: Codable, Sendable, Hashable {
    public var categories: [MenuCategory]
    public var items: [MenuItem]
    public var modifierGroups: [ModifierGroup]

    public init(categories: [MenuCategory] = [], items: [MenuItem] = [], modifierGroups: [ModifierGroup] = []) {
        self.categories = categories.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        self.items = items
        self.modifierGroups = modifierGroups
    }

    public static let empty = Catalog()

    public func item(_ id: String) -> MenuItem? { items.first { $0.id == id } }
    public func category(_ id: String) -> MenuCategory? { categories.first { $0.id == id } }
    public func group(_ id: String) -> ModifierGroup? { modifierGroups.first { $0.id == id } }

    public func items(in categoryId: String) -> [MenuItem] {
        items.filter { $0.categoryId == categoryId }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    public func groups(for item: MenuItem) -> [ModifierGroup] {
        item.modifierGroupIds.compactMap { group($0) }
    }

    /// 掃描器、品號：條碼或品號完全相同
    public func lookup(code: String) -> MenuItem? {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return nil }
        return items.first { $0.barcode == c } ?? items.first { $0.plu == c }
    }

    /// 搜尋：名字、短名、品號、條碼（不分大小寫；中文直接比對子字串）
    public func search(_ query: String) -> [MenuItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return items.filter { item in
            item.name.lowercased().contains(q) || (item.shortName?.lowercased().contains(q) ?? false)
                || item.plu == q || item.barcode == q
        }
    }

    /// 品項出單站：品項自己的 → 分類的 → nil（不出單）
    public func station(for item: MenuItem) -> String? {
        item.station ?? category(item.categoryId)?.station
    }
}
