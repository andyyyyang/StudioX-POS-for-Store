import Foundation
import POSCore
import POSInvoice

// iPad ↔ 後台（atelier-cms 的「門市 POS」服務插件）的資料格式。和 docs/API.md 一一對應，改這裡就要改那裡。
// 金額一律是整數「分」；時間一律是 ISO 8601（UTC、毫秒）；JSON 的 key 是 camelCase。

/// 裝置的角色
public enum DeviceRole: String, Codable, Sendable, CaseIterable, Hashable {
    /// 櫃台收銀（有錢櫃、出單機）
    case register
    /// 手持點餐（桌邊點餐、不收現金）
    case handheld
    /// 廚房螢幕（只看出單、按出餐）
    case kitchen

    public var label: String {
        switch self {
        case .register: "收銀機"
        case .handheld: "點餐機"
        case .kitchen: "廚房螢幕"
        }
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
    /// 店家看得到的備註（過敏、偏好）
    public var note: String?

    public init(id: String, phone: String, name: String?, tierName: String?, lifetimeSpend: Money, visits: Int, lastVisitAt: Date?, note: String?) {
        self.id = id; self.phone = phone; self.name = name; self.tierName = tierName
        self.lifetimeSpend = lifetimeSpend; self.visits = visits; self.lastVisitAt = lastVisitAt; self.note = note
    }

    public var ref: MemberRef { MemberRef(id: id, phone: phone, name: name, tierName: tierName) }
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

    public init(id: String, kind: ReservationKind, name: String, phone: String, partySize: Int, startsAt: Date, durationMinutes: Int = 90,
                tableIds: [String] = [], status: ReservationStatus = .booked, note: String = "", source: String = "pos",
                queueNumber: Int? = nil, notifiedAt: Date? = nil, createdAt: Date) {
        self.id = id; self.kind = kind; self.name = name; self.phone = phone; self.partySize = partySize; self.startsAt = startsAt
        self.durationMinutes = durationMinutes; self.tableIds = tableIds; self.status = status; self.note = note; self.source = source
        self.queueNumber = queueNumber; self.notifiedAt = notifiedAt; self.createdAt = createdAt
    }
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

    public init(kind: ReservationKind? = nil, name: String? = nil, phone: String? = nil, partySize: Int? = nil, startsAt: Date? = nil,
                durationMinutes: Int? = nil, tableIds: [String]? = nil, status: ReservationStatus? = nil, note: String? = nil) {
        self.kind = kind; self.name = name; self.phone = phone; self.partySize = partySize; self.startsAt = startsAt
        self.durationMinutes = durationMinutes; self.tableIds = tableIds; self.status = status; self.note = note
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
    public init(appVersion: String, outbox: Int, lastSeq: Int, printers: [PrinterHealth], battery: Double?, openTickets: Int, staffId: String?) {
        self.appVersion = appVersion; self.outbox = outbox; self.lastSeq = lastSeq; self.printers = printers
        self.battery = battery; self.openTickets = openTickets; self.staffId = staffId
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

/// 錯誤：{ "error": "revoked", "message": "這台裝置已經被移除" }
public struct APIErrorBody: Codable, Sendable, Hashable {
    public var error: String
    public var message: String?
}
