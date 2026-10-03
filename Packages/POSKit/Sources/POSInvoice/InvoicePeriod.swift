import Foundation
import POSCore

/// 發票期別：兩個月一期（1–2、3–4、…、11–12 月），用民國年＋雙數月表示：11510 = 115 年 9–10 月
public struct InvoicePeriod: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public var rocYear: Int
    /// 雙數月（2、4、6、8、10、12）
    public var endMonth: Int

    public init(rocYear: Int, endMonth: Int) {
        self.rocYear = rocYear
        self.endMonth = endMonth % 2 == 0 ? endMonth : endMonth + 1
    }

    /// 這個時間（台北）所在的期別
    public init(date: Date) {
        let c = TaipeiTime.components(date)
        let m = c.month ?? 1
        self.init(rocYear: (c.year ?? 2026) - 1911, endMonth: m % 2 == 0 ? m : m + 1)
    }

    /// "11510"
    public init?(code: String) {
        guard code.count == 5, let y = Int(code.prefix(3)), let m = Int(code.suffix(2)), m % 2 == 0, (2...12).contains(m) else { return nil }
        self.init(rocYear: y, endMonth: m)
    }

    /// 11510（一維條碼、QR Code、API 都用這個）
    public var code: String { String(format: "%03d%02d", rocYear, endMonth) }
    /// 115年09-10月（證明聯上的字）
    public var label: String { String(format: "%d年%02d-%02d月", rocYear, endMonth - 1, endMonth) }
    public var description: String { code }

    public var next: InvoicePeriod { endMonth == 12 ? InvoicePeriod(rocYear: rocYear + 1, endMonth: 2) : InvoicePeriod(rocYear: rocYear, endMonth: endMonth + 2) }
    public var previous: InvoicePeriod { endMonth == 2 ? InvoicePeriod(rocYear: rocYear - 1, endMonth: 12) : InvoicePeriod(rocYear: rocYear, endMonth: endMonth - 2) }

    public static func < (a: InvoicePeriod, b: InvoicePeriod) -> Bool { (a.rocYear, a.endMonth) < (b.rocYear, b.endMonth) }

    /// 這一期最後一刻（台北時間雙數月最後一天 23:59:59）
    public var endsAt: Date {
        var c = DateComponents()
        c.year = rocYear + 1911 + (endMonth == 12 ? 1 : 0)
        c.month = endMonth == 12 ? 1 : endMonth + 1
        c.day = 1
        let start = TaipeiTime.calendar.date(from: c) ?? .distantFuture
        return start.addingTimeInterval(-1)
    }
}

/// 民國年的日期：1151003（QR Code 用的 7 碼）
public enum ROCDate {
    public static func compact(_ date: Date) -> String {
        let c = TaipeiTime.components(date)
        return String(format: "%03d%02d%02d", (c.year ?? 2026) - 1911, c.month ?? 1, c.day ?? 1)
    }

    /// 20261003（MIG 的 InvoiceDate 是西元年）
    public static func gregorian(_ date: Date) -> String { TaipeiTime.dayString(date).replacingOccurrences(of: "-", with: "") }
}
