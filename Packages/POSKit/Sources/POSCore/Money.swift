import Foundation

/// 金額：以「分」存（NT$1,280 = 128000），和後台 atelier-cms 的資料庫一樣。
///
/// 新台幣實際只收整數元，所以**所有算出來的金額**（折扣、服務費、稅、找零）都經過 `roundedToDollar()`
/// 再存進單子；分只是讓後台、匯出、加總不會因為單位不同出錯。
public struct Money: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var cents: Int

    public init(cents: Int) { self.cents = cents }
    public init(dollars: Int) { self.cents = dollars * 100 }

    public static let zero = Money(cents: 0)

    /// 整數元（四捨五入）
    public var dollars: Int { roundedToDollar().cents / 100 }

    /// 四捨五入到整數元（負數對稱：−0.5 元 → −1 元）
    public func roundedToDollar() -> Money {
        let q = cents / 100, r = cents % 100
        if r >= 50 { return Money(cents: (q + 1) * 100) }
        if r <= -50 { return Money(cents: (q - 1) * 100) }
        return Money(cents: q * 100)
    }

    public var isZero: Bool { cents == 0 }
    public var isNegative: Bool { cents < 0 }

    public static func + (a: Money, b: Money) -> Money { Money(cents: a.cents + b.cents) }
    public static func - (a: Money, b: Money) -> Money { Money(cents: a.cents - b.cents) }
    public static func * (a: Money, n: Int) -> Money { Money(cents: a.cents * n) }
    public static func * (n: Int, a: Money) -> Money { Money(cents: a.cents * n) }
    public static prefix func - (a: Money) -> Money { Money(cents: -a.cents) }
    public static func += (a: inout Money, b: Money) { a.cents += b.cents }
    public static func -= (a: inout Money, b: Money) { a.cents -= b.cents }
    public static func < (a: Money, b: Money) -> Bool { a.cents < b.cents }

    /// 乘上萬分比（bps：1000 = 10%），四捨五入到整數元
    public func applying(bps: Int) -> Money {
        // 先用分算到精確，再一次四捨五入，避免兩次捨入的誤差
        let raw = Double(cents) * Double(bps) / 10_000
        return Money(cents: Int(raw.rounded(.toNearestOrAwayFromZero))).roundedToDollar()
    }

    public static func sum<S: Sequence>(_ items: S) -> Money where S.Element == Money {
        items.reduce(.zero, +)
    }

    // MARK: 顯示

    /// NT$1,280（負數：−NT$120）
    public var formatted: String { Money.format(self, prefix: "NT$") }
    /// $1,280：收據、按鈕這種窄的地方
    public var short: String { Money.format(self, prefix: "$") }
    /// 1,280：表格裡已經標了單位
    public var plain: String { Money.group(abs(dollars)).withSign(dollars < 0) }

    public var description: String { formatted }

    // JSON 裡就是一個整數（分），和後台資料庫的欄位一樣
    public init(from decoder: Decoder) throws {
        cents = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(cents)
    }

    static func format(_ m: Money, prefix: String) -> String {
        let d = m.dollars
        return (d < 0 ? "−" : "") + prefix + group(abs(d))
    }

    /// 千分位（不靠 NumberFormatter：Linux 與 iOS 的地區設定不同，收據要一模一樣）
    public static func group(_ n: Int) -> String {
        let s = String(n)
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}

private extension String {
    func withSign(_ negative: Bool) -> String { negative ? "−" + self : self }
}

/// 稅：台灣的定價都是含稅（5% 營業稅）。
public enum Tax {
    /// 一般稅率 5%（萬分比）
    public static let standardRateBps = 500

    /// 含稅總額拆出未稅銷售額與稅額：銷售額 = round(總額 ÷ 1.05)，稅額 = 總額 − 銷售額（整數元）。
    /// 統一發票（B2B）就印這兩個數字；B2C 的證明聯只印總計。
    public static func split(inclusive total: Money, rateBps: Int = standardRateBps) -> (sales: Money, tax: Money) {
        let t = total.roundedToDollar()
        guard rateBps > 0 else { return (t, .zero) }
        let dollars = Double(t.dollars) * 10_000 / Double(10_000 + rateBps)
        let sales = Money(dollars: Int(dollars.rounded(.toNearestOrAwayFromZero)))
        return (sales, t - sales)
    }
}

/// 萬分比的顯示：1000 → 10%，1250 → 12.5%
public func percentText(bps: Int) -> String {
    if bps % 100 == 0 { return "\(bps / 100)%" }
    let whole = bps / 100, frac = abs(bps % 100)
    let fracText = frac % 10 == 0 ? "\(frac / 10)" : (frac < 10 ? "0\(frac)" : "\(frac)")
    return "\(whole).\(fracText)%"
}
