import Foundation

/// 錢櫃的進出（不是收款）
public enum CashMoveKind: String, Codable, Sendable, Hashable {
    /// 存入零用金
    case payIn
    /// 取出（買菜、付廠商）
    case payOut
    /// 只開錢櫃（換零錢），金額 0
    case noSale

    public var label: String {
        switch self {
        case .payIn: "存入"
        case .payOut: "取出"
        case .noSale: "開錢櫃"
        }
    }
}

public struct CashMove: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: CashMoveKind
    public var amount: Money
    public var reason: String
    public var at: Date
    public var by: String
    public var authorizedBy: String?

    public init(id: String, kind: CashMoveKind, amount: Money, reason: String, at: Date, by: String, authorizedBy: String? = nil) {
        self.id = id; self.kind = kind; self.amount = amount; self.reason = reason; self.at = at; self.by = by; self.authorizedBy = authorizedBy
    }

    /// 對錢櫃的影響（存入＋、取出−）
    public var signed: Money {
        switch kind {
        case .payIn: amount
        case .payOut: -amount
        case .noSale: .zero
        }
    }
}

/// 新台幣的面額（交班點錢：每種幾張／幾個，用右側鍵盤一格一格輸入）
public enum Denomination: Int, Codable, Sendable, CaseIterable, Hashable {
    case d2000 = 2000, d1000 = 1000, d500 = 500, d200 = 200, d100 = 100, d50 = 50, d10 = 10, d5 = 5, d1 = 1

    public var value: Money { Money(dollars: rawValue) }
    public var isCoin: Bool { rawValue <= 50 }
    public var label: String { "\(rawValue) 元" }
    /// 平常會用到的（2000、200 很少見，交班畫面收在「更多」）
    public static let common: [Denomination] = [.d1000, .d500, .d100, .d50, .d10, .d5, .d1]
}

public struct CashCount: Codable, Sendable, Hashable {
    /// 面額（"1000"）→ 張數。key 用字串：JSON 才會是物件（Swift 的 [Int: Int] 會編成陣列）
    public var counts: [String: Int]

    public init(counts: [String: Int] = [:]) { self.counts = counts }

    public var total: Money {
        Money.sum(counts.map { Money(dollars: (Int($0.key) ?? 0) * $0.value) })
    }

    public func count(_ d: Denomination) -> Int { counts[String(d.rawValue)] ?? 0 }
    public mutating func set(_ d: Denomination, _ n: Int) { counts[String(d.rawValue)] = max(n, 0) }
}

/// 一班（一台收銀機的錢櫃，從開班到交班）
public struct Shift: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var deviceId: String
    public var openedAt: Date
    public var openedBy: String
    /// 開班時錢櫃裡的零用金
    public var openingCash: Money
    public var moves: [CashMove]
    public var closedAt: Date?
    public var closedBy: String?
    /// 交班時點到的現金
    public var counted: CashCount?
    /// 交班時算出應有的現金（存下來：之後就算退款改到這班的資料，交班單上的數字也不會變）
    public var expectedAtClose: Money?
    public var note: String
    public var businessDate: String

    public init(id: String, deviceId: String, openedAt: Date, openedBy: String, openingCash: Money, moves: [CashMove] = [],
                closedAt: Date? = nil, closedBy: String? = nil, counted: CashCount? = nil, expectedAtClose: Money? = nil,
                note: String = "", businessDate: String) {
        self.id = id; self.deviceId = deviceId; self.openedAt = openedAt; self.openedBy = openedBy; self.openingCash = openingCash
        self.moves = moves; self.closedAt = closedAt; self.closedBy = closedBy; self.counted = counted
        self.expectedAtClose = expectedAtClose; self.note = note; self.businessDate = businessDate
    }

    public var isOpen: Bool { closedAt == nil }
}

/// 上下班打卡
public struct ClockEntry: Codable, Sendable, Hashable {
    public var staffId: String
    public var inAt: Date
    public var outAt: Date?

    public init(staffId: String, inAt: Date, outAt: Date? = nil) {
        self.staffId = staffId; self.inAt = inAt; self.outAt = outAt
    }

    public func minutes(now: Date) -> Int { Int(((outAt ?? now).timeIntervalSince(inAt) / 60).rounded(.down)) }
}
