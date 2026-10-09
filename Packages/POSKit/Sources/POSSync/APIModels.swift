import Foundation
import POSCore
import POSInvoice
import POSPrinting

// iPad ↔ 後台（atelier-cms 的「門市 POS」服務插件）的資料格式。和 docs/API.md 一一對應，改這裡就要改那裡。
// 金額一律是整數「分」；時間一律是 ISO 8601（UTC、毫秒）；JSON 的 key 是 camelCase。

/// 崗位：這台 iPad 放在店裡的哪個位置、做什麼事。同一家店的每台 iPad 看的是同一份資料（事件同步），
/// 崗位只決定它顯示哪些頁、先看哪一頁、能不能收錢開錢櫃。
/// 後台配對時決定預設；店長可以在 iPad 上改（換位置用），改了會在心跳回報給後台。
public enum DeviceRole: String, Codable, Sendable, CaseIterable, Hashable {
    /// 結帳櫃台：什麼都能做（收錢、錢櫃、交班、報表）
    case register
    /// 前場：桌邊點餐、帶位、送單（不收現金、不交班）
    case handheld
    /// 後廚：只看出單、按出餐
    case kitchen
    /// 報到接待：帶位與候位、預約表、會員報到（不結帳）
    case reception
    /// 出餐口：所有出單站的進度、叫號（櫃台模式的取餐號碼）
    case expo

    public var label: String {
        switch self {
        case .register: "結帳櫃台"
        case .handheld: "前場點餐"
        case .kitchen: "後廚"
        case .reception: "報到接待"
        case .expo: "出餐口"
        }
    }

    public var summary: String {
        switch self {
        case .register: "收錢、開發票、錢櫃與交班，全部功能"
        case .handheld: "桌邊點餐、帶位、送廚房；結帳交給櫃台（可以刷卡、電子支付）"
        case .kitchen: "依出單站看單、按製作中／可出餐"
        case .reception: "帶位候位、預約表、會員報到；開單後交給結帳"
        case .expo: "看所有出單站的進度、出餐叫號"
        }
    }

    /// 能結帳（收錢）
    public var takesPayment: Bool { self == .register || self == .handheld }
    /// 有錢櫃（收現金、交班點錢）
    public var hasDrawer: Bool { self == .register }
    /// 能開單點東西
    public var takesOrders: Bool { self == .register || self == .handheld || self == .reception }
    /// 廚房類（只看出單）
    public var isKitchen: Bool { self == .kitchen || self == .expo }
    /// 要不要發票號碼段（會結帳的才要）
    public var issuesInvoices: Bool { takesPayment }

    // 新版後台多了這版不認得的崗位：當作結帳櫃台，不要整份開機資料讀不進來
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceRole(rawValue: raw) ?? .register
    }
}

public struct DeviceInfo: Codable, Sendable, Hashable {
    public var name: String
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    public init(name: String, model: String, systemVersion: String, appVersion: String) {
        self.name = name; self.model = model; self.systemVersion = systemVersion; self.appVersion = appVersion
    }
}

// MARK: - 配對

/// 配對的結果（用 StudioX 帳號登入，console 代轉回來的那一份）
public struct PairResponse: Codable, Sendable, Hashable {
    public init(deviceId: String, token: String, deviceCode: String, role: DeviceRole, storeName: String) { self.deviceId = deviceId; self.token = token; self.deviceCode = deviceCode; self.role = role; self.storeName = storeName }

    public var deviceId: String
    /// 之後每個請求的 Authorization: Bearer <token>（只會給這一次，存在 Keychain）
    public var token: String
    /// 單號前面的字母（A、B、C…）：每台不同，斷網也不會重號
    public var deviceCode: String
    public var role: DeviceRole
    public var storeName: String
}

// MARK: - 開機資料

public struct DeviceProfile: Codable, Sendable, Hashable {
    public init(id: String, name: String, code: String, role: DeviceRole, stations: [String], personal: Bool? = nil, staffId: String? = nil) {
        self.id = id; self.name = name; self.code = code; self.role = role; self.stations = stations
        self.personal = personal; self.staffId = staffId
    }

    public var id: String
    public var name: String
    public var code: String
    public var role: DeviceRole
    /// 廚房螢幕只看哪些出單站（空的＝全部）
    public var stations: [String]
    /// 個人的裝置（用 StudioX 帳號登入、綁著 staffId 那位；ConsoleAuth.swift）。沒給＝店裡共用的
    public var personal: Bool?
    public var staffId: String?
}

/// 同一家店的 iPad 在同一個 Wi-Fi 上互相同步（斷網也能看到別台點的單）：訊息用這把金鑰簽章
public struct MeshConfig: Codable, Sendable, Hashable {
    public init(key: String, enabled: Bool) { self.key = key; self.enabled = enabled }

    /// 32 bytes 的十六進位
    public var key: String
    public var enabled: Bool
}

/// GET {cms}/api/pos/v1/bootstrap：開機、每 5 分鐘、收到「設定改了」時重抓。帶 If-None-Match: <version> 沒變回 304
public struct Bootstrap: Codable, Sendable, Hashable {
    public init(version: String, serverTime: Date, device: DeviceProfile, store: StoreProfile, features: FeatureFlags, catalog: Catalog,
                floor: FloorPlan, staff: [StaffMember], invoice: InvoiceSettings, mesh: MeshConfig, queue: QueueConfig? = nil,
                printStyle: PrintStyle? = nil, delivery: DeliveryConfig? = nil, walletScan: WalletScanConfig? = nil) {
        self.version = version; self.serverTime = serverTime; self.device = device; self.store = store; self.features = features
        self.catalog = catalog; self.floor = floor; self.staff = staff; self.invoice = invoice; self.mesh = mesh
        self.queue = queue
        self.printStyle = printStyle
        self.delivery = delivery
        self.walletScan = walletScan
    }

    public var version: String
    public var serverTime: Date
    public var device: DeviceProfile
    public var store: StoreProfile
    public var features: FeatureFlags
    public var catalog: Catalog
    public var floor: FloorPlan
    public var staff: [StaffMember]
    public var invoice: InvoiceSettings
    public var mesh: MeshConfig
    /// 叫號（號碼牌）的設定；features.queue 關著、或舊版後台沒有時是 nil
    public var queue: QueueConfig?
    /// 單據樣式（POSPrinting/PrintStyle.swift）：先畫成圖片再印、疊店家的圖；沒給＝預設（圖片、不疊圖）。讀的時候很寬鬆，壞掉的樣式不會讓開機資料讀不進來
    public var printStyle: PrintStyle?
    /// 外送平台（docs/DELIVERY.md）；features.delivery 關著、或舊版後台沒有時是 nil
    public var delivery: DeliveryConfig?
    /// 門市掃碼付開了哪些錢包（WalletPayAPI.swift）；features.walletScan 關著、或舊版後台沒有時是 nil
    public var walletScan: WalletScanConfig?
}

// MARK: - 事件

/// POST {cms}/api/pos/v1/events
public struct EventsPush: Codable, Sendable {
    public var events: [POSEvent]
    public init(events: [POSEvent]) { self.events = events }
}

public struct EventRejection: Codable, Sendable, Hashable {
    public init(id: String, reason: String, expectSeq: Int?) { self.id = id; self.reason = reason; self.expectSeq = expectSeq }

    public var id: String
    /// bad_hash｜chain_gap｜invalid｜sale_mismatch
    public var reason: String
    /// chain_gap：後台要從這個流水號開始收
    public var expectSeq: Int?
}

public struct EventsPushResult: Codable, Sendable, Hashable {
    public init(accepted: [String], duplicates: [String], rejected: [EventRejection], serverSeq: Int) { self.accepted = accepted; self.duplicates = duplicates; self.rejected = rejected; self.serverSeq = serverSeq }

    public var accepted: [String]
    public var duplicates: [String]
    public var rejected: [EventRejection]
    /// 後台目前最新的 serverSeq
    public var serverSeq: Int
}

/// GET {cms}/api/pos/v1/events?after=<serverSeq>&limit=500
public struct EventsPage: Codable, Sendable, Hashable {
    public init(events: [POSEvent], next: Int, hasMore: Bool) { self.events = events; self.next = next; self.hasMore = hasMore }

    public var events: [POSEvent]
    /// 下一次從這裡接著拿
    public var next: Int
    public var hasMore: Bool
}

// MARK: - 發票號碼段

/// POST {cms}/api/pos/v1/invoice/rolls
public struct RollRequest: Codable, Sendable {
    public var period: String
    public var count: Int
    public init(period: String, count: Int = 50) { self.period = period; self.count = count }
}

public struct RollResponse: Codable, Sendable, Hashable {
    public init(roll: InvoiceRoll) { self.roll = roll }

    public var roll: InvoiceRoll
}

// MARK: - 會員

public struct Member: Codable, Sendable, Hashable {
    public var id: String
    public var phone: String
    public var name: String?
    public var tierName: String?
    /// 累積消費（網路＋門市）
    public var lifetimeSpend: Money
    public var visits: Int
    public var lastVisitAt: Date?
    /// 店家看得到的備註（過敏、偏好、染髮配方）
    public var note: String?
    /// 儲值金餘額（後台算到 accountEventIds 為止；features.accounts 開的店才有）
    public var wallet: Money?
    /// 課程卡、會籍（含用完、過期的最近幾張）
    public var passes: [MemberPass]?
    /// 後台的餘額已經算進去的 POS 事件 id（最近 7 天）：iPad 再補上不在這裡面的
    public var accountEventIds: [String]?
    /// 最近幾次消費（美業看上次做了什麼、誰做的）
    public var recentVisits: [MemberVisit]?
    /// 會員照片（健身房報到核對）
    public var photoURL: String?
    /// 生日（MM-DD；當月壽星提醒）
    public var birthday: String?

    public init(id: String, phone: String, name: String?, tierName: String?, lifetimeSpend: Money, visits: Int, lastVisitAt: Date?, note: String?,
                wallet: Money? = nil, passes: [MemberPass]? = nil, accountEventIds: [String]? = nil, recentVisits: [MemberVisit]? = nil,
                photoURL: String? = nil, birthday: String? = nil) {
        self.id = id; self.phone = phone; self.name = name; self.tierName = tierName
        self.lifetimeSpend = lifetimeSpend; self.visits = visits; self.lastVisitAt = lastVisitAt; self.note = note
        self.wallet = wallet; self.passes = passes; self.accountEventIds = accountEventIds; self.recentVisits = recentVisits
        self.photoURL = photoURL; self.birthday = birthday
    }

    public var ref: MemberRef { MemberRef(id: id, phone: phone, name: name, tierName: tierName) }

    /// 後台查到的帳戶（還沒加上這台的）
    public var serverAccount: MemberAccount { MemberAccount(wallet: wallet ?? .zero, passes: passes ?? []) }

    /// 現在的帳戶：後台的＋這台記了但後台還沒算進去的（斷網也對）
    public func account(in state: StoreState) -> MemberAccount {
        state.account(memberId: id, server: serverAccount, included: Set(accountEventIds ?? []))
    }
}

/// 會員的一次消費（後台從 pos_sales 與網路訂單整理）
public struct MemberVisit: Codable, Sendable, Hashable, Identifiable {
    public var id: String { ticketId }
    public var ticketId: String
    public var number: String
    public var at: Date
    public var total: Money
    /// 「剪髮」「染髮 6N」
    public var items: [String]
    /// 服務人員的名字
    public var staffNames: [String]
    public var note: String?

    public init(ticketId: String, number: String, at: Date, total: Money, items: [String], staffNames: [String] = [], note: String? = nil) {
        self.ticketId = ticketId; self.number = number; self.at = at; self.total = total; self.items = items
        self.staffNames = staffNames; self.note = note
    }
}

/// PATCH {cms}/api/pos/v1/members/:id（只送要改的）
public struct MemberUpdate: Codable, Sendable, Hashable {
    public var name: String?
    public var note: String?
    public var birthday: String?
    public init(name: String? = nil, note: String? = nil, birthday: String? = nil) { self.name = name; self.note = note; self.birthday = birthday }
}

/// GET {cms}/api/pos/v1/members?phone=0912345678
public struct MemberLookup: Codable, Sendable, Hashable {
    public init(member: Member?) { self.member = member }

    public var member: Member?
}

/// POST {cms}/api/pos/v1/members
public struct MemberCreate: Codable, Sendable {
    public var phone: String
    public var name: String?
    public init(phone: String, name: String?) { self.phone = phone; self.name = name }
}

// MARK: - 折價券（門市）

/// 折價券的種類。`free_shipping`（免運）不能在門市用；不認得的種類照樣讀得進來（後台會給 problem）
public enum CouponType: Codable, Sendable, Hashable {
    /// 折固定金額（value 是分：NT$100＝10000）
    case fixed
    /// 打折（value 是萬分比：9 折＝1000）
    case percentage
    /// 免運、或之後新增的種類
    case other(String)

    public var rawValue: String {
        switch self {
        case .fixed: "fixed"
        case .percentage: "percentage"
        case .other(let s): s
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "fixed": self = .fixed
        case "percentage": self = .percentage
        default: self = .other(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// 一張折價券（和網路商店同一份；後台「折價券」）
public struct Coupon: Codable, Sendable, Hashable {
    /// 大寫英數（YG-A3B2C1）
    public var code: String
    /// 「新會員 100 元」
    public var name: String
    public var description: String?
    public var type: CouponType
    /// fixed：分；percentage：萬分比
    public var value: Int
    /// 最低消費（小計，分）；沒有＝不限
    public var minimumOrder: Money?
    public var expiresAt: Date?
    /// 還能用幾次（沒有＝不限）
    public var usesLeft: Int?

    public init(code: String, name: String, description: String? = nil, type: CouponType, value: Int, minimumOrder: Money? = nil,
                expiresAt: Date? = nil, usesLeft: Int? = nil) {
        self.code = code; self.name = name; self.description = description; self.type = type; self.value = value
        self.minimumOrder = minimumOrder; self.expiresAt = expiresAt; self.usesLeft = usesLeft
    }

    /// 畫面、收據上的名字：「新會員 100 元」（沒取名字的用代碼）
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? code : n
    }

    /// 整單折扣的原因：「折價券 新會員 100 元」
    public var reason: String { "折價券 \(displayName)" }

    /// 套到單子上的整單折扣（帶著代碼與最低消費）；免運、不認得的種類是 nil（門市不能用）
    public var discount: Discount? {
        let min = (minimumOrder?.cents ?? 0) > 0 ? minimumOrder : nil
        switch type {
        case .fixed:
            guard value > 0 else { return nil }
            return Discount(kind: .amount, value: value, reason: reason, couponCode: code, minimumOrder: min)
        case .percentage:
            guard value > 0, value <= 10_000 else { return nil }
            return Discount(kind: .percent, value: value, reason: reason, couponCode: code, minimumOrder: min)
        case .other:
            return nil
        }
    }
}

/// GET {cms}/api/pos/v1/coupons/:code?subtotal=12000&memberId=…：
/// `problem` 是不能用的原因（給店員看的一句：「已經過期（10/1）」「未達最低消費 NT$500」）；null＝可以用。
/// 沒有這張券是 404 not_found（POSClient.coupon 回 nil）
public struct CouponLookup: Codable, Sendable, Hashable {
    public var coupon: Coupon
    public var problem: String?

    public init(coupon: Coupon, problem: String? = nil) {
        self.coupon = coupon
        self.problem = problem
    }

    enum CodingKeys: String, CodingKey { case coupon, problem }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coupon = try c.decode(Coupon.self, forKey: .coupon)
        let p = try c.decodeIfPresent(String.self, forKey: .problem)?.trimmingCharacters(in: .whitespacesAndNewlines)
        problem = (p?.isEmpty ?? true) ? nil : p
    }

    /// 和 docs/API.md 的範例一樣：可以用的時候也寫 `"problem": null`
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coupon, forKey: .coupon)
        try c.encode(problem, forKey: .problem)
    }
}

// MARK: - 主管授權（後台驗 PIN）

/// POST {cms}/api/pos/v1/staff/verify-pin：個人的裝置拿不到 PIN 雜湊，主管授權改問後台（docs/API.md「用 StudioX 帳號登入」第 5 步）。
/// 錯了 `401 wrong_pin`；同一台 10 分鐘錯 5 次 `429 rate_limited`（鎖 10 分鐘）
public struct VerifyPinRequest: Codable, Sendable, Hashable {
    /// 省略＝看 PIN 對到誰（兩個人一樣，後台取職能最高的）
    public var staffId: String?
    public var pin: String
    /// 要授權什麼（Permission 的 rawValue：voidTicket、refund、largeDiscount…）
    public var purpose: String

    public init(staffId: String? = nil, pin: String, purpose: String) {
        self.staffId = staffId; self.pin = pin; self.purpose = purpose
    }
}

/// PIN 對到的人
public struct VerifiedStaff: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// cashier｜supervisor｜manager｜owner；用字串收：不認得的值也不會讓整個回應讀不進來（當作收銀，見 staffRole）
    public var role: String

    public init(id: String, name: String, role: String) {
        self.id = id; self.name = name; self.role = role
    }

    /// 不認得的職能當作最低的（收銀）：寧可再問一次，不要多給權限
    public var staffRole: StaffRole { StaffRole(rawValue: role) ?? .cashier }
}

public struct VerifyPinResponse: Codable, Sendable, Hashable {
    public var staff: VerifiedStaff
    public init(staff: VerifiedStaff) { self.staff = staff }
}

// MARK: - 訂位與候位

public enum ReservationKind: String, Codable, Sendable, Hashable {
    /// 訂位（有時間）
    case reservation
    /// 現場候位（抽號碼）
    case waitlist
    /// 預約服務（美業的設計師、私人教練）：有服務項目、指定的人、時間長度
    case appointment
    /// 團體課報名（瑜珈、飛輪）
    case classBooking

    public var label: String {
        switch self {
        case .reservation: "訂位"
        case .waitlist: "候位"
        case .appointment: "預約"
        case .classBooking: "課程報名"
        }
    }
}

public enum ReservationStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case booked
    /// 通知了（候位叫號簡訊）
    case notified
    case arrived
    case seated
    case cancelled
    case noShow

    public var label: String {
        switch self {
        case .booked: "已預約"
        case .notified: "已通知"
        case .arrived: "已到店"
        case .seated: "已入座"
        case .cancelled: "已取消"
        case .noShow: "未到"
        }
    }

    public var isActive: Bool { [.booked, .notified, .arrived].contains(self) }

    /// 依種類換說法：訂位「已入座」、預約「服務中」、課程「已報到」
    public func label(for kind: ReservationKind) -> String {
        switch (kind, self) {
        case (.appointment, .seated): "服務中"
        case (.classBooking, .seated), (.classBooking, .arrived): "已報到"
        default: label
        }
    }
}

/// 預約的服務項目
public struct BookedService: Codable, Sendable, Hashable {
    public var itemId: String
    public var name: String
    public var durationMinutes: Int
    /// 這一項由誰做（沒指定就是預約上的 staffId）
    public var staffId: String?
    public var price: Money?

    public init(itemId: String, name: String, durationMinutes: Int, staffId: String? = nil, price: Money? = nil) {
        self.itemId = itemId; self.name = name; self.durationMinutes = durationMinutes; self.staffId = staffId; self.price = price
    }
}

public struct Reservation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ReservationKind
    public var name: String
    public var phone: String
    public var partySize: Int
    /// 訂位的時間（候位是抽號碼的時間）
    public var startsAt: Date
    public var durationMinutes: Int
    public var tableIds: [String]
    public var status: ReservationStatus
    public var note: String
    /// pos｜admin｜web｜phone
    public var source: String
    /// 候位號碼
    public var queueNumber: Int?
    public var notifiedAt: Date?
    public var createdAt: Date
    /// 指定的服務人員（設計師、教練；nil = 不指定）
    public var staffId: String?
    /// 預約的服務項目
    public var services: [BookedService]?
    public var memberId: String?
    /// 團體課（classBooking）
    public var sessionId: String?
    /// 到店後開的單
    public var ticketId: String?

    public init(id: String, kind: ReservationKind, name: String, phone: String, partySize: Int, startsAt: Date, durationMinutes: Int = 90,
                tableIds: [String] = [], status: ReservationStatus = .booked, note: String = "", source: String = "pos",
                queueNumber: Int? = nil, notifiedAt: Date? = nil, createdAt: Date, staffId: String? = nil, services: [BookedService]? = nil,
                memberId: String? = nil, sessionId: String? = nil, ticketId: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.phone = phone; self.partySize = partySize; self.startsAt = startsAt
        self.durationMinutes = durationMinutes; self.tableIds = tableIds; self.status = status; self.note = note; self.source = source
        self.queueNumber = queueNumber; self.notifiedAt = notifiedAt; self.createdAt = createdAt
        self.staffId = staffId; self.services = services; self.memberId = memberId; self.sessionId = sessionId; self.ticketId = ticketId
    }

    public var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) }

    /// 跟另一筆時間重疊
    public func overlaps(_ other: Reservation) -> Bool { startsAt < other.endsAt && other.startsAt < endsAt }

    /// 這個人這段時間被約走了沒（預約表排班用；取消、未到、做完的不算）
    public static func conflicts(staffId: String, start: Date, minutes: Int, in list: [Reservation], ignoring id: String? = nil) -> [Reservation] {
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return list.filter { r in
            r.id != id && r.kind == .appointment && r.status.isActive && r.staffId == staffId && r.startsAt < end && start < r.endsAt
        }
    }
}

/// 團體課的一堂（後台「門市 POS → 課表」排的）
public struct ClassSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// 教練
    public var staffId: String?
    public var startsAt: Date
    public var durationMinutes: Int
    /// 名額（0 = 不限）
    public var capacity: Int
    /// 已報名（不含取消）
    public var booked: Int
    /// 教室
    public var room: String?
    /// 哪些課程卡、會籍可以用（PassSpec 的 itemIds 對到這個 id 或分類）
    public var itemId: String?
    /// 單堂價（沒有卡的人現場付）
    public var dropInPrice: Money?
    public var note: String?

    public init(id: String, name: String, staffId: String? = nil, startsAt: Date, durationMinutes: Int = 60, capacity: Int = 0, booked: Int = 0,
                room: String? = nil, itemId: String? = nil, dropInPrice: Money? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.staffId = staffId; self.startsAt = startsAt; self.durationMinutes = durationMinutes
        self.capacity = capacity; self.booked = booked; self.room = room; self.itemId = itemId; self.dropInPrice = dropInPrice; self.note = note
    }

    public var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    public var isFull: Bool { capacity > 0 && booked >= capacity }
    public var spotsLeft: Int? { capacity > 0 ? max(capacity - booked, 0) : nil }
}

/// GET {cms}/api/pos/v1/classes?date=2026-10-04
public struct ClassList: Codable, Sendable, Hashable {
    public var classes: [ClassSession]
    public init(classes: [ClassSession]) { self.classes = classes }
}

/// GET {cms}/api/pos/v1/reservations?date=2026-10-03
public struct ReservationList: Codable, Sendable, Hashable {
    public init(reservations: [Reservation]) { self.reservations = reservations }

    public var reservations: [Reservation]
}

/// POST {cms}/api/pos/v1/reservations、PATCH {cms}/api/pos/v1/reservations/:id（只送要改的欄位）
public struct ReservationInput: Codable, Sendable, Hashable {
    public var kind: ReservationKind?
    public var name: String?
    public var phone: String?
    public var partySize: Int?
    public var startsAt: Date?
    public var durationMinutes: Int?
    public var tableIds: [String]?
    public var status: ReservationStatus?
    public var note: String?
    public var staffId: String?
    public var services: [BookedService]?
    public var memberId: String?
    public var sessionId: String?
    public var ticketId: String?

    public init(kind: ReservationKind? = nil, name: String? = nil, phone: String? = nil, partySize: Int? = nil, startsAt: Date? = nil,
                durationMinutes: Int? = nil, tableIds: [String]? = nil, status: ReservationStatus? = nil, note: String? = nil,
                staffId: String? = nil, services: [BookedService]? = nil, memberId: String? = nil, sessionId: String? = nil, ticketId: String? = nil) {
        self.kind = kind; self.name = name; self.phone = phone; self.partySize = partySize; self.startsAt = startsAt
        self.durationMinutes = durationMinutes; self.tableIds = tableIds; self.status = status; self.note = note
        self.staffId = staffId; self.services = services; self.memberId = memberId; self.sessionId = sessionId; self.ticketId = ticketId
    }
}

public struct ReservationResponse: Codable, Sendable, Hashable {
    public init(reservation: Reservation) { self.reservation = reservation }

    public var reservation: Reservation
}

// MARK: - 叫號（號碼牌）

/// 號碼存在哪裡（後台「叫號」的設定）
public enum QueueMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// 原本的叫號伺服器（黃毛丫頭的 Flask）：後台代轉。沒有取號、叫號的時間，也不能「再叫一次」過號的
    case legacy
    /// 後台自己的資料庫：有取號時間、今天服務了幾位，過號的可以再叫一次
    case native

    public var label: String {
        switch self {
        case .legacy: "原本的叫號伺服器"
        case .native: "後台"
        }
    }

    /// 過號的可以再叫一次（舊伺服器沒有這個動作，會回 409 unsupported）
    public var canRecall: Bool { self == .native }

    // 新版後台多了這版不認得的模式：當作後台自己的（不認得的動作後台會回錯，畫面照常）
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QueueMode(rawValue: raw) ?? .native
    }
}

/// 號碼牌的版面（iPad 直接印，不用樹莓派）。座標都以 58 mm 的 384 點寬為準（80 mm 的機器等比放大）；
/// 預設值和樹莓派原本印的一模一樣（pi-display/app.py 的 compose_ticket_image）
public struct QueueTicketLayout: Codable, Sendable, Hashable {
    /// 字的顏色（背景圖上的黑框裡用白字）
    public enum Ink: String, Codable, Sendable, Hashable {
        case white, black

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Ink(rawValue: raw.lowercased()) ?? .black
        }
    }

    /// 一行字，水平置中：y＝字型 ascender 線的位置（和 PIL 的 draw.text 一樣，不是字的上緣）
    public struct Line: Codable, Sendable, Hashable {
        public var y: Double
        public var size: Double
        public var color: Ink
        /// 字（{waiting}、{number} 會被換掉）；號碼那一行沒有
        public var text: String?

        public init(y: Double, size: Double, color: Ink, text: String? = nil) {
            self.y = y; self.size = size; self.color = color; self.text = text
        }
    }

    public struct QR: Codable, Sendable, Hashable {
        /// 邊長＝size × 384（0.45 → 172 點）
        public var size: Double
        /// 下緣離紙的底部幾點
        public var bottom: Double

        public init(size: Double, bottom: Double) { self.size = size; self.bottom = bottom }
    }

    /// 背景圖（照比例裁滿 384×height、置中）；沒有就用 iPad 自己的版面
    public var backgroundUrl: String?
    /// 紙的長度（點，384 寬時）
    public var height: Int
    /// 一個號碼印幾張
    public var copies: Int
    public var number: Line
    public var waiting: Line
    public var qr: QR

    /// 座標的基準寬度（58 mm）
    public static let baseWidth = 384
    public static let defaultNumber = Line(y: 140, size: 90, color: .white)
    public static let defaultWaiting = Line(y: 290, size: 20, color: .black, text: "目前 {waiting} 人等候中")
    public static let defaultQR = QR(size: 0.45, bottom: 100)
    /// 樹莓派原本的版面（沒有背景圖）
    public static let standard = QueueTicketLayout()

    public init(backgroundUrl: String? = nil, height: Int = 640, copies: Int = 1, number: Line = QueueTicketLayout.defaultNumber,
                waiting: Line = QueueTicketLayout.defaultWaiting, qr: QR = QueueTicketLayout.defaultQR) {
        self.backgroundUrl = backgroundUrl
        self.height = height
        self.copies = copies
        self.number = number
        self.waiting = waiting
        self.qr = qr
    }

    enum CodingKeys: String, CodingKey { case backgroundUrl, height, copies, number, waiting, qr }

    /// 只寫了一部分的 Line、QR：沒寫的用預設
    private struct LinePatch: Decodable {
        var y: Double?
        var size: Double?
        var color: Ink?
        var text: String?

        func applied(to base: Line) -> Line {
            Line(y: y ?? base.y, size: size ?? base.size, color: color ?? base.color, text: text ?? base.text)
        }
    }

    private struct QRPatch: Decodable {
        var size: Double?
        var bottom: Double?
    }

    // 後台少給、給錯的欄位都用預設：號碼牌一定印得出來
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = (try? c.decodeIfPresent(String.self, forKey: .backgroundUrl))?.trimmingCharacters(in: .whitespacesAndNewlines)
        backgroundUrl = (url?.isEmpty ?? true) ? nil : url
        height = min(max((try? c.decodeIfPresent(Int.self, forKey: .height)) ?? 640, 200), 2000)
        copies = min(max((try? c.decodeIfPresent(Int.self, forKey: .copies)) ?? 1, 1), 5)
        number = ((try? c.decodeIfPresent(LinePatch.self, forKey: .number)) ?? nil)?.applied(to: Self.defaultNumber) ?? Self.defaultNumber
        waiting = ((try? c.decodeIfPresent(LinePatch.self, forKey: .waiting)) ?? nil)?.applied(to: Self.defaultWaiting) ?? Self.defaultWaiting
        let q = (try? c.decodeIfPresent(QRPatch.self, forKey: .qr)) ?? nil
        qr = QR(size: min(max(q?.size ?? Self.defaultQR.size, 0.1), 1), bottom: max(q?.bottom ?? Self.defaultQR.bottom, 0))
    }

    /// 等候人數那一行（「目前 5 人等候中」）
    public func waitingText(waiting count: Int, number n: Int) -> String {
        (waiting.text ?? "目前 {waiting} 人等候中")
            .replacingOccurrences(of: "{waiting}", with: String(count))
            .replacingOccurrences(of: "{number}", with: String(n))
    }

    /// QR 的邊長（384 寬時；樹莓派是 int(384 × 0.45) = 172）
    public var qrSide: Int { Int(Double(Self.baseWidth) * qr.size) }
}

/// 開機資料的 `queue`：號碼存在哪裡、號碼牌的 QR 網址與版面
/// 叫號用在哪裡（可以兩個都開）。都沒開＝只有「叫號」頁，店員自己取號、叫號
public enum QueueUsage: String, Codable, Sendable, Hashable, CaseIterable {
    /// 全外帶（黃毛丫頭）：外帶單結帳完成時自動取號、印號碼牌，做好了在右欄叫號
    case takeout
    /// 排隊等內用：取號時打人數，叫到號時選桌入座
    case dineIn

    public var label: String {
        switch self {
        case .takeout: "外帶取餐"
        case .dineIn: "排隊等內用"
        }
    }
}

public struct QueueConfig: Codable, Sendable, Hashable {
    public var mode: QueueMode
    /// 號碼牌 QR 的網址樣板：{number}、{waiting} 會被換掉（例：https://shop.tw/q?no={number}&waiting={waiting}）
    public var customerUrl: String?
    public var ticket: QueueTicketLayout
    /// 用在哪裡（看不懂的值略過）
    public var usage: Set<QueueUsage>

    public init(mode: QueueMode = .native, customerUrl: String? = nil, ticket: QueueTicketLayout = .standard, usage: Set<QueueUsage> = []) {
        self.mode = mode
        self.customerUrl = customerUrl
        self.ticket = ticket
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey { case mode, customerUrl, ticket, usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(QueueMode.self, forKey: .mode)) ?? .native
        let url = (try? c.decodeIfPresent(String.self, forKey: .customerUrl))?.trimmingCharacters(in: .whitespacesAndNewlines)
        customerUrl = (url?.isEmpty ?? true) ? nil : url
        ticket = ((try? c.decodeIfPresent(QueueTicketLayout.self, forKey: .ticket)) ?? nil) ?? .standard
        let raw = ((try? c.decodeIfPresent([String].self, forKey: .usage)) ?? nil) ?? []
        usage = Set(raw.compactMap(QueueUsage.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(customerUrl, forKey: .customerUrl)
        try c.encode(ticket, forKey: .ticket)
        if !usage.isEmpty { try c.encode(QueueUsage.allCases.filter(usage.contains).map(\.rawValue), forKey: .usage) }
    }

    /// 號碼牌、收據上的 QR：這個號碼的網址（沒設網址樣板是 nil）。
    /// 樣板可以用 {number}、{waiting}、{date}（營業日 20261005：號碼每天從 1 開始，舊的號碼牌掃了知道是哪一天的）
    public func customerLink(number: Int, waiting: Int, date: String? = nil) -> String? {
        guard let t = customerUrl else { return nil }
        return t.replacingOccurrences(of: "{number}", with: String(number))
            .replacingOccurrences(of: "{waiting}", with: String(waiting))
            .replacingOccurrences(of: "{date}", with: date ?? "")
    }
}

/// GET {cms}/api/pos/v1/queue、POST /queue/<action> 的回應：現在的號碼。
/// 每個欄位都可能沒有（舊的叫號伺服器只有 current、waiting、missed、marked、next_no）：少了、看不懂的都當作空的
public struct QueueState: Codable, Sendable, Hashable {
    public var mode: QueueMode?
    /// 現在叫到的號碼
    public var current: Int?
    /// 等候中（照順序）
    public var waiting: [Int]
    /// 過號
    public var missed: [Int]
    /// 標記（店員自己看的星號）
    public var marked: [Int]
    /// 下一張號碼牌
    public var nextNo: Int?
    /// current 什麼時候叫的（native）
    public var calledAt: Date?
    public var updatedAt: Date?
    /// 每個等候中的號碼什麼時候取的（native；key 是號碼的字串）
    public var takenAt: [String: Date]
    /// 今天服務完的人數（native）
    public var servedToday: Int?
    /// 取號的回應：這次取到的號碼
    public var numbers: [Int]?
    /// 號碼的附帶資料（native）：幾位、哪一張單（key 是號碼的字串）
    public var entries: [String: QueueEntry]

    public init(mode: QueueMode? = nil, current: Int? = nil, waiting: [Int] = [], missed: [Int] = [], marked: [Int] = [], nextNo: Int? = nil,
                calledAt: Date? = nil, updatedAt: Date? = nil, takenAt: [String: Date] = [:], servedToday: Int? = nil, numbers: [Int]? = nil,
                entries: [String: QueueEntry] = [:]) {
        self.mode = mode; self.current = current; self.waiting = waiting; self.missed = missed; self.marked = marked; self.nextNo = nextNo
        self.calledAt = calledAt; self.updatedAt = updatedAt; self.takenAt = takenAt; self.servedToday = servedToday; self.numbers = numbers
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case mode, current, waiting, missed, marked, nextNo, calledAt, updatedAt, takenAt, servedToday, numbers, entries
        /// 舊伺服器 /status 的寫法
        case nextNoSnake = "next_no"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func ints(_ k: CodingKeys) -> [Int] { ((try? c.decodeIfPresent([Int].self, forKey: k)) ?? nil) ?? [] }
        func date(_ k: CodingKeys) -> Date? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap(EventCoding.parseTimestamp) }
        mode = (try? c.decodeIfPresent(QueueMode.self, forKey: .mode)) ?? nil
        current = (try? c.decodeIfPresent(Int.self, forKey: .current)) ?? nil
        waiting = ints(.waiting)
        missed = ints(.missed)
        marked = ints(.marked)
        nextNo = ((try? c.decodeIfPresent(Int.self, forKey: .nextNo)) ?? nil) ?? ((try? c.decodeIfPresent(Int.self, forKey: .nextNoSnake)) ?? nil)
        calledAt = date(.calledAt)
        updatedAt = date(.updatedAt)
        let raw = ((try? c.decodeIfPresent([String: String].self, forKey: .takenAt)) ?? nil) ?? [:]
        takenAt = raw.compactMapValues(EventCoding.parseTimestamp)
        servedToday = (try? c.decodeIfPresent(Int.self, forKey: .servedToday)) ?? nil
        numbers = (try? c.decodeIfPresent([Int].self, forKey: .numbers)) ?? nil
        entries = ((try? c.decodeIfPresent([String: QueueEntry].self, forKey: .entries)) ?? nil) ?? [:]
    }

    // 選填的沒有值就不出現；時間一律是 ISO 8601（UTC、毫秒）
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(current, forKey: .current)
        try c.encode(waiting, forKey: .waiting)
        try c.encode(missed, forKey: .missed)
        try c.encode(marked, forKey: .marked)
        try c.encodeIfPresent(nextNo, forKey: .nextNo)
        try c.encodeIfPresent(calledAt.map(EventCoding.timestamp), forKey: .calledAt)
        try c.encodeIfPresent(updatedAt.map(EventCoding.timestamp), forKey: .updatedAt)
        if !takenAt.isEmpty { try c.encode(takenAt.mapValues(EventCoding.timestamp), forKey: .takenAt) }
        try c.encodeIfPresent(servedToday, forKey: .servedToday)
        try c.encodeIfPresent(numbers, forKey: .numbers)
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
    }

    /// 這個號碼的附帶資料（幾位、哪一張單）
    public func entry(_ n: Int) -> QueueEntry? { entries[String(n)] }

    /// 沒有人在等、也沒有在叫、沒有過號
    public var isEmpty: Bool { current == nil && waiting.isEmpty && missed.isEmpty }

    public func isMarked(_ n: Int) -> Bool { marked.contains(n) }

    /// 這個號碼什麼時候取的（native）
    public func takenTime(of n: Int) -> Date? { takenAt[String(n)] }

    /// 等了幾分鐘（沒有取號時間是 nil）
    public func waitMinutes(_ n: Int, now: Date) -> Int? {
        takenTime(of: n).map { max(Int(now.timeIntervalSince($0) / 60), 0) }
    }

    /// 還在等的人平均等了幾分鐘（沒有取號時間是 nil）
    public func averageWaitMinutes(now: Date) -> Int? {
        let minutes = waiting.compactMap { waitMinutes($0, now: now) }
        guard !minutes.isEmpty else { return nil }
        return Int((Double(minutes.reduce(0, +)) / Double(minutes.count)).rounded())
    }

    /// 今天取了幾張（號碼每天從 1 開始：下一張減 1）
    public var takenToday: Int? { nextNo.map { max($0 - 1, 0) } }

    /// 目前用到的最大號碼（號碼從 1 重新開始時會變小）
    public var highestNumber: Int {
        let seen = (waiting + missed + [current ?? 0]).max() ?? 0
        return max(seen, (nextNo ?? 1) - 1)
    }
}

/// 一個號碼的附帶資料：排隊等內用的人數、外帶單（取號時帶上；舊的叫號伺服器沒有）
public struct QueueEntry: Codable, Sendable, Hashable {
    /// 幾位（排隊等內用）
    public var guests: Int?
    /// 哪一張單（外帶結帳時自動取號的）
    public var ticketId: String?
    /// 給人看的一句（「A012・3 項」）
    public var label: String?

    public init(guests: Int? = nil, ticketId: String? = nil, label: String? = nil) {
        self.guests = guests; self.ticketId = ticketId; self.label = label
    }
}

/// POST {cms}/api/pos/v1/queue/<action> 的 body
public struct QueueActionBody: Codable, Sendable, Hashable {
    public var count: Int?
    public var requestId: String?
    public var number: Int?
    public var staffId: String?
    /// 取號時帶的附帶資料（一次只取一張時）
    public var guests: Int?
    public var ticketId: String?
    public var label: String?

    public init(count: Int? = nil, requestId: String? = nil, number: Int? = nil, staffId: String? = nil,
                guests: Int? = nil, ticketId: String? = nil, label: String? = nil) {
        self.count = count; self.requestId = requestId; self.number = number; self.staffId = staffId
        self.guests = guests; self.ticketId = ticketId; self.label = label
    }
}

/// 叫號的動作（docs/API.md「叫號」）：回應一律是改完的 QueueState
public enum QueueAction: Sendable, Hashable {
    /// 取號：nextNo 起連續 count 張（1–20）加到最後；同一個 requestId 十分鐘內重送不會再取
    case take(count: Int, requestId: String)
    /// 叫下一號（原本的 current 算服務完了）
    case next(requestId: String)
    /// 過號：current 移到過號，自動叫下一號
    case miss(requestId: String)
    /// 返回前一號：current 放回等候的最前面
    case previous
    /// 再叫一次過號的（只有 native）
    case recall(Int)
    /// 從過號清單刪掉
    case unmiss(Int)
    case mark(Int)
    case unmark(Int)
    /// 全部歸零（店長授權過）
    case reset(staffId: String)
    /// 取一張、帶附帶資料：排隊等內用（幾位）、外帶結帳（哪一張單）
    case takeOne(entry: QueueEntry, requestId: String)
    /// 叫指定的號碼（外帶：先做好的先叫）：等候中的那一號變成 current（只有 native）
    case call(Int, requestId: String)
    /// 放回號碼：這張單作廢了，號碼從等候、過號拿掉（叫號螢幕不再列它；只有 native）
    case cancel(Int, requestId: String)

    /// POST /queue/<path>
    public var path: String {
        switch self {
        case .take: "take"
        case .next: "next"
        case .miss: "miss"
        case .previous: "previous"
        case .recall: "recall"
        case .unmiss: "unmiss"
        case .mark: "mark"
        case .unmark: "unmark"
        case .reset: "reset"
        case .takeOne: "take"
        case .call: "call"
        case .cancel: "cancel"
        }
    }

    public var body: QueueActionBody {
        switch self {
        case .take(let count, let id): QueueActionBody(count: min(max(count, 1), 20), requestId: id)
        case .next(let id), .miss(let id): QueueActionBody(requestId: id)
        case .previous: QueueActionBody()
        case .recall(let n), .unmiss(let n), .mark(let n), .unmark(let n): QueueActionBody(number: n)
        case .reset(let staffId): QueueActionBody(staffId: staffId)
        case .takeOne(let e, let id): QueueActionBody(count: 1, requestId: id, guests: e.guests, ticketId: e.ticketId, label: e.label)
        case .call(let n, let id), .cancel(let n, let id): QueueActionBody(requestId: id, number: n)
        }
    }
}

// MARK: - 桌位圖、心跳

/// PUT {cms}/api/pos/v1/floor
public struct FloorUpdate: Codable, Sendable {
    public var areas: [FloorArea]
    /// 誰改的（店長 PIN 授權過）
    public var staffId: String
    public init(areas: [FloorArea], staffId: String) { self.areas = areas; self.staffId = staffId }
}

public struct FloorResponse: Codable, Sendable, Hashable {
    public init(floor: FloorPlan, version: String) { self.floor = floor; self.version = version }

    public var floor: FloorPlan
    public var version: String
}

public struct PrinterHealth: Codable, Sendable, Hashable {
    public var name: String
    public var ok: Bool
    public var message: String?
    public init(name: String, ok: Bool, message: String? = nil) { self.name = name; self.ok = ok; self.message = message }
}

/// POST {cms}/api/pos/v1/heartbeat：每分鐘一次（後台「裝置」頁看得到誰在線、誰有沒送出去的單）
public struct Heartbeat: Codable, Sendable {
    public var appVersion: String
    /// 還沒送到後台的事件數
    public var outbox: Int
    public var lastSeq: Int
    public var printers: [PrinterHealth]
    public var battery: Double?
    public var openTickets: Int
    public var staffId: String?
    /// 這台現在的崗位（店長在 iPad 上改過才和後台的不一樣）
    public var workstation: DeviceRole?
    public init(appVersion: String, outbox: Int, lastSeq: Int, printers: [PrinterHealth], battery: Double?, openTickets: Int, staffId: String?,
                workstation: DeviceRole? = nil) {
        self.appVersion = appVersion; self.outbox = outbox; self.lastSeq = lastSeq; self.printers = printers
        self.battery = battery; self.openTickets = openTickets; self.staffId = staffId; self.workstation = workstation
    }
}

public struct HeartbeatResponse: Codable, Sendable, Hashable {
    public init(serverTime: Date, configVersion: String, serverSeq: Int) { self.serverTime = serverTime; self.configVersion = configVersion; self.serverSeq = serverSeq }

    public var serverTime: Date
    /// 設定版本：和手上的不同就重抓 bootstrap
    public var configVersion: String
    /// 後台的 serverSeq：比手上的新就拉事件
    public var serverSeq: Int
}

// MARK: - 歷史（後台存的；iPad 只留最近兩天）

/// 一筆退款屬於哪張單
public struct TicketRefund: Codable, Sendable, Hashable {
    public var ticketId: String
    public var refund: Refund
    public init(ticketId: String, refund: Refund) { self.ticketId = ticketId; self.refund = refund }
}

/// 作廢的單（報表的「作廢」）
public struct VoidedTicketSummary: Codable, Sendable, Hashable {
    public var ticketId: String
    public var number: String
    public var items: Int
    public var amount: Money
    public var reason: String
    public init(ticketId: String, number: String, items: Int, amount: Money, reason: String) {
        self.ticketId = ticketId; self.number = number; self.items = items; self.amount = amount; self.reason = reason
    }
}

/// GET {cms}/api/pos/v1/history?date=2026-10-03：那一個營業日所有裝置的結帳、退款、作廢、發票。
/// sales 是 ticket.closed 事件裡的 SaleRecord 原樣（後台不重算）；報表用同一套 SalesSummary 在 iPad 上算
public struct DayHistory: Codable, Sendable, Hashable {
    public var businessDate: String
    public var sales: [SaleRecord]
    public var refunds: [TicketRefund]
    public var voidedTickets: [VoidedTicketSummary]
    /// 那天開的發票號碼（含之後作廢的）
    public var invoiceNumbers: [String]
    public var voidedInvoiceNumbers: [String]
    public var checkIns: Int

    public init(businessDate: String, sales: [SaleRecord] = [], refunds: [TicketRefund] = [], voidedTickets: [VoidedTicketSummary] = [],
                invoiceNumbers: [String] = [], voidedInvoiceNumbers: [String] = [], checkIns: Int = 0) {
        self.businessDate = businessDate; self.sales = sales; self.refunds = refunds; self.voidedTickets = voidedTickets
        self.invoiceNumbers = invoiceNumbers; self.voidedInvoiceNumbers = voidedInvoiceNumbers; self.checkIns = checkIns
    }

    /// 那天的報表（和 iPad 上今天的報表同一套算法）
    public var summary: SalesSummary {
        SalesSummary(sales: sales, refunds: refunds.map(\.refund), voidedTicketCount: voidedTickets.count,
                     voidedTicketItems: voidedTickets.reduce(0) { $0 + $1.items }, voidedTicketAmount: Money.sum(voidedTickets.map(\.amount)),
                     invoiceNumbers: invoiceNumbers, voidedInvoiceCount: voidedInvoiceNumbers.count, checkIns: checkIns)
    }

    /// 某張單的退款
    public func refunds(of ticketId: String) -> [Refund] { refunds.filter { $0.ticketId == ticketId }.map(\.refund) }
}

/// 錯誤：{ "error": "revoked", "message": "這台裝置已經被移除" }
public struct APIErrorBody: Codable, Sendable, Hashable {
    public var error: String
    public var message: String?
}
