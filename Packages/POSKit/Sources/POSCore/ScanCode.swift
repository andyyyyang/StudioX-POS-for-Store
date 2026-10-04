import Foundation

/// 掃到的一串字是什麼（手機用相機掃、iPad 的外接條碼機打進來的；docs/API.md「掃碼」）。
///
/// 一個「掃碼」鍵就好：App 照內容判斷——
///
///   載具      `/` 開頭 8 碼（手機條碼）、2 個英文＋14 個數字（自然人憑證）
///   商品      品號、條碼、SKU 剛好對到菜單（`Catalog.match`）
///   會員      裡面有一段 `09` 開頭 10 碼的手機號碼（會員卡的條碼／QR 就是手機號碼；網址 `…?phone=0912…`、`+886 912…` 也行）。
///             前後還連著數字的不算（EAN-13 的 `4710912345678` 是商品條碼，不是電話）
///   折價券    其他看起來像代碼的：轉大寫後是 4–32 個英文、數字、`-`（`YG-A3B2C1`）
///
/// 商品放在會員前面：商品條碼剛好是 `09` 開頭 10 碼時算商品（菜單對得到的一定是商品）。
public enum ScanCode: Sendable, Hashable {
    /// 發票載具（手機條碼、自然人憑證）
    case carrier(InvoiceCarrier)
    /// 會員的手機號碼（0912345678）
    case member(phone: String)
    /// 菜單上的品項（掃吊牌是那個規格）
    case product(Catalog.Match)
    /// 折價券代碼（大寫）
    case coupon(code: String)
    /// 看不懂（太短、中文、空的）
    case unknown(String)

    public static func classify(_ raw: String, catalog: Catalog) -> ScanCode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = carrier(in: trimmed) { return .carrier(c) }
        if let m = catalog.match(code: trimmed) { return .product(m) }
        if let phone = memberPhone(in: trimmed) { return .member(phone: phone) }
        if let code = couponCode(in: trimmed) { return .coupon(code: code) }
        return .unknown(trimmed)
    }

    /// 手機條碼（/ABC+123）、自然人憑證（AB12345678901234）；大小寫不拘（掃描器有時候打成小寫）
    public static func carrier(in raw: String) -> InvoiceCarrier? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if InvoiceValidation.isMobileBarcode(code) { return .mobileBarcode(code) }
        if InvoiceValidation.isCitizenCertificate(code) { return .citizenCertificate(code) }
        return nil
    }

    /// 會員卡上的手機號碼（0912345678）：
    ///   - 整串就是電話（可以有空白、`-`、括號，或 `+886`）
    ///   - 裡面有一段剛好 10 碼、`09` 開頭的數字（網址 `?phone=0912345678`、`member:0912345678`）；`886` 開頭 12 碼的也算
    public static func memberPhone(in raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let compact = s.filter { !" -()".contains($0) }
        if compact.allSatisfy({ isDigit($0) || $0 == "+" }), let p = normalizedPhone(compact.filter(isDigit)) { return p }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard isDigit(chars[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < chars.count, isDigit(chars[j]) { j += 1 }
            if let p = normalizedPhone(String(chars[i..<j])) { return p }
            i = j
        }
        return nil
    }

    /// 折價券代碼：轉大寫、4–32 個英文、數字、`-`；不像的回 nil
    public static func couponCode(in raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (4...32).contains(code.count) else { return nil }
        guard code.allSatisfy({ $0.isASCII && ($0.isUppercase || isDigit($0) || $0 == "-") }) else { return nil }
        // 只有「-」的不算
        guard code.contains(where: { $0 != "-" }) else { return nil }
        return code
    }

    /// 0912345678、886912345678 → 0912345678；其他 nil
    static func normalizedPhone(_ digits: String) -> String? {
        if digits.count == 10, digits.hasPrefix("09") { return digits }
        if digits.count == 12, digits.hasPrefix("8869") { return "0" + digits.dropFirst(3) }
        return nil
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}
