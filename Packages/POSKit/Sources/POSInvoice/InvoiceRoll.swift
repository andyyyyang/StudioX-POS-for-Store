import Foundation
import POSCore

/// 一段發票號碼（後台從這一期的字軌配給這台 iPad 的「一本」，通常 50 張）。
///
/// 為什麼要先配號：好幾台 iPad 同時開發票、又可能斷網，號碼不能撞。後台把字軌切成一段一段，每台只用自己那段，
/// 所以完全不用連線就能開；剩不多時（預設 10 張）連上網就自動再要一段。
public struct InvoiceRoll: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 期別（11510）
    public var period: String
    /// 字軌（兩個大寫英文）
    public var track: String
    /// 起號（含）
    public var start: Int
    /// 迄號（含）
    public var end: Int

    public init(id: String, period: String, track: String, start: Int, end: Int) {
        self.id = id; self.period = period; self.track = track; self.start = start; self.end = end
    }

    public var count: Int { end - start + 1 }
    public func contains(_ n: Int) -> Bool { (start...end).contains(n) }
    public func number(_ n: Int) -> String { track + String(format: "%08d", n) }
    /// AB-12345650 ~ AB-12345699
    public var label: String { "\(track)-\(String(format: "%08d", start)) ~ \(track)-\(String(format: "%08d", end))" }

    /// AB12345678 → ("AB", 12345678)
    public static func parse(_ number: String) -> (track: String, n: Int)? {
        guard number.count == 10, let n = Int(number.suffix(8)) else { return nil }
        let track = String(number.prefix(2))
        guard track.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return (track, n)
    }
}

/// 下一張發票號碼：照號碼段順序、段內照順序，一張都不跳。
/// 用過哪些號碼從事件算（StoreState.invoices），不另外存：事件日誌是唯一的真相，重裝 App 補回事件就知道用到哪裡
public struct InvoiceAllocator: Sendable {
    public var rolls: [InvoiceRoll]
    public var used: Set<String>

    public init(rolls: [InvoiceRoll], used: some Sequence<String>) {
        self.rolls = rolls.sorted { ($0.period, $0.track, $0.start) < ($1.period, $1.track, $1.start) }
        self.used = Set(used)
    }

    public init(rolls: [InvoiceRoll], state: StoreState) {
        self.init(rolls: rolls, used: state.invoices.keys)
    }

    /// 這一段用到哪裡（下一張是幾號；用完了回 nil）
    public func next(in roll: InvoiceRoll) -> Int? {
        let usedHere = used.compactMap { InvoiceRoll.parse($0) }.filter { $0.track == roll.track && roll.contains($0.n) }.map(\.n)
        let next = (usedHere.max() ?? roll.start - 1) + 1
        return next <= roll.end ? next : nil
    }

    /// 下一張號碼（這一期沒有可用的號碼段回 nil）
    public func next(period: InvoicePeriod) -> (number: String, roll: InvoiceRoll)? {
        for roll in rolls where roll.period == period.code {
            if let n = next(in: roll) { return (roll.number(n), roll) }
        }
        return nil
    }

    public mutating func markUsed(_ number: String) { used.insert(number) }

    /// 這一期還剩幾張
    public func remaining(period: InvoicePeriod) -> Int {
        rolls.filter { $0.period == period.code }.reduce(0) { sum, roll in
            guard let n = next(in: roll) else { return sum }
            return sum + (roll.end - n + 1)
        }
    }

    /// 剩不多了，連上網就要一段新的
    public func needsMore(period: InvoicePeriod, threshold: Int = 10) -> Bool { remaining(period: period) < threshold }

    /// 期末沒用到的號碼（要報「空白未使用字軌」）：每一段從下一張到迄號
    public func blankRanges(period: InvoicePeriod) -> [(track: String, start: Int, end: Int)] {
        rolls.filter { $0.period == period.code }.compactMap { roll in
            guard let n = next(in: roll) else { return nil }
            return (roll.track, n, roll.end)
        }
    }
}
