import Foundation

/// 右側鍵盤待機時打的一串數字是什麼（打完停一下就照這個自動做，不用再按鍵）：
///
///   1–3 碼              數量（打 3 再點品項＝3 份）
///   09 開頭、還沒滿 10 碼  會員電話打到一半（等打完）
///   09 開頭 10 碼        會員電話 → 停一下就查、掛到這張單（菜單剛好有這個品號的話算商品）
///   8 碼、統編檢查碼對     結帳中：買方統編（不在結帳就當品號）
///   剛好對到菜單、而且沒有更長的品號是它開頭的   商品 → 停一下就加入
///   其他                 品號（還沒打完）；按「確定」時對不到品號就當金額（TypedConfirm）
///
/// 條碼機打進來的不走這裡（打得很快、最後有 Enter：整串直接當掃到的，見 ScanCode）
public enum TypedDigits: Sendable, Hashable {
    case quantity(Int)
    /// 09 開頭還沒打滿 10 碼
    case partialPhone(String)
    case member(phone: String)
    case taxId(String)
    case product(Catalog.Match)
    case code(String)

    public static func classify(_ digits: String, catalog: Catalog, atCheckout: Bool) -> TypedDigits? {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        if digits.count <= 3, let n = Int(digits), n > 0, !digits.hasPrefix("0") { return .quantity(min(n, 999)) }
        if let m = catalog.match(code: digits), !catalog.hasLongerCode(startingWith: digits) { return .product(m) }
        if digits.hasPrefix("09") {
            if digits.count < 10 { return .partialPhone(digits) }
            if digits.count == 10 { return .member(phone: digits) }
        }
        if atCheckout, digits.count == 8, InvoiceValidation.isTaxId(digits) { return .taxId(digits) }
        return .code(digits)
    }

    /// 停一下就自動做的（會員、統編、對到的商品）；其他的等使用者
    public var actsOnPause: Bool {
        switch self {
        case .member, .taxId, .product: true
        case .quantity, .partialPhone, .code: false
        }
    }
}

/// 待機打了數字、按「確定」：打完了，照這個做（停一下才自動做的不用再等）
///
///   對到品號、條碼            商品（3 碼以內的品號也是：按確定就不是數量了）
///   09 開頭 10 碼             會員電話
///   沒有這個品號、1–6 位數     就是多少錢：加一筆這個金額（「其他」）
///   其他（0 開頭、7 碼以上）   找不到品號（多半是打錯的條碼，不當錢）
public enum TypedConfirm: Sendable, Hashable {
    case product(Catalog.Match)
    case member(phone: String)
    case amount(Money)
    case notFound(String)

    /// 最多幾位數當金額（再長的是條碼打錯，不是錢）
    public static let maxAmountDigits = 6

    public static func classify(_ digits: String, catalog: Catalog) -> TypedConfirm? {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        if let m = catalog.match(code: digits) { return .product(m) }
        if digits.hasPrefix("09"), digits.count == 10 { return .member(phone: digits) }
        if !digits.hasPrefix("0"), digits.count <= maxAmountDigits, let n = Int(digits), n > 0 { return .amount(Money(dollars: n)) }
        return .notFound(digits)
    }
}

extension Catalog {
    /// 有沒有更長的品號、條碼、SKU 是這串數字開頭的（有的話還不能確定是哪一個：等打完）
    public func hasLongerCode(startingWith prefix: String) -> Bool {
        items.contains { item in
            let codes = [item.plu, item.barcode] + (item.variants ?? []).flatMap { [$0.barcode, $0.sku] }
            return codes.contains { c in
                guard let c else { return false }
                return c.count > prefix.count && c.hasPrefix(prefix)
            }
        }
    }
}
