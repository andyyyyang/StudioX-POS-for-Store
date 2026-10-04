import Foundation
import POSCore
import POSInvoice

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

/// POST {console}/api/pos/resolve：8 位數配對碼 → 這家店的後台網址（接 StudioX 的店家不用打網址）
public struct ResolveRequest: Codable, Sendable { public var code: String; public init(code: String) { self.code = code } }
public struct ResolveResponse: Codable, Sendable, Hashable {
    public init(cmsUrl: String, siteName: String) { self.cmsUrl = cmsUrl; self.siteName = siteName }

    public var cmsUrl: String
    public var siteName: String
}

/// POST {cms}/api/pos/v1/pair
public struct PairRequest: Codable, Sendable {
    public var code: String
    public var device: DeviceInfo
    public init(code: String, device: DeviceInfo) { self.code = code; self.device = device }
}

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
    public init(id: String, name: String, code: String, role: DeviceRole, stations: [String]) {
        self.id = id; self.name = name; self.code = code; self.role = role; self.stations = stations
    }

    public var id: String
    public var name: String
    public var code: String
    public var role: DeviceRole
    /// 廚房螢幕只看哪些出單站（空的＝全部）
    public var stations: [String]
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
                floor: FloorPlan, staff: [StaffMember], invoice: InvoiceSettings, mesh: MeshConfig) {
        self.version = version; self.serverTime = serverTime; self.device = device; self.store = store; self.features = features
        self.catalog = catalog; self.floor = floor; self.staff = staff; self.invoice = invoice; self.mesh = mesh
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
