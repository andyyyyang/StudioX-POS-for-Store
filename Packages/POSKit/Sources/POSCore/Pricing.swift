import Foundation

/// 一行在整張單裡實際收多少（整單折扣分攤後）：報表的品項營收、發票的品項金額都用這個
public struct LineAmount: Sendable, Hashable {
    public var lineId: String
    public var gross: Money
    public var lineDiscount: Money
    /// 整單折扣分到這一行的
    public var orderDiscountShare: Money
    public var net: Money { gross - lineDiscount - orderDiscountShare }
}

/// 一張單的金額。算法（全部整數元）：
///
///   品項小計 = Σ (單價＋加料) × 數量            （作廢的不算）
///   單品折扣 = Σ 每一行自己的折扣
///   小計     = 品項小計 − 單品折扣
///   整單折扣 = 小計 × %（或固定金額，不超過小計）→ 依各行金額比例分攤（最大餘數法，分攤加起來剛好等於折扣）
///   服務費   = (小計 − 整單折扣) × 服務費率
///   總計     = 小計 − 整單折扣 + 服務費      ← 發票金額（含 5% 營業稅）
///   應收     = 總計 + 小費                    ← 小費不開發票
public struct TicketTotals: Sendable, Hashable {
    public var itemsGross: Money
    public var lineDiscounts: Money
    public var subtotal: Money
    public var orderDiscount: Money
    public var serviceCharge: Money
    public var total: Money
    public var tip: Money
    public var amountDue: Money
    public var paid: Money
    /// 還要收多少（負數＝收多了）
    public var balance: Money
    /// 含在總計裡的營業稅
    public var tax: Money
    public var lines: [LineAmount]

    public init(_ t: Ticket) {
        let active = t.activeLines
        let grossByLine = active.map { ($0.id, $0.gross, $0.lineDiscount) }
        itemsGross = Money.sum(grossByLine.map(\.1))
        lineDiscounts = Money.sum(grossByLine.map(\.2))
        subtotal = itemsGross - lineDiscounts
        orderDiscount = t.discount?.amount(on: subtotal) ?? .zero

        let shares = Self.allocate(orderDiscount, over: grossByLine.map { $0.1 - $0.2 })
        lines = zip(grossByLine, shares).map { LineAmount(lineId: $0.0.0, gross: $0.0.1, lineDiscount: $0.0.2, orderDiscountShare: $0.1) }

        let discounted = subtotal - orderDiscount
        serviceCharge = discounted.applying(bps: t.serviceChargeBps)
        total = discounted + serviceCharge
        tip = t.tip.roundedToDollar()
        amountDue = total + tip
        paid = Money.sum(t.approvedPayments.map(\.amount))
        balance = amountDue - paid
        tax = Tax.split(inclusive: total).tax
    }

    public var isPaidInFull: Bool { balance.cents <= 0 }
    public var discountTotal: Money { lineDiscounts + orderDiscount }

    /// 把 amount 依 weights 的比例分成整數元（最大餘數法：先分整數、剩下的一元一元給餘數最大的）
    public static func allocate(_ amount: Money, over weights: [Money]) -> [Money] {
        let totalDollars = amount.dollars
        let w = weights.map { max($0.dollars, 0) }
        let sum = w.reduce(0, +)
        guard totalDollars != 0, sum > 0 else { return weights.map { _ in .zero } }
        var base = [Int](repeating: 0, count: w.count)
        var remainders: [(index: Int, rem: Int)] = []
        for (i, wi) in w.enumerated() {
            let product = totalDollars * wi
            base[i] = product / sum
            remainders.append((i, product % sum))
        }
        var left = totalDollars - base.reduce(0, +)
        for r in remainders.sorted(by: { $0.rem != $1.rem ? $0.rem > $1.rem : $0.index < $1.index }) where left > 0 {
            base[r.index] += 1
            left -= 1
        }
        return base.map { Money(dollars: $0) }
    }

    /// 平均分攤（拆帳「平分」）：1000 分 3 → 334、333、333
    public static func split(_ amount: Money, ways: Int) -> [Money] {
        guard ways > 0 else { return [] }
        return allocate(amount, over: [Money](repeating: Money(dollars: 1), count: ways))
    }
}

/// 找零建議：客人可能給的整數鈔票（右側鍵盤上面那排快速鍵）
public enum CashSuggestions {
    public static func amounts(for due: Money, presets: [Money]) -> [Money] {
        let d = due.dollars
        guard d > 0 else { return [] }
        var out: [Int] = [d]
        for step in [10, 50, 100, 500, 1000] {
            let up = ((d + step - 1) / step) * step
            if up > d && !out.contains(up) { out.append(up) }
        }
        for p in presets.map(\.dollars) where p > d && !out.contains(p) { out.append(p) }
        return Array(out.sorted().prefix(5)).map { Money(dollars: $0) }
    }
}
