import Foundation

// 右側固定鍵盤的輸入規則。
//
// POS 上所有要打數字的地方（數量、改價、折扣、收現金、小費、PIN、統編、電話、愛心碼、點錢、配對碼…）
// 都用畫面最右邊同一個位置、同一個大小的鍵盤：手不用找、眼睛不用找，打了什麼大字顯示在鍵盤上方，
// 合不合規則（統編檢查碼、PIN 位數）當場告訴你，按下確認鍵才算數。
// 這裡只有規則（沒有畫面），App 的 KeypadDock 照這個畫。

public struct KeypadSpec: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// 數量（1–999）
        case quantity
        /// 金額（整數元）
        case money
        /// 百分比（0–100）
        case percent
        /// PIN（遮起來）
        case pin(minLength: Int, maxLength: Int)
        /// 統一編號（8 碼，檢查碼）
        case taxId
        /// 手機號碼（09 開頭 10 碼）
        case phone
        /// 愛心碼（3–7 碼）
        case loveCode
        /// 一般代碼：品號、配對碼、桌號（固定或最多幾碼）
        case code(minLength: Int, maxLength: Int)
        /// 張數、人數（0–9999）
        case count
    }

    /// 快速鍵（鍵盤上方那排：100、500、1000、剛好；9 折、85 折；2 位、4 位…）
    public struct QuickKey: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public var label: String
        public var digits: String
        /// 按了直接確認（「剛好」）
        public var commits: Bool

        public init(_ label: String, digits: String, commits: Bool = false) {
            self.label = label; self.digits = digits; self.commits = commits
        }
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var initial: String
    public var quickKeys: [QuickKey]
    public var confirmLabel: String
    /// 金額的上限（例如退款不能超過已收）
    public var maxValue: Int?
    /// 金額的下限（例如收現金不能少於應收——但允許先收一部分時就不設）
    public var minValue: Int?

    public init(kind: Kind, title: String, subtitle: String? = nil, initial: String = "", quickKeys: [QuickKey] = [],
                confirmLabel: String = "確定", maxValue: Int? = nil, minValue: Int? = nil) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.initial = initial; self.quickKeys = quickKeys
        self.confirmLabel = confirmLabel; self.maxValue = maxValue; self.minValue = minValue
    }

    /// 最多幾位
    public var maxDigits: Int {
        switch kind {
        case .quantity: 3
        case .money: 7
        case .percent: 3
        case .pin(_, let max): max
        case .taxId: 8
        case .phone: 10
        case .loveCode: 7
        case .code(_, let max): max
        case .count: 4
        }
    }

    /// 有「00」鍵（金額）
    public var hasDoubleZero: Bool { kind == .money }
    public var isSecret: Bool { if case .pin = kind { true } else { false } }
}

public enum KeypadKey: Sendable, Hashable {
    case digit(Int)
    case doubleZero
    case backspace
    case clear
}

/// 鍵盤正在輸入的值
public struct KeypadEntry: Sendable, Hashable {
    public let spec: KeypadSpec
    public private(set) var digits: String
    /// 剛打開、還沒按過：第一個數字直接取代原本的值（像計算機）
    public private(set) var isPristine: Bool

    public init(_ spec: KeypadSpec) {
        self.spec = spec
        self.digits = String(spec.initial.filter(\.isNumber).prefix(spec.maxDigits))
        self.isPristine = !self.digits.isEmpty
    }

    public mutating func press(_ key: KeypadKey) {
        switch key {
        case .digit(let n):
            guard (0...9).contains(n) else { return }
            if isPristine { digits = "" }
            isPristine = false
            guard digits.count < spec.maxDigits else { return }
            // 數值類不留前面的 0（PIN、統編、電話、代碼要留）
            if digits == "0" && isNumeric { digits = "" }
            digits.append(String(n))
        case .doubleZero:
            if isPristine { digits = "" }
            isPristine = false
            guard !digits.isEmpty else { return }
            digits = String((digits + "00").prefix(spec.maxDigits))
        case .backspace:
            if isPristine { digits = ""; isPristine = false; return }
            if !digits.isEmpty { digits.removeLast() }
        case .clear:
            digits = ""
            isPristine = false
        }
    }

    public mutating func apply(_ quick: KeypadSpec.QuickKey) {
        digits = String(quick.digits.prefix(spec.maxDigits))
        isPristine = false
    }

    /// 打字機式輸入（外接鍵盤、掃描器）
    public mutating func type(_ text: String) {
        for ch in text {
            if let n = ch.wholeNumberValue { press(.digit(n)) }
        }
    }

    private var isNumeric: Bool {
        switch spec.kind {
        case .quantity, .money, .percent, .count: true
        default: false
        }
    }

    /// 數值（數量、金額、百分比、張數）
    public var value: Int? { Int(digits) }

    public var money: Money? { value.map { Money(dollars: $0) } }

    /// 大字顯示
    public var display: String {
        switch spec.kind {
        case .money: return Money.group(value ?? 0)
        case .quantity, .count: return digits.isEmpty ? "0" : String(value ?? 0)
        case .percent: return "\(value ?? 0)%"
        case .pin: return String(repeating: "●", count: digits.count)
        case .taxId: return KeypadEntry.grouped(digits, [4, 4])
        case .phone: return KeypadEntry.grouped(digits, [4, 3, 3])
        case .loveCode, .code: return digits
        }
    }

    /// PIN 的小圓點：(已輸入, 總共要顯示幾個)
    public var pinDots: (filled: Int, total: Int)? {
        guard case .pin(let min, let max) = spec.kind else { return nil }
        return (digits.count, Swift.max(min, Swift.min(Swift.max(digits.count, min), max)))
    }

    /// 合不合規則（nil＝可以按確認）
    public var problem: String? {
        switch spec.kind {
        case .quantity:
            guard let v = value, v >= 1 else { return "數量至少 1" }
            if let max = spec.maxValue, v > max { return "最多 \(max)" }
            return nil
        case .money:
            let v = value ?? 0
            if let min = spec.minValue, v < min { return "至少 \(Money(dollars: min).formatted)" }
            if let max = spec.maxValue, v > max { return "不能超過 \(Money(dollars: max).formatted)" }
            return nil
        case .percent:
            let v = value ?? 0
            return v > 100 ? "不能超過 100%" : nil
        case .pin(let min, _):
            return digits.count < min ? "請輸入 \(min) 位數以上" : nil
        case .taxId:
            if digits.count < 8 { return "統一編號是 8 碼" }
            return InvoiceValidation.isTaxId(digits) ? nil : "統一編號檢查碼不對"
        case .phone:
            if digits.count < 10 { return "手機號碼是 10 碼" }
            return digits.hasPrefix("09") ? nil : "手機號碼是 09 開頭"
        case .loveCode:
            return InvoiceValidation.isLoveCode(digits) ? nil : "愛心碼是 3 到 7 位數字"
        case .code(let min, _):
            return digits.count < min ? (min == spec.maxDigits ? "請輸入 \(min) 碼" : "至少 \(min) 碼") : nil
        case .count:
            let v = value ?? 0
            if let min = spec.minValue, v < min { return "至少 \(min)" }
            if let max = spec.maxValue, v > max { return "最多 \(max)" }
            return nil
        }
    }

    /// 還沒打完，不算錯（統編打到第 5 碼時不要一直說「不對」）
    public var isIncomplete: Bool {
        switch spec.kind {
        case .taxId: digits.count < 8
        case .phone: digits.count < 10
        case .pin(let min, _): digits.count < min
        case .code(let min, _): digits.count < min
        case .loveCode: digits.count < 3
        default: false
        }
    }

    /// 統編打滿 8 碼且檢查碼對（鍵盤上打勾）
    public var isVerified: Bool {
        switch spec.kind {
        case .taxId: digits.count == 8 && problem == nil
        default: false
        }
    }

    public var canCommit: Bool { problem == nil }

    static func grouped(_ s: String, _ sizes: [Int]) -> String {
        var out: [String] = []
        var rest = Substring(s)
        for size in sizes where !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.joined(separator: " ")
    }
}

extension KeypadSpec {
    /// 收現金：快速鍵是「剛好」與往上湊整的鈔票
    public static func cashTendered(due: Money, presets: [Money]) -> KeypadSpec {
        let suggestions = CashSuggestions.amounts(for: due, presets: presets)
        let quick = suggestions.enumerated().map { i, m in
            QuickKey(i == 0 ? "剛好" : m.short, digits: String(m.dollars), commits: i == 0)
        }
        return KeypadSpec(kind: .money, title: "收現金", subtitle: "應收 \(due.formatted)", quickKeys: quick, confirmLabel: "收款")
    }

    public static func quantity(name: String, current: Int) -> KeypadSpec {
        KeypadSpec(kind: .quantity, title: "數量", subtitle: name, initial: String(current), maxValue: 999)
    }

    public static func price(name: String, current: Money) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "單價", subtitle: name, initial: String(current.dollars), confirmLabel: "改價")
    }

    public static func discountPercent(presets: [Int]) -> KeypadSpec {
        let quick = presets.map { bps in
            QuickKey(Discount.percent(bps).label, digits: String(bps / 100))
        }
        return KeypadSpec(kind: .percent, title: "折扣", subtitle: "輸入要折掉的 %（打 9 折＝10）", quickKeys: quick, confirmLabel: "打折")
    }

    public static func discountAmount(max: Money) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "折扣金額", subtitle: "最多 \(max.formatted)", confirmLabel: "折抵", maxValue: max.dollars)
    }

    public static func guests(current: Int) -> KeypadSpec {
        KeypadSpec(kind: .count, title: "人數", initial: current > 0 ? String(current) : "",
                   quickKeys: [1, 2, 3, 4, 6].map { QuickKey("\($0) 位", digits: String($0)) }, confirmLabel: "入座", maxValue: 99)
    }

    public static func pin(title: String = "輸入 PIN", subtitle: String? = nil) -> KeypadSpec {
        KeypadSpec(kind: .pin(minLength: 4, maxLength: 6), title: title, subtitle: subtitle, confirmLabel: "登入")
    }

    public static let taxId = KeypadSpec(kind: .taxId, title: "統一編號", subtitle: "打統編的發票會印證明聯", confirmLabel: "使用")
    public static let phone = KeypadSpec(kind: .phone, title: "會員電話", confirmLabel: "查詢")
    public static let loveCode = KeypadSpec(kind: .loveCode, title: "愛心碼", subtitle: "捐贈發票", confirmLabel: "捐贈")
    public static let pairingCode = KeypadSpec(kind: .code(minLength: 8, maxLength: 8), title: "配對碼", subtitle: "後台「門市 POS → 裝置」產生的 8 位數", confirmLabel: "配對")
    public static let plu = KeypadSpec(kind: .code(minLength: 1, maxLength: 13), title: "品號", confirmLabel: "加入")

    public static func tip(base: Money) -> KeypadSpec {
        let quick = [500, 1000, 1500].map { bps in QuickKey(percentText(bps: bps), digits: String(base.applying(bps: bps).dollars)) }
        return KeypadSpec(kind: .money, title: "小費", subtitle: "不開發票", quickKeys: quick, confirmLabel: "加上")
    }

    public static func refund(max: Money) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "退款金額", subtitle: "最多 \(max.formatted)", initial: String(max.dollars), confirmLabel: "退款", maxValue: max.dollars, minValue: 1)
    }

    public static func openingCash(suggested: Money) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "零用金", subtitle: "開班時錢櫃裡的現金", initial: String(suggested.dollars), confirmLabel: "開班")
    }

    public static func denomination(_ d: Denomination, current: Int) -> KeypadSpec {
        KeypadSpec(kind: .count, title: d.label, subtitle: d.isCoin ? "幾個" : "幾張", initial: current > 0 ? String(current) : "", confirmLabel: "下一個")
    }

    public static func cashMove(_ kind: CashMoveKind) -> KeypadSpec {
        KeypadSpec(kind: .money, title: kind == .payIn ? "存入金額" : "取出金額", confirmLabel: kind.label, minValue: 1)
    }

    public static func openPrice(name: String) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "時價", subtitle: name, confirmLabel: "加入", minValue: 1)
    }

    /// 服務時間（分鐘）
    public static func duration(name: String, current: Int) -> KeypadSpec {
        KeypadSpec(kind: .count, title: "時間（分鐘）", subtitle: name, initial: current > 0 ? String(current) : "",
                   quickKeys: [30, 45, 60, 90, 120].map { QuickKey("\($0) 分", digits: String($0)) }, confirmLabel: "好", maxValue: 600, minValue: 5)
    }

    /// 自訂儲值金額
    public static func topUp(presets: [Money] = [Money(dollars: 1_000), Money(dollars: 3_000), Money(dollars: 5_000), Money(dollars: 10_000)]) -> KeypadSpec {
        KeypadSpec(kind: .money, title: "儲值金額", subtitle: "加到會員的儲值金", quickKeys: presets.map { QuickKey($0.short, digits: String($0.dollars)) },
                   confirmLabel: "儲值", minValue: 1)
    }

    /// 用儲值金付：最多付到餘額或應收（先帶入可以付的最多）
    public static func prepaid(balance: Money, due: Money) -> KeypadSpec {
        let most = min(balance, due)
        return KeypadSpec(kind: .money, title: "用儲值金付", subtitle: "餘額 \(balance.formatted)", initial: String(most.dollars),
                          quickKeys: [QuickKey("全部", digits: String(most.dollars), commits: true)], confirmLabel: "扣儲值金",
                          maxValue: most.dollars, minValue: 1)
    }

    /// 會員電話或會員編號（健身房報到：打電話號碼或掃會員卡）
    public static let memberCode = KeypadSpec(kind: .code(minLength: 4, maxLength: 10), title: "會員", subtitle: "手機號碼或會員卡號", confirmLabel: "查詢")

    public static func partySize() -> KeypadSpec {
        KeypadSpec(kind: .count, title: "幾位", quickKeys: [2, 3, 4, 5, 6].map { QuickKey("\($0) 位", digits: String($0)) }, confirmLabel: "下一步", maxValue: 99, minValue: 1)
    }
}
