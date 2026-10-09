import Foundation

// 外送平台（Uber Eats、foodpanda）的單：後台收下平台的單、寫成一張「外送」的單同步過來（docs/DELIVERY.md）。
// 接單、拒單、出餐好了都在 POS 上做，後台替我們告訴平台；這裡只有資料與狀態，不碰網路。

public enum DeliveryPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case ubereats, foodpanda

    public var label: String {
        switch self {
        case .ubereats: "Uber Eats"
        case .foodpanda: "foodpanda"
        }
    }

    /// 單號前面的字（UE-3F2A1）
    public var prefix: String {
        switch self {
        case .ubereats: "UE"
        case .foodpanda: "FP"
        }
    }
}

/// delivery 外送員來拿｜pickup 客人自己來拿
public enum DeliveryKind: String, Codable, Sendable, Hashable {
    case delivery, pickup
}

public enum DeliveryStatus: String, Codable, Sendable, Hashable {
    /// 等接單（倒數到 acceptBy）
    case pending
    case accepted
    case rejected
    /// 做好了、等人來拿
    case ready
    case pickedUp
    /// 平台取消、逾時沒接
    case cancelled

    public var label: String {
        switch self {
        case .pending: "待接單"
        case .accepted: "製作中"
        case .rejected: "已拒單"
        case .ready: "等取餐"
        case .pickedUp: "已取餐"
        case .cancelled: "已取消"
        }
    }

    /// 已經結束（不會再變）
    public var isFinal: Bool { self == .rejected || self == .pickedUp || self == .cancelled }
}

/// 拒單、取消的原因（後台換成平台的代碼）
public enum DeliveryReason: String, Codable, Sendable, Hashable, CaseIterable {
    case tooBusy = "too_busy"
    case itemUnavailable = "item_unavailable"
    case closed
    case other

    public var label: String {
        switch self {
        case .tooBusy: "太忙了"
        case .itemUnavailable: "有東西賣完了"
        case .closed: "打烊了"
        case .other: "其他"
        }
    }
}

public enum CourierStatus: String, Codable, Sendable, Hashable {
    case assigned, arriving, arrived, pickedUp

    public var label: String {
        switch self {
        case .assigned: "外送員已接單"
        case .arriving: "外送員快到了"
        case .arrived: "外送員到了"
        case .pickedUp: "外送員拿走了"
        }
    }
}

public struct Courier: Codable, Sendable, Hashable {
    public var name: String?
    public var status: CourierStatus
    public var eta: Date?
    public init(name: String? = nil, status: CourierStatus, eta: Date? = nil) { self.name = name; self.status = status; self.eta = eta }
}

/// 客人在平台上填的發票資料（平台有給才有）
public struct DeliveryInvoiceInfo: Codable, Sendable, Hashable {
    public var carrier: String?
    public var taxId: String?
    public var donation: String?
    public init(carrier: String? = nil, taxId: String? = nil, donation: String? = nil) {
        self.carrier = carrier; self.taxId = taxId; self.donation = donation
    }

    /// 結帳開發票用：統編 → 載具 → 捐贈；都沒有＝紙本
    public var buyer: InvoiceBuyer? {
        if let t = taxId, !t.isEmpty { return .business(taxId: t, title: nil) }
        if let c = carrier, !c.isEmpty { return .consumer(carrier: .mobileBarcode(c)) }
        if let d = donation, !d.isEmpty { return .donation(loveCode: d) }
        return nil
    }
}

/// 掛在單子上的外送資訊（ticket.opened 帶來、delivery.updated 更新）
public struct DeliveryOrder: Codable, Sendable, Hashable {
    public var platform: DeliveryPlatform
    /// 平台的訂單 id
    public var orderId: String
    /// 給外送員、客人看的短碼
    public var code: String
    public var kind: DeliveryKind
    public var status: DeliveryStatus
    public var placedAt: Date
    /// 這之前要接或拒（不然平台自動取消，連續幾次會被暫停）
    public var acceptBy: Date?
    /// 答應幾點做好
    public var readyAt: Date?
    public var prepMinutes: Int?
    /// 預約單：客人要的時間
    public var scheduledFor: Date?
    public var customerName: String?
    /// 整單備註、過敏
    public var customerNote: String?
    public var courier: Courier?
    /// 平台上的品項合計（客人付的餐點錢）
    public var subtotal: Money
    /// 抽成、撥款（平台給的；estimated＝照設定的抽成率估的）
    public var commission: Money?
    public var payout: Money?
    public var estimated: Bool?
    public var invoice: DeliveryInvoiceInfo?
    /// 哪一台接的（那一台負責結帳、送廚房）
    public var acceptedBy: String?
    /// 拒單、取消的原因
    public var reason: String?
    public var test: Bool?

    public init(platform: DeliveryPlatform, orderId: String, code: String, kind: DeliveryKind = .delivery, status: DeliveryStatus = .pending,
                placedAt: Date, acceptBy: Date? = nil, readyAt: Date? = nil, prepMinutes: Int? = nil, scheduledFor: Date? = nil,
                customerName: String? = nil, customerNote: String? = nil, courier: Courier? = nil, subtotal: Money,
                commission: Money? = nil, payout: Money? = nil, estimated: Bool? = nil, invoice: DeliveryInvoiceInfo? = nil,
                acceptedBy: String? = nil, reason: String? = nil, test: Bool? = nil) {
        self.platform = platform; self.orderId = orderId; self.code = code; self.kind = kind; self.status = status
        self.placedAt = placedAt; self.acceptBy = acceptBy; self.readyAt = readyAt; self.prepMinutes = prepMinutes
        self.scheduledFor = scheduledFor; self.customerName = customerName; self.customerNote = customerNote; self.courier = courier
        self.subtotal = subtotal; self.commission = commission; self.payout = payout; self.estimated = estimated
        self.invoice = invoice; self.acceptedBy = acceptedBy; self.reason = reason; self.test = test
    }

    /// 「Uber Eats #3F2A1」
    public var title: String { "\(platform.label) #\(code)" }

    /// 還剩幾秒要接（過了是負的）；不是待接單＝nil
    public func secondsToAccept(at now: Date) -> Int? {
        guard status == .pending, let by = acceptBy else { return nil }
        return Int(by.timeIntervalSince(now).rounded(.down))
    }

    /// 離答應的時間還有幾分（遲了是負的）
    public func minutesToReady(at now: Date) -> Int? {
        guard let r = readyAt, status == .accepted else { return nil }
        return Int((r.timeIntervalSince(now) / 60).rounded(.down))
    }
}

/// 後台寫的：平台那邊的狀態變了（接了、做好了、外送員到了、被取消了）。只送有變的欄位
public struct DeliveryUpdated: Codable, Sendable, Hashable {
    public var ticketId: String
    public var status: DeliveryStatus?
    public var readyAt: Date?
    public var prepMinutes: Int?
    public var courier: Courier?
    public var reason: String?
    public var commission: Money?
    public var payout: Money?
    public var estimated: Bool?
    public var acceptedBy: String?

    public init(ticketId: String, status: DeliveryStatus? = nil, readyAt: Date? = nil, prepMinutes: Int? = nil, courier: Courier? = nil,
                reason: String? = nil, commission: Money? = nil, payout: Money? = nil, estimated: Bool? = nil, acceptedBy: String? = nil) {
        self.ticketId = ticketId; self.status = status; self.readyAt = readyAt; self.prepMinutes = prepMinutes; self.courier = courier
        self.reason = reason; self.commission = commission; self.payout = payout; self.estimated = estimated; self.acceptedBy = acceptedBy
    }

    func apply(to d: inout DeliveryOrder) {
        if let s = status { d.status = s }
        if let r = readyAt { d.readyAt = r }
        if let p = prepMinutes { d.prepMinutes = p }
        if let c = courier { d.courier = c }
        if let r = reason { d.reason = r }
        if let c = commission { d.commission = c }
        if let p = payout { d.payout = p }
        if let e = estimated { d.estimated = e }
        if let a = acceptedBy { d.acceptedBy = a }
    }
}

/// 一個平台在這家店的狀態（後台 bootstrap、GET delivery 給的）
public struct DeliveryPlatformState: Codable, Sendable, Hashable, Identifiable {
    public var platform: DeliveryPlatform
    public var enabled: Bool
    public var connected: Bool
    public var storeName: String?
    /// online｜paused｜offline（沒連上）
    public var status: String
    public var pausedUntil: Date?
    /// watchdog＝POS 全部斷線時後台自動暫停的；manual＝店裡按的
    public var pausedBy: String?
    public var busyExtraMinutes: Int
    public var autoAccept: Bool
    public var defaultPrepMinutes: Int
    public var lastOrderAt: Date?
    public var lastError: DeliveryError?
    /// 後台的自動連線檢查：ok｜waiting_platform（等平台開通，不是錯誤）｜needs_reauth（要重新連結）｜error；還沒檢查＝nil
    public var health: String?

    public var id: String { platform.rawValue }
    public var isOnline: Bool { status == "online" }

    /// 連線檢查要店家知道的（正常、還沒檢查＝nil）
    public var healthNote: String? {
        switch health {
        case "waiting_platform": "等 \(platform.label) 開通（自動重試中）"
        case "needs_reauth": "請負責人在後台重新連結 \(platform.label)"
        case "error": "連不上 \(platform.label)（自動重試中）"
        default: nil
        }
    }

    public init(platform: DeliveryPlatform, enabled: Bool = true, connected: Bool = true, storeName: String? = nil, status: String = "online",
                pausedUntil: Date? = nil, pausedBy: String? = nil, busyExtraMinutes: Int = 0, autoAccept: Bool = false,
                defaultPrepMinutes: Int = 15, lastOrderAt: Date? = nil, lastError: DeliveryError? = nil, health: String? = nil) {
        self.platform = platform; self.enabled = enabled; self.connected = connected; self.storeName = storeName; self.status = status
        self.pausedUntil = pausedUntil; self.pausedBy = pausedBy; self.busyExtraMinutes = busyExtraMinutes; self.autoAccept = autoAccept
        self.defaultPrepMinutes = defaultPrepMinutes; self.lastOrderAt = lastOrderAt; self.lastError = lastError; self.health = health
    }
}

public struct DeliveryError: Codable, Sendable, Hashable {
    public var at: Date
    public var message: String
    public init(at: Date, message: String) { self.at = at; self.message = message }
}

/// bootstrap 的 delivery
public struct DeliveryConfig: Codable, Sendable, Hashable {
    public var platforms: [DeliveryPlatformState]
    public init(platforms: [DeliveryPlatformState] = []) { self.platforms = platforms }

    public var enabled: [DeliveryPlatformState] { platforms.filter(\.enabled) }
    public func state(_ p: DeliveryPlatform) -> DeliveryPlatformState? { platforms.first { $0.platform == p } }
}

/// 建議的備餐時間：基本的分鐘數＋廚房現在的份數（內用、外帶、叫號、外送一起算）＋忙碌加的
///
/// 每多 `itemsPerMinute` 份還沒做好的就多一分鐘，最多加到 `maxExtra`。這是店家看得懂的規則（不是黑盒子），
/// 右欄會寫「建議 18 分（廚房 11 份待做）」，按一下就用、也可以自己打。
public struct PrepTimeAdvisor: Sendable, Hashable {
    public var baseMinutes: Int
    public var busyExtraMinutes: Int
    public var itemsPerMinute: Int
    public var maxExtra: Int

    public init(baseMinutes: Int, busyExtraMinutes: Int = 0, itemsPerMinute: Int = 3, maxExtra: Int = 30) {
        self.baseMinutes = baseMinutes; self.busyExtraMinutes = busyExtraMinutes
        self.itemsPerMinute = max(itemsPerMinute, 1); self.maxExtra = maxExtra
    }

    /// 這張單要做的份數也算進去（大單要久一點）
    public func suggest(pendingItems: Int, orderItems: Int) -> Int {
        let load = min((pendingItems + orderItems) / itemsPerMinute, maxExtra)
        return min(max(baseMinutes + load + busyExtraMinutes, 5), 120)
    }
}
