import Foundation

// 會員帳戶：儲值金、課程卡（次數）、會籍（期間）。
//
// 帳戶的變動不是另外記的：都是從事件推出來的（結帳時賣了儲值／課程卡、用儲值金付、用課程卡抵、退款、入場報到），
// 規則只有這一份（AccountRules），iPad 與後台照同樣的規則算，所以兩邊的餘額一定一樣。
//
// 餘額的真相在後台（所有門市、所有 iPad 的事件都在那裡）。iPad 查會員時拿到後台的餘額，
// 再加上「這台已經記了、但後台那份還沒算進去」的事件（後台回傳它算過哪些事件 id），就是現在的餘額——斷網也對。
// 兩台 iPad 都斷網、同一個客人在兩邊各扣一次，可能扣成負的：後台收到時照記、標出來給店長處理（不吞掉）。

/// 會員身上的一張課程卡或會籍
public struct MemberPass: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case active
        /// 次數用完
        case usedUp
        case expired
        /// 退款作廢
        case cancelled
    }

    /// 賣出那一行的 id（一次買 2 張：lineId#1、lineId#2）
    public var id: String
    public var name: String
    public var spec: PassSpec
    /// 次數卡剩幾次（期間會籍是 nil）
    public var remaining: Int?
    public var startsAt: Date
    public var expiresAt: Date?
    /// 賣出這張的單
    public var ticketId: String?
    /// 每次的價值（卡價 ÷ 次數；用卡抵的服務算業績用）
    public var unitValue: Money
    public var status: Status

    public init(id: String, name: String, spec: PassSpec, remaining: Int?, startsAt: Date, expiresAt: Date?, ticketId: String? = nil,
                unitValue: Money = .zero, status: Status = .active) {
        self.id = id; self.name = name; self.spec = spec; self.remaining = remaining; self.startsAt = startsAt
        self.expiresAt = expiresAt; self.ticketId = ticketId; self.unitValue = unitValue; self.status = status
    }

    /// 現在能不能用（有效期內、還有次數）
    public func isUsable(at date: Date) -> Bool {
        guard status == .active else { return false }
        if date < startsAt { return false }
        if let e = expiresAt, date >= e { return false }
        if spec.kind == .visits { return (remaining ?? 0) > 0 }
        return true
    }

    /// 畫面上的狀態：「剩 7 次・到 2027/4/3」「有效到 11/3」「已過期」
    public func statusText(at date: Date) -> String {
        switch status {
        case .cancelled: return "已退費"
        case .usedUp: return "已用完"
        case .expired: return "已過期"
        case .active: break
        }
        if let e = expiresAt, date >= e { return "已過期" }
        if date < startsAt { return "\(Self.short(startsAt)) 開始" }
        var parts: [String] = []
        if spec.kind == .visits { parts.append("剩 \(remaining ?? 0) 次") }
        if let e = expiresAt { parts.append("到 \(Self.short(e.addingTimeInterval(-1)))") }
        return parts.isEmpty ? "有效" : parts.joined(separator: "・")
    }

    /// 還有幾天到期（沒有期限是 nil）
    public func daysLeft(at date: Date) -> Int? {
        guard let e = expiresAt else { return nil }
        return Int((e.timeIntervalSince(date) / 86_400).rounded(.up))
    }

    static func short(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0)"
    }
}

/// 帳戶的一筆變動
public struct AccountMove: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// 儲值金加（儲值、退款退回儲值金）
        case walletCredit
        /// 儲值金扣（用儲值金付、退掉儲值）
        case walletDebit
        /// 新的一張課程卡／會籍
        case passIssued
        /// 扣次數（用卡抵服務、入場報到）
        case passUsed
        /// 還次數（退款、取消報到）
        case passRestored
        /// 整張作廢（退掉課程卡）
        case passCancelled
    }

    public var kind: Kind
    public var memberId: String
    /// 儲值金的金額
    public var amount: Money?
    /// 新的卡（passIssued）
    public var pass: MemberPass?
    public var passId: String?
    /// 扣／還幾次
    public var count: Int?
    public var ticketId: String?
    public var at: Date

    public init(kind: Kind, memberId: String, amount: Money? = nil, pass: MemberPass? = nil, passId: String? = nil, count: Int? = nil,
                ticketId: String? = nil, at: Date) {
        self.kind = kind; self.memberId = memberId; self.amount = amount; self.pass = pass; self.passId = passId
        self.count = count; self.ticketId = ticketId; self.at = at
    }
}

/// 一個會員的帳戶
public struct MemberAccount: Codable, Sendable, Hashable {
    /// 儲值金餘額
    public var wallet: Money
    public var passes: [MemberPass]

    public init(wallet: Money = .zero, passes: [MemberPass] = []) {
        self.wallet = wallet; self.passes = passes
    }

    public static let empty = MemberAccount()

    public mutating func apply(_ m: AccountMove) {
        switch m.kind {
        case .walletCredit: wallet += m.amount ?? .zero
        case .walletDebit: wallet -= m.amount ?? .zero
        case .passIssued:
            if let p = m.pass, !passes.contains(where: { $0.id == p.id }) { passes.append(p) }
        case .passUsed, .passRestored:
            guard let id = m.passId, let i = passes.firstIndex(where: { $0.id == id }) else { return }
            guard passes[i].spec.kind == .visits else { return }
            let n = (m.count ?? 1) * (m.kind == .passUsed ? -1 : 1)
            let left = (passes[i].remaining ?? 0) + n
            passes[i].remaining = left
            if passes[i].status != .cancelled && passes[i].status != .expired {
                passes[i].status = left <= 0 ? .usedUp : .active
            }
        case .passCancelled:
            guard let id = m.passId, let i = passes.firstIndex(where: { $0.id == id }) else { return }
            passes[i].status = .cancelled
        }
    }

    public func applying(_ moves: [AccountMove]) -> MemberAccount {
        var a = self
        for m in moves { a.apply(m) }
        return a
    }

    /// 現在能用的卡（快到期的排前面）
    public func usablePasses(at date: Date) -> [MemberPass] {
        passes.filter { $0.isUsable(at: date) }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// 能抵這個品項的卡
    public func passes(covering itemId: String?, categoryId: String?, at date: Date) -> [MemberPass] {
        usablePasses(at: date).filter { $0.spec.covers(itemId: itemId, categoryId: categoryId) }
    }

    /// 入場報到能用的卡（期間會籍優先：不扣次數）
    public func checkInPasses(at date: Date) -> [MemberPass] {
        usablePasses(at: date).filter(\.spec.checkIn).sorted { a, b in
            if a.spec.kind != b.spec.kind { return a.spec.kind == .period }
            return (a.expiresAt ?? .distantFuture) < (b.expiresAt ?? .distantFuture)
        }
    }

    /// 續約的開始日：同一種會籍（同名、或都是入場用的期間會籍）還有效的話，新的接在最晚的到期日後面；沒有就是 nil（從今天開始）
    public func renewalStart(name: String, spec: PassSpec, at date: Date) -> Date? {
        guard spec.kind == .period else { return nil }
        return passes
            .filter { $0.status == .active && $0.spec.kind == .period && ($0.name == name || ($0.spec.checkIn && spec.checkIn)) }
            .compactMap(\.expiresAt)
            .filter { $0 > date }
            .max()
    }
}

/// 事件 → 帳戶變動（iPad 與後台共用的規則；後台照 docs/API.md「會員帳戶」一節實作同樣的算法）
public enum AccountRules {
    /// 次數卡一次的價值：實收 ÷ 次數（整數元，四捨五入）；會籍：實收
    public static func unitValue(net: Money, quantity: Int, spec: PassSpec) -> Money {
        let each = quantity > 0 ? net.dollars / quantity : net.dollars
        guard spec.kind == .visits, let v = spec.visits, v > 0 else { return Money(dollars: each) }
        return Money(dollars: Int((Double(each) / Double(v)).rounded()))
    }

    /// 結帳
    public static func moves(sale: SaleRecord) -> [AccountMove] {
        guard let memberId = sale.member?.id else { return [] }
        var out: [AccountMove] = []
        let at = sale.closedAt
        for l in sale.lines {
            switch l.kind ?? .goods {
            case .storedValue:
                let credit = (l.credit ?? l.unitPrice) * l.quantity
                if credit.cents > 0 { out.append(AccountMove(kind: .walletCredit, memberId: memberId, amount: credit, ticketId: sale.ticketId, at: at)) }
            case .pass:
                guard let spec = l.pass else { continue }
                for k in 0..<max(l.quantity, 0) {
                    let start = l.passStartsAt ?? at
                    let expires = spec.validDays.map { TaipeiTime.endOfDay(start, plusDays: $0) }
                    let p = MemberPass(id: passId(lineId: l.lineId, index: k, quantity: l.quantity), name: l.name, spec: spec,
                                       remaining: spec.kind == .visits ? spec.visits : nil, startsAt: start, expiresAt: expires,
                                       ticketId: sale.ticketId, unitValue: unitValue(net: l.net, quantity: l.quantity, spec: spec))
                    out.append(AccountMove(kind: .passIssued, memberId: memberId, pass: p, passId: p.id, ticketId: sale.ticketId, at: at))
                }
            case .goods, .service:
                break
            }
            if let r = l.redeem {
                out.append(AccountMove(kind: .passUsed, memberId: memberId, passId: r.passId, count: l.quantity, ticketId: sale.ticketId, at: at))
            }
        }
        let prepaid = Money.sum(sale.payments.filter { $0.tender == .prepaid }.map(\.amount))
        if prepaid.cents > 0 { out.append(AccountMove(kind: .walletDebit, memberId: memberId, amount: prepaid, ticketId: sale.ticketId, at: at)) }
        return out
    }

    /// 退款：退回儲值金、退掉賣出的儲值與課程卡、還回抵掉的次數
    public static func moves(refund: Refund, sale: SaleRecord) -> [AccountMove] {
        guard let memberId = sale.member?.id else { return [] }
        var out: [AccountMove] = []
        let at = refund.at
        if refund.tender == .prepaid && refund.amount.cents > 0 {
            out.append(AccountMove(kind: .walletCredit, memberId: memberId, amount: refund.amount, ticketId: sale.ticketId, at: at))
        }
        // 退了哪些行、各幾個：有列品項照品項；沒列品項而且退了整張的金額＝全部；只退一部分金額（沒列品項）不動卡與儲值
        let returned: [(SaleLine, Int)]
        if !refund.lines.isEmpty {
            returned = refund.lines.compactMap { rl in sale.lines.first { $0.lineId == rl.lineId }.map { ($0, min(rl.quantity, $0.quantity)) } }
        } else if refund.amount >= sale.total {
            returned = sale.lines.map { ($0, $0.quantity) }
        } else {
            returned = []
        }
        for (l, qty) in returned where qty > 0 {
            switch l.kind ?? .goods {
            case .storedValue:
                let credit = (l.credit ?? l.unitPrice) * qty
                if credit.cents > 0 { out.append(AccountMove(kind: .walletDebit, memberId: memberId, amount: credit, ticketId: sale.ticketId, at: at)) }
            case .pass:
                // 退最後買的那幾張
                for k in stride(from: l.quantity - 1, through: l.quantity - qty, by: -1) {
                    out.append(AccountMove(kind: .passCancelled, memberId: memberId, passId: passId(lineId: l.lineId, index: k, quantity: l.quantity), ticketId: sale.ticketId, at: at))
                }
            case .goods, .service:
                break
            }
            if let r = l.redeem {
                out.append(AccountMove(kind: .passRestored, memberId: memberId, passId: r.passId, count: qty, ticketId: sale.ticketId, at: at))
            }
        }
        return out
    }

    public static func moves(checkIn c: CheckIn) -> [AccountMove] {
        guard let memberId = c.member.id, let passId = c.passId, c.uses > 0 else { return [] }
        return [AccountMove(kind: .passUsed, memberId: memberId, passId: passId, count: c.uses, at: c.at)]
    }

    public static func moves(checkInVoided c: CheckIn, at: Date) -> [AccountMove] {
        guard let memberId = c.member.id, let passId = c.passId, c.uses > 0 else { return [] }
        return [AccountMove(kind: .passRestored, memberId: memberId, passId: passId, count: c.uses, at: at)]
    }

    /// 課程卡的 id：一次買一張就是那一行的 id；買好幾張是 lineId#1、lineId#2…
    public static func passId(lineId: String, index: Int, quantity: Int) -> String {
        quantity <= 1 ? lineId : "\(lineId)#\(index + 1)"
    }
}

/// 入場報到（健身房、教室）
public struct CheckIn: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var member: MemberRef
    /// 用哪一張卡（沒有卡的單次入場是 nil：另外開單收錢）
    public var passId: String?
    public var passName: String?
    /// 扣幾次（次數卡 1、期間會籍 0）
    public var uses: Int
    /// 團體課
    public var sessionId: String?
    public var reservationId: String?
    public var note: String
    public var at: Date
    public var by: String
    public var voidedAt: Date?

    public init(id: String, member: MemberRef, passId: String? = nil, passName: String? = nil, uses: Int = 0, sessionId: String? = nil,
                reservationId: String? = nil, note: String = "", at: Date, by: String, voidedAt: Date? = nil) {
        self.id = id; self.member = member; self.passId = passId; self.passName = passName; self.uses = uses
        self.sessionId = sessionId; self.reservationId = reservationId; self.note = note; self.at = at; self.by = by; self.voidedAt = voidedAt
    }

    public var isVoided: Bool { voidedAt != nil }
}

/// 某一筆事件造成的帳戶變動（StoreState 記著，查會員時用來補上後台還沒算進去的）
public struct AccountEntry: Codable, Sendable, Hashable {
    public var eventId: String
    public var moves: [AccountMove]

    public init(eventId: String, moves: [AccountMove]) { self.eventId = eventId; self.moves = moves }
}

extension TaipeiTime {
    /// 從 date 那天（台北）00:00 算起 days 天後的 00:00：30 天的月卡 10/4 買 → 10/4–11/2 這 30 天能用，存成 11/3 00:00 到期
    public static func endOfDay(_ date: Date, plusDays days: Int) -> Date {
        let cal = calendar
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: max(days, 0), to: start) ?? date.addingTimeInterval(TimeInterval(days * 86_400))
    }
}
