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

/// 營業模式：同一套 POS 用在不同的店、不同的時段（每台 iPad 可以切換）。
///
/// 模式只決定「流程」：先結帳還是後結帳、開哪個畫面、要不要桌位與廚房、業績算給誰。
/// 底下的單子、付款、發票、事件、同步每個模式都一樣，所以一家店可以同時有好幾種（健身房的櫃台賣飲料＝櫃台點餐）。
public enum ServiceMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// 餐廳桌邊：帶位 → 點餐 → 送廚房 → 吃完再結帳
    case tableService
    /// 櫃台（飲料、快餐）：點完先結帳 → 印取餐號碼 → 出餐叫號
    case counter
    /// 零售／攤位：掃條碼或點品項 → 結帳，不出廚房單
    case retail
    /// 咖啡甜點：內用外帶都有，點完先結帳、內用送到桌
    case cafe
    /// 服飾配件（衣服、鞋包、選物）：款式選顏色尺寸、掃吊牌條碼、換貨、業績算給店員
    case apparel
    /// 美業預約（髮廊、美甲、美容、寵物美容）：照設計師排預約、到店開單、做完再結帳；儲值金與療程卡
    case salon
    /// 會員課程（健身房、瑜珈、舞蹈、才藝教室）：入場報到、會籍與堂數、課表與私人教練
    case fitness

    public var label: String {
        switch self {
        case .tableService: "餐廳桌邊"
        case .counter: "櫃台點餐"
        case .retail: "零售攤位"
        case .cafe: "咖啡甜點"
        case .apparel: "服飾零售"
        case .salon: "美業預約"
        case .fitness: "會員課程"
        }
    }

    public var summary: String {
        switch self {
        case .tableService: "帶位、點餐送廚房，吃完再結帳"
        case .counter: "點完先結帳，印取餐號碼、出餐叫號"
        case .retail: "掃條碼或點品項就結帳，不出廚房單"
        case .cafe: "內用外帶都有，先結帳、內用送到桌"
        case .apparel: "選顏色尺寸、掃吊牌，換貨退貨，業績算給店員"
        case .salon: "照設計師排預約，到店開單、做完結帳，儲值與療程卡"
        case .fitness: "入場報到、會籍與堂數，課表與私人教練"
        }
    }

    /// 例子（設定畫面、後台選模式時的說明）
    public var examples: String {
        switch self {
        case .tableService: "餐廳、火鍋、居酒屋"
        case .counter: "手搖飲、早餐、便當、小吃"
        case .retail: "市集攤位、伴手禮、書店、雜貨"
        case .cafe: "咖啡廳、甜點店、麵包店"
        case .apparel: "服飾、鞋包、配件、選物店"
        case .salon: "髮廊、美甲、美睫、美容、寵物美容"
        case .fitness: "健身房、瑜珈、舞蹈、拳擊、才藝教室"
        }
    }

    /// 先結帳才送廚房／才服務（櫃台、咖啡、零售、服飾、課程）；餐廳與美業是做完再結帳
    public var payFirst: Bool { self != .tableService && self != .salon }
    /// 用桌位圖
    public var usesTables: Bool { self == .tableService || self == .cafe }
    /// 有廚房出單
    public var usesKitchen: Bool { self == .tableService || self == .counter || self == .cafe }
    /// 收據上印大大的取餐號碼
    public var printsPickupNumber: Bool { self == .counter || self == .cafe }
    /// 單子、收據上顯示內用／外帶（服飾、美業、課程沒有這回事）
    public var showsOrderType: Bool { self == .tableService || self == .counter || self == .cafe }
    /// 預約表（照服務人員排時段）
    public var usesAppointments: Bool { self == .salon || self == .fitness }
    /// 團體課的課表
    public var usesClasses: Bool { self == .fitness }
    /// 入場報到（掃會員、扣堂數）
    public var usesCheckIn: Bool { self == .fitness }
    /// 換貨（同款換尺寸、換別的商品補差價）
    public var usesExchanges: Bool { self == .retail || self == .apparel }
    /// 每一行可以指定服務人員（設計師、教練）：業績、抽成照行算
    public var staffPerLine: Bool { self == .salon || self == .fitness }
    /// 整張單算給一位店員（服飾的銷售業績）
    public var staffPerTicket: Bool { self == .apparel }
    /// 單子一定要有客人（美業做完要記在客人的紀錄上；課程要扣會員的堂數）
    public var wantsCustomer: Bool { self == .salon || self == .fitness }

    /// 服務人員的稱呼
    public var staffTitle: String {
        switch self {
        case .salon: "設計師"
        case .fitness: "教練"
        case .apparel: "銷售人員"
        default: "服務人員"
        }
    }

    /// 新單的用餐方式（服飾、美業、課程用「外帶」：不收內用服務費，畫面上也不顯示）
    public var defaultOrderType: OrderType {
        switch self {
        case .tableService, .cafe: .dineIn
        case .counter, .retail, .apparel, .salon, .fitness: .takeout
        }
    }

    /// 登入後先看哪個畫面
    public var home: ModeHome {
        switch self {
        case .tableService: .floor
        case .salon: .appointments
        case .fitness: .checkIn
        case .counter, .retail, .cafe, .apparel: .order
        }
    }
}

/// 模式的首頁（App 對到自己的分頁）
public enum ModeHome: String, Sendable, Hashable {
    case order, floor, appointments, checkIn
}

/// 儲值金的發票什麼時候開
public enum PrepaidInvoicing: String, Codable, Sendable, Hashable, CaseIterable {
    /// 儲值（收錢）時開；之後用儲值金付的部分不再開（台灣美業、健身多半這樣：預收款收款時開立）
    case atTopUp
    /// 消費時才開；儲值時不開（像「現金禮券」：只寫金額、憑券兌換時開立）
    case atRedemption

    public var label: String {
        switch self {
        case .atTopUp: "儲值時開發票"
        case .atRedemption: "消費時開發票"
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
    /// 這家店開了哪些營業模式（每台 iPad 在這幾個裡面切換）
    public var serviceModes: [ServiceMode]
    public var defaultServiceMode: ServiceMode
    /// 儲值金的發票什麼時候開
    public var prepaidInvoicing: PrepaidInvoicing
    /// 幾天內可以換貨（0 = 不限）
    public var exchangeDays: Int
    /// 預約表一格幾分鐘
    public var bookingSlotMinutes: Int

    public init(
        name: String, legalName: String = "", taxId: String = "", address: String = "", phone: String = "",
        receiptFooter: String = "謝謝光臨", serviceChargeBps: Int = 0, serviceChargeOn: [OrderType] = [.dineIn],
        tipsEnabled: Bool = false, defaultOrderType: OrderType = .dineIn, tableTimeLimitMinutes: Int = 0,
        businessDayCutoffHour: Int = 4, discountLimitBps: Int = 1000, discountPresetsBps: [Int] = [500, 1000, 1500, 2000],
        cashQuickAmounts: [Money] = [Money(dollars: 100), Money(dollars: 500), Money(dollars: 1000)],
        serviceModes: [ServiceMode] = ServiceMode.allCases, defaultServiceMode: ServiceMode = .tableService,
        prepaidInvoicing: PrepaidInvoicing = .atTopUp, exchangeDays: Int = 7, bookingSlotMinutes: Int = 15
    ) {
        self.name = name; self.legalName = legalName; self.taxId = taxId; self.address = address; self.phone = phone
        self.receiptFooter = receiptFooter; self.serviceChargeBps = serviceChargeBps; self.serviceChargeOn = serviceChargeOn
        self.tipsEnabled = tipsEnabled; self.defaultOrderType = defaultOrderType; self.tableTimeLimitMinutes = tableTimeLimitMinutes
        self.businessDayCutoffHour = businessDayCutoffHour; self.discountLimitBps = discountLimitBps
        self.discountPresetsBps = discountPresetsBps; self.cashQuickAmounts = cashQuickAmounts
        self.serviceModes = serviceModes.isEmpty ? ServiceMode.allCases : serviceModes
        self.defaultServiceMode = defaultServiceMode
        self.prepaidInvoicing = prepaidInvoicing; self.exchangeDays = exchangeDays; self.bookingSlotMinutes = bookingSlotMinutes
    }

    public func serviceChargeBps(for type: OrderType) -> Int { serviceChargeOn.contains(type) ? serviceChargeBps : 0 }

    // 後台少給哪個欄位（舊版後台、還沒設定）就用預設值，不要整份設定讀不進來
    enum CodingKeys: String, CodingKey {
        case name, legalName, taxId, address, phone, receiptFooter, serviceChargeBps, serviceChargeOn, tipsEnabled, defaultOrderType
        case tableTimeLimitMinutes, businessDayCutoffHour, discountLimitBps, discountPresetsBps, cashQuickAmounts, serviceModes, defaultServiceMode
        case prepaidInvoicing, exchangeDays, bookingSlotMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StoreProfile(name: "")
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        legalName = try c.decodeIfPresent(String.self, forKey: .legalName) ?? d.legalName
        taxId = try c.decodeIfPresent(String.self, forKey: .taxId) ?? d.taxId
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? d.address
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? d.phone
        receiptFooter = try c.decodeIfPresent(String.self, forKey: .receiptFooter) ?? d.receiptFooter
        serviceChargeBps = try c.decodeIfPresent(Int.self, forKey: .serviceChargeBps) ?? d.serviceChargeBps
        serviceChargeOn = try c.decodeIfPresent([OrderType].self, forKey: .serviceChargeOn) ?? d.serviceChargeOn
        tipsEnabled = try c.decodeIfPresent(Bool.self, forKey: .tipsEnabled) ?? d.tipsEnabled
        defaultOrderType = try c.decodeIfPresent(OrderType.self, forKey: .defaultOrderType) ?? d.defaultOrderType
        tableTimeLimitMinutes = try c.decodeIfPresent(Int.self, forKey: .tableTimeLimitMinutes) ?? d.tableTimeLimitMinutes
        businessDayCutoffHour = try c.decodeIfPresent(Int.self, forKey: .businessDayCutoffHour) ?? d.businessDayCutoffHour
        discountLimitBps = try c.decodeIfPresent(Int.self, forKey: .discountLimitBps) ?? d.discountLimitBps
        discountPresetsBps = try c.decodeIfPresent([Int].self, forKey: .discountPresetsBps) ?? d.discountPresetsBps
        cashQuickAmounts = try c.decodeIfPresent([Money].self, forKey: .cashQuickAmounts) ?? d.cashQuickAmounts
        // 不認得的模式（新版後台加的）略過
        let rawModes = try c.decodeIfPresent([String].self, forKey: .serviceModes) ?? []
        let decoded = rawModes.compactMap(ServiceMode.init(rawValue:))
        let modes = decoded.isEmpty ? ServiceMode.allCases : decoded
        serviceModes = modes
        let rawDefault = try c.decodeIfPresent(String.self, forKey: .defaultServiceMode)
        let wanted = rawDefault.flatMap(ServiceMode.init(rawValue:))
        defaultServiceMode = wanted.flatMap { modes.contains($0) ? $0 : nil } ?? modes[0]
        let rawInvoicing = try c.decodeIfPresent(String.self, forKey: .prepaidInvoicing)
        prepaidInvoicing = rawInvoicing.flatMap(PrepaidInvoicing.init(rawValue:)) ?? d.prepaidInvoicing
        exchangeDays = try c.decodeIfPresent(Int.self, forKey: .exchangeDays) ?? d.exchangeDays
        bookingSlotMinutes = max(5, try c.decodeIfPresent(Int.self, forKey: .bookingSlotMinutes) ?? d.bookingSlotMinutes)
    }
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
    /// 預約表（美業的設計師、健身的私人教練）與團體課
    public var appointments: Bool
    /// 會員的儲值金、課程卡、會籍（要後台支援；舊版後台沒有就關）
    public var accounts: Bool
    /// 業績與抽成報表
    public var commission: Bool
    /// 叫號（號碼牌）：取號、叫號、過號（Bootstrap.queue 是它的設定）。要後台設好號碼存在哪裡，所以預設關
    public var queue: Bool
    /// 外送平台（Uber Eats、foodpanda）的單直接進 POS（Bootstrap.delivery 是它的設定）。要後台串好平台，所以預設關
    public var delivery: Bool

    public init(seating: Bool = true, kitchen: Bool = true, reservations: Bool = true, invoice: Bool = true, members: Bool = true, waitlistSMS: Bool = false,
                appointments: Bool = true, accounts: Bool = true, commission: Bool = true, queue: Bool = false, delivery: Bool = false) {
        self.seating = seating; self.kitchen = kitchen; self.reservations = reservations; self.invoice = invoice
        self.members = members; self.waitlistSMS = waitlistSMS
        self.appointments = appointments; self.accounts = accounts; self.commission = commission
        self.queue = queue; self.delivery = delivery
    }

    public static let all = FeatureFlags()

    enum CodingKeys: String, CodingKey { case seating, kitchen, reservations, invoice, members, waitlistSMS, appointments, accounts, commission, queue, delivery }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seating = try c.decodeIfPresent(Bool.self, forKey: .seating) ?? true
        kitchen = try c.decodeIfPresent(Bool.self, forKey: .kitchen) ?? true
        reservations = try c.decodeIfPresent(Bool.self, forKey: .reservations) ?? true
        invoice = try c.decodeIfPresent(Bool.self, forKey: .invoice) ?? false
        members = try c.decodeIfPresent(Bool.self, forKey: .members) ?? true
        waitlistSMS = try c.decodeIfPresent(Bool.self, forKey: .waitlistSMS) ?? false
        // 後台沒說就是沒有（這些要後台有對應的資料表）
        appointments = try c.decodeIfPresent(Bool.self, forKey: .appointments) ?? false
        accounts = try c.decodeIfPresent(Bool.self, forKey: .accounts) ?? false
        commission = try c.decodeIfPresent(Bool.self, forKey: .commission) ?? false
        queue = try c.decodeIfPresent(Bool.self, forKey: .queue) ?? false
        delivery = try c.decodeIfPresent(Bool.self, forKey: .delivery) ?? false
    }
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
