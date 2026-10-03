import Foundation

/// 用餐方式
public enum OrderType: String, Codable, Sendable, CaseIterable, Hashable {
    case dineIn, takeout, delivery

    public var label: String {
        switch self {
        case .dineIn: "內用"
        case .takeout: "外帶"
        case .delivery: "外送"
        }
    }
}

/// 店家設定（後台「門市 POS → 設定」）
public struct StoreProfile: Codable, Sendable, Hashable {
    /// 店名（收據、證明聯最上面）
    public var name: String
    /// 營業人名稱（發票上的賣方名稱；通常是公司名）
    public var legalName: String
    /// 賣方統一編號
    public var taxId: String
    public var address: String
    public var phone: String
    /// 收據最下面一行（「謝謝光臨」、Wi-Fi 密碼…）
    public var receiptFooter: String
    /// 服務費（萬分比；1000 = 10%）
    public var serviceChargeBps: Int
    /// 哪些用餐方式收服務費（通常只有內用）
    public var serviceChargeOn: [OrderType]
    /// 小費（台灣少見，預設關）
    public var tipsEnabled: Bool
    public var defaultOrderType: OrderType
    /// 用餐時間限制（分鐘；0 = 不限）：桌子上顯示剩多久
    public var tableTimeLimitMinutes: Int
    /// 營業日的分界（凌晨 4 點前的單算前一天：宵夜、酒吧）
    public var businessDayCutoffHour: Int
    /// 不用主管授權就能打的折扣上限（萬分比）
    public var discountLimitBps: Int
    /// 快速折扣按鈕
    public var discountPresetsBps: [Int]
    /// 找零的快速金額（右側鍵盤：100、500、1000）
    public var cashQuickAmounts: [Money]

    public init(
        name: String, legalName: String = "", taxId: String = "", address: String = "", phone: String = "",
        receiptFooter: String = "謝謝光臨", serviceChargeBps: Int = 0, serviceChargeOn: [OrderType] = [.dineIn],
        tipsEnabled: Bool = false, defaultOrderType: OrderType = .dineIn, tableTimeLimitMinutes: Int = 0,
        businessDayCutoffHour: Int = 4, discountLimitBps: Int = 1000, discountPresetsBps: [Int] = [500, 1000, 1500, 2000],
        cashQuickAmounts: [Money] = [Money(dollars: 100), Money(dollars: 500), Money(dollars: 1000)]
    ) {
        self.name = name; self.legalName = legalName; self.taxId = taxId; self.address = address; self.phone = phone
        self.receiptFooter = receiptFooter; self.serviceChargeBps = serviceChargeBps; self.serviceChargeOn = serviceChargeOn
        self.tipsEnabled = tipsEnabled; self.defaultOrderType = defaultOrderType; self.tableTimeLimitMinutes = tableTimeLimitMinutes
        self.businessDayCutoffHour = businessDayCutoffHour; self.discountLimitBps = discountLimitBps
        self.discountPresetsBps = discountPresetsBps; self.cashQuickAmounts = cashQuickAmounts
    }

    public func serviceChargeBps(for type: OrderType) -> Int { serviceChargeOn.contains(type) ? serviceChargeBps : 0 }
}

/// 這家店開了哪些功能（後台的方案與設定決定；App 依這個顯示側欄）
public struct FeatureFlags: Codable, Sendable, Hashable {
    /// 桌位（內用）
    public var seating: Bool
    /// 廚房出單／廚房螢幕
    public var kitchen: Bool
    /// 訂位與候位
    public var reservations: Bool
    /// 電子發票
    public var invoice: Bool
    /// 會員（查電話、累積消費）
    public var members: Bool
    /// 候位叫號簡訊（要有「簡訊」服務）
    public var waitlistSMS: Bool

    public init(seating: Bool = true, kitchen: Bool = true, reservations: Bool = true, invoice: Bool = true, members: Bool = true, waitlistSMS: Bool = false) {
        self.seating = seating; self.kitchen = kitchen; self.reservations = reservations; self.invoice = invoice
        self.members = members; self.waitlistSMS = waitlistSMS
    }

    public static let all = FeatureFlags()
}

/// 時間：一律台北時間（營業日、報表、發票日期）
public enum TaipeiTime {
    public static let timeZone = TimeZone(identifier: "Asia/Taipei") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// 營業日（YYYY-MM-DD）：凌晨 cutoff 點前算前一天
    public static func businessDate(_ date: Date, cutoffHour: Int = 4) -> String {
        let shifted = date.addingTimeInterval(TimeInterval(-cutoffHour * 3600))
        return dayString(shifted)
    }

    /// YYYY-MM-DD（台北）
    public static func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// HH:mm:ss（台北）
    public static func timeString(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// HH:mm（台北）
    public static func clock(_ date: Date) -> String { String(timeString(date).prefix(5)) }

    public static func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }
}
