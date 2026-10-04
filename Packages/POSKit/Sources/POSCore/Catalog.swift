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

/// 品項的種類：一般商品、服務、課程卡／會籍、儲值
public enum ItemKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// 一般商品（餐點、飲料、衣服、保養品）
    case goods
    /// 服務（剪髮、染髮、私人教練一堂）：有時間長度、可以指定服務人員
    case service
    /// 課程卡、會籍（10 次剪髮卡、月卡、20 堂瑜珈）：賣出後記在客人身上，之後用次數抵
    case pass
    /// 儲值（儲 NT$10,000 送 NT$1,000）：賣出後加到客人的儲值金
    case storedValue

    public var label: String {
        switch self {
        case .goods: "商品"
        case .service: "服務"
        case .pass: "課程卡／會籍"
        case .storedValue: "儲值"
        }
    }

    /// 賣出後要記在會員身上（一定要先找到會員）
    public var needsMember: Bool { self == .pass || self == .storedValue }
}

/// 規格（款式的一個顏色＋尺寸）：自己的條碼、庫存，價格可以不一樣
public struct ItemVariant: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// 照品項的 optionNames 排：["黑", "M"]
    public var options: [String]
    public var sku: String?
    /// 吊牌條碼（掃到直接加這個規格）
    public var barcode: String?
    /// 沒有就用品項的價格
    public var price: Money?
    /// 這家門市還有幾件（沒有管庫存就是 nil）
    public var stock: Int?
    public var isAvailable: Bool
    /// 網路商店的規格（賣出扣同一份庫存）
    public var productVariantId: String?

    public init(id: String, options: [String], sku: String? = nil, barcode: String? = nil, price: Money? = nil, stock: Int? = nil,
                isAvailable: Bool = true, productVariantId: String? = nil) {
        self.id = id; self.options = options; self.sku = sku; self.barcode = barcode; self.price = price; self.stock = stock
        self.isAvailable = isAvailable; self.productVariantId = productVariantId
    }

    /// 「黑・M」
    public var label: String { options.joined(separator: "・") }
}

/// 課程卡／會籍的規則（後台設定；賣出時抄一份到單子上）
public struct PassSpec: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// 次數卡：10 次剪髮、20 堂課（用一次扣一次）
        case visits
        /// 期間會籍：月卡、年卡（期間內不限次數）
        case period
    }

    public var kind: Kind
    /// 次數卡的次數
    public var visits: Int?
    /// 幾天內有效（次數卡也可以有期限；nil = 不限）
    public var validDays: Int?
    /// 可以抵哪些品項（服務）
    public var itemIds: [String]
    /// 可以抵哪些分類的品項
    public var categoryIds: [String]
    /// 健身房入場報到時用這張（月卡、次數卡）
    public var checkIn: Bool

    public init(kind: Kind, visits: Int? = nil, validDays: Int? = nil, itemIds: [String] = [], categoryIds: [String] = [], checkIn: Bool = false) {
        self.kind = kind; self.visits = visits; self.validDays = validDays; self.itemIds = itemIds; self.categoryIds = categoryIds; self.checkIn = checkIn
    }

    /// 這張卡能不能抵這個品項
    public func covers(itemId: String?, categoryId: String?) -> Bool {
        if let itemId, itemIds.contains(itemId) { return true }
        if let categoryId, categoryIds.contains(categoryId) { return true }
        return false
    }

    /// 「10 次・180 天」「30 天不限次數」
    public var summary: String {
        var parts: [String] = []
        switch kind {
        case .visits: parts.append("\(visits ?? 0) 次")
        case .period: parts.append(validDays.map { "\($0) 天不限次數" } ?? "不限次數")
        }
        if kind == .visits, let d = validDays { parts.append("\(d) 天內") }
        return parts.joined(separator: "・")
    }
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

    // 以下是非餐飲業用的欄位，後台沒給（舊版後台、餐廳）就是 nil：一般商品、沒有規格

    /// 種類（nil = 一般商品）
    public var kind: ItemKind?
    /// 規格的維度：["顏色", "尺寸"]
    public var optionNames: [String]?
    /// 規格（服飾的每個顏色＋尺寸）
    public var variants: [ItemVariant]?
    /// 服務要多久（排預約用）
    public var durationMinutes: Int?
    /// 課程卡／會籍的規則（kind == .pass）
    public var pass: PassSpec?
    /// 儲值進去的金額（kind == .storedValue；儲 10,000 送 1,000 → 11,000）
    public var credit: Money?
    /// 抽成（萬分比；nil = 用服務人員自己的抽成）
    public var commissionBps: Int?

    public init(
        id: String, categoryId: String, name: String, shortName: String? = nil, price: Money, openPrice: Bool = false,
        barcode: String? = nil, plu: String? = nil, modifierGroupIds: [String] = [], station: String? = nil,
        taxKind: TaxKind = .taxable, isAvailable: Bool = true, unit: String = "份", imageURL: String? = nil,
        sortOrder: Int = 0, productId: String? = nil, variantId: String? = nil, stock: Int? = nil,
        kind: ItemKind? = nil, optionNames: [String]? = nil, variants: [ItemVariant]? = nil, durationMinutes: Int? = nil,
        pass: PassSpec? = nil, credit: Money? = nil, commissionBps: Int? = nil
    ) {
        self.id = id; self.categoryId = categoryId; self.name = name; self.shortName = shortName; self.price = price
        self.openPrice = openPrice; self.barcode = barcode; self.plu = plu; self.modifierGroupIds = modifierGroupIds
        self.station = station; self.taxKind = taxKind; self.isAvailable = isAvailable; self.unit = unit
        self.imageURL = imageURL; self.sortOrder = sortOrder; self.productId = productId; self.variantId = variantId; self.stock = stock
        self.kind = kind; self.optionNames = optionNames; self.variants = variants; self.durationMinutes = durationMinutes
        self.pass = pass; self.credit = credit; self.commissionBps = commissionBps
    }

    public var itemKind: ItemKind { kind ?? .goods }
    /// 有規格：點的時候先選顏色尺寸
    public var hasVariants: Bool { !(variants ?? []).isEmpty }
    public var activeVariants: [ItemVariant] { variants ?? [] }

    public func variant(_ id: String?) -> ItemVariant? {
        guard let id else { return nil }
        return variants?.first { $0.id == id }
    }

    /// 這個規格的價格
    public func price(of variant: ItemVariant?) -> Money { variant?.price ?? price }

    /// 規格的某一個維度有哪些值（照後台排的順序、不重複）：顏色 → [黑, 白, 卡其]
    public func optionValues(_ dimension: Int) -> [String] {
        var seen: [String] = []
        for v in activeVariants where dimension < v.options.count {
            let o = v.options[dimension]
            if !seen.contains(o) { seen.append(o) }
        }
        return seen
    }

    /// 選了這些值對到哪一個規格（服飾的顏色 × 尺寸表）
    public func variant(matching options: [String]) -> ItemVariant? {
        activeVariants.first { $0.options == options }
    }

    /// 所有規格加起來的庫存（有任何一個沒管庫存就是 nil）
    public var totalStock: Int? {
        guard hasVariants else { return stock }
        var sum = 0
        for v in activeVariants {
            guard let s = v.stock else { return nil }
            sum += s
        }
        return sum
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
    public func lookup(code: String) -> MenuItem? { match(code: code)?.item }

    /// 掃描器、品號找到的品項與規格（掃吊牌直接是那個顏色尺寸）
    public struct Match: Sendable, Hashable {
        public var item: MenuItem
        public var variant: ItemVariant?
    }

    public func match(code: String) -> Match? {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return nil }
        if let i = items.first(where: { $0.barcode == c }) { return Match(item: i, variant: nil) }
        for i in items {
            if let v = i.variants?.first(where: { $0.barcode == c || $0.sku == c }) { return Match(item: i, variant: v) }
        }
        if let i = items.first(where: { $0.plu == c }) { return Match(item: i, variant: nil) }
        return nil
    }

    /// 課程卡能抵的品項
    public func items(coveredBy pass: PassSpec) -> [MenuItem] {
        items.filter { pass.covers(itemId: $0.id, categoryId: $0.categoryId) }
    }

    /// 搜尋：名字、短名、品號、條碼（不分大小寫；中文直接比對子字串）
    public func search(_ query: String) -> [MenuItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return items.filter { item in
            item.name.lowercased().contains(q) || (item.shortName?.lowercased().contains(q) ?? false)
                || item.plu == q || item.barcode == q
                || (item.variants ?? []).contains { $0.sku?.lowercased() == q || $0.barcode == q }
        }
    }

    /// 品項出單站：品項自己的 → 分類的 → nil（不出單）
    public func station(for item: MenuItem) -> String? {
        item.station ?? category(item.categoryId)?.station
    }
}
