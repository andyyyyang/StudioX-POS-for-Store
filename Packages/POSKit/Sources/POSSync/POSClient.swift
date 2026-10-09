import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import POSCore

/// 後台 API 的錯誤（App 依這個決定要重試、回登入畫面、還是提示）
public enum APIError: Error, Equatable, Sendable {
    /// 沒網路、逾時：等一下再試
    case offline(String)
    /// token 不對：回登入畫面
    case unauthorized
    /// 後台移除了這台：清資料、回登入畫面
    case revoked
    /// 個人裝置綁的門市人員被停用（401 staff_inactive）：還沒送的帳要留著，不能清資料
    case staffInactive
    /// StudioX 沒開通／店家暫停了門市 POS：照常營業，提示「後台暫停同步」
    case serviceOff
    case notModified
    case http(status: Int, code: String, message: String?)
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        case .offline: true
        case .http(let s, _, _): s >= 500 || s == 429
        default: false
        }
    }

    public var userMessage: String {
        switch self {
        case .offline: "沒有網路，先存在這台，連上後自動補送"
        case .unauthorized: "這台的登入失效了，請重新配對"
        case .revoked: "這台已經從後台移除"
        case .staffInactive: "你在這家店的門市人員被停用了，請找店長"
        case .serviceOff: "後台暫停了門市 POS 的同步（這台照常可以用）"
        case .notModified: "沒有變更"
        case .http(_, _, let m): m ?? "後台出了點問題，稍後自動重試"
        case .decoding: "後台回的資料看不懂，請更新 App"
        }
    }
}

/// 後台要提供的功能（測試、示範模式用假的）
public protocol POSAPI: Sendable {
    func bootstrap(ifNoneMatch version: String?) async throws -> Bootstrap
    func push(_ events: [POSEvent]) async throws -> EventsPushResult
    func pull(after serverSeq: Int, limit: Int) async throws -> EventsPage
    func requestRoll(period: String, count: Int) async throws -> RollResponse
    func heartbeat(_ h: Heartbeat) async throws -> HeartbeatResponse
    func member(phone: String) async throws -> Member?
    func createMember(_ m: MemberCreate) async throws -> Member
    func reservations(date: String) async throws -> [Reservation]
    func createReservation(_ input: ReservationInput) async throws -> Reservation
    func updateReservation(id: String, _ input: ReservationInput) async throws -> Reservation
    func notifyReservation(id: String) async throws
    func saveFloor(_ update: FloorUpdate) async throws -> FloorResponse
    /// 改會員的名字、備註（配方、偏好）
    func updateMember(id: String, _ update: MemberUpdate) async throws -> Member
    /// 那一天的團體課（健身、瑜珈）
    func classes(date: String) async throws -> [ClassSession]
    /// 某個營業日的結帳、退款、作廢（iPad 只留最近兩天，更早的跟後台要）
    func history(date: String) async throws -> DayHistory
    /// 叫號：現在的號碼
    func queue() async throws -> QueueState
    /// 叫號的動作（取號、下一號、過號…）：回應是改完的狀態
    func queue(_ action: QueueAction) async throws -> QueueState
    /// 門市折價券：能不能用在這張單（subtotal：整單折扣前的小計）。沒有這張券＝nil；斷線丟 APIError.offline（App 不套用）
    func coupon(code: String, subtotal: Money, memberId: String?) async throws -> CouponLookup?
    /// 主管授權問後台（個人的裝置沒有 PIN 雜湊）：PIN 對到的人（staffId 省略＝看 PIN 對到誰）。
    /// PIN 不對丟 `.http(401, "wrong_pin", "PIN 不對")`；錯太多次 `.http(429, "rate_limited", …)`；斷線 `.offline`
    func verifyPin(staffId: String?, pin: String, purpose: String) async throws -> VerifiedStaff
    /// 外送平台（DeliveryAPI.swift）：各平台的狀態
    func delivery() async throws -> DeliveryStateResponse
    /// 外送平台的動作：接單、拒單、出餐好了、忙碌、暫停。另一台先接了丟 `.http(409, "already_accepted", …)`
    func delivery(_ action: DeliveryAction) async throws -> DeliveryActionResult
}

extension POSAPI {
    // 舊的假後台（測試）沒有這些：當作後台還不支援
    public func updateMember(id: String, _ update: MemberUpdate) async throws -> Member {
        throw APIError.http(status: 404, code: "not_found", message: "後台還不支援修改會員")
    }

    public func classes(date: String) async throws -> [ClassSession] { [] }

    public func history(date: String) async throws -> DayHistory {
        throw APIError.http(status: 404, code: "not_found", message: "後台還不支援查歷史資料")
    }

    public func queue() async throws -> QueueState {
        throw APIError.http(status: 404, code: "not_found", message: "後台還不支援叫號")
    }

    public func queue(_ action: QueueAction) async throws -> QueueState {
        throw APIError.http(status: 404, code: "not_found", message: "後台還不支援叫號")
    }

    public func coupon(code: String, subtotal: Money, memberId: String?) async throws -> CouponLookup? {
        throw APIError.http(status: 404, code: "unsupported", message: POSClient.couponsUnsupported)
    }

    public func verifyPin(staffId: String?, pin: String, purpose: String) async throws -> VerifiedStaff {
        throw APIError.http(status: 404, code: "unsupported", message: POSClient.verifyPinUnsupported)
    }
}

extension APIError {
    /// 主管授權問後台時 PIN 不對（401 wrong_pin）
    public static let wrongPinCode = "wrong_pin"
    public static let wrongPinMessage = "PIN 不對"
    public static let pinRateLimitedMessage = "錯太多次了，10 分鐘後再試"

    /// PIN 不對（不是這台的登入失效）
    public var isWrongPin: Bool {
        if case .http(401, Self.wrongPinCode, _) = self { return true }
        return false
    }
}

/// 真的後台（URLSession）
public struct POSClient: POSAPI {
    public let baseURL: URL
    public let token: String
    let session: URLSession

    public init(cmsURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = cmsURL.appendingPathComponent("api/pos/v1")
        self.token = token
        self.session = session
    }

    // MARK: POSAPI

    public func bootstrap(ifNoneMatch version: String?) async throws -> Bootstrap {
        try await call("bootstrap", headers: version.map { ["If-None-Match": "\"\($0)\""] } ?? [:])
    }

    public func push(_ events: [POSEvent]) async throws -> EventsPushResult {
        try await call("events", method: "POST", body: EventsPush(events: events))
    }

    public func pull(after serverSeq: Int, limit: Int = 500) async throws -> EventsPage {
        try await call("events", query: ["after": String(serverSeq), "limit": String(limit)])
    }

    public func requestRoll(period: String, count: Int = 50) async throws -> RollResponse {
        try await call("invoice/rolls", method: "POST", body: RollRequest(period: period, count: count))
    }

    public func heartbeat(_ h: Heartbeat) async throws -> HeartbeatResponse {
        try await call("heartbeat", method: "POST", body: h)
    }

    public func member(phone: String) async throws -> Member? {
        let r: MemberLookup = try await call("members", query: ["phone": phone])
        return r.member
    }

    public func createMember(_ m: MemberCreate) async throws -> Member {
        struct R: Decodable { var member: Member }
        let r: R = try await call("members", method: "POST", body: m)
        return r.member
    }

    public func reservations(date: String) async throws -> [Reservation] {
        let r: ReservationList = try await call("reservations", query: ["date": date])
        return r.reservations
    }

    public func createReservation(_ input: ReservationInput) async throws -> Reservation {
        let r: ReservationResponse = try await call("reservations", method: "POST", body: input)
        return r.reservation
    }

    public func updateReservation(id: String, _ input: ReservationInput) async throws -> Reservation {
        let r: ReservationResponse = try await call("reservations/\(id)", method: "PATCH", body: input)
        return r.reservation
    }

    public func notifyReservation(id: String) async throws {
        struct R: Decodable { var sent: Bool }
        let _: R = try await call("reservations/\(id)/notify", method: "POST", body: [String: String]())
    }

    public func saveFloor(_ update: FloorUpdate) async throws -> FloorResponse {
        try await call("floor", method: "PUT", body: update)
    }

    public func updateMember(id: String, _ update: MemberUpdate) async throws -> Member {
        struct R: Decodable { var member: Member }
        let r: R = try await call("members/\(id)", method: "PATCH", body: update)
        return r.member
    }

    public func classes(date: String) async throws -> [ClassSession] {
        let r: ClassList = try await call("classes", query: ["date": date])
        return r.classes
    }

    public func history(date: String) async throws -> DayHistory {
        try await call("history", query: ["date": date])
    }

    public func queue() async throws -> QueueState {
        try await call("queue")
    }

    public func queue(_ action: QueueAction) async throws -> QueueState {
        try await call("queue/\(action.path)", method: "POST", body: action.body)
    }

    /// 後台還沒有折價券的 API（舊版的後台：路徑不存在的 404 沒有 `not_found`）
    public static let couponsUnsupported = "後台還不支援門市折價券，請更新後台"

    /// GET /coupons/:code?subtotal=&memberId=。`404 not_found`＝沒有這張券（nil）；其他的 404（舊版後台沒有這個路徑）丟出來
    public func coupon(code: String, subtotal: Money, memberId: String?) async throws -> CouponLookup? {
        var query = ["subtotal": String(subtotal.cents)]
        if let memberId, !memberId.isEmpty { query["memberId"] = memberId }
        do {
            let r: CouponLookup = try await call("coupons/\(code)", query: query)
            return r
        } catch APIError.http(404, let errorCode, let message) {
            if errorCode == "not_found" { return nil }
            throw APIError.http(status: 404, code: errorCode, message: message ?? Self.couponsUnsupported)
        }
    }

    /// 後台還沒有 verify-pin（舊版的後台：路徑不存在）
    public static let verifyPinUnsupported = "後台還不支援主管授權，請更新後台"

    /// POST /staff/verify-pin。401 wrong_pin、429 rate_limited 的訊息沒給時補上協定的那一句；舊版後台（沒有這個路徑）說請更新後台
    public func verifyPin(staffId: String?, pin: String, purpose: String) async throws -> VerifiedStaff {
        let body = VerifyPinRequest(staffId: staffId?.isEmpty == false ? staffId : nil, pin: pin, purpose: purpose)
        do {
            let r: VerifyPinResponse = try await call("staff/verify-pin", method: "POST", body: body)
            return r.staff
        } catch APIError.http(401, let code, let message) where code == APIError.wrongPinCode {
            throw APIError.http(status: 401, code: code, message: message ?? APIError.wrongPinMessage)
        } catch APIError.http(429, let code, let message) {
            throw APIError.http(status: 429, code: code, message: message ?? APIError.pinRateLimitedMessage)
        } catch APIError.http(404, let code, _) {
            throw APIError.http(status: 404, code: code, message: Self.verifyPinUnsupported)
        }
    }

    // MARK: 傳輸

    struct Empty: Encodable {}

    func call<T: Decodable>(_ path: String, method: String = "GET", query: [String: String] = [:], headers: [String: String] = [:]) async throws -> T {
        try await call(path, method: method, query: query, headers: headers, body: Optional<Empty>.none)
    }

    func call<T: Decodable, B: Encodable>(_ path: String, method: String = "GET", query: [String: String] = [:], headers: [String: String] = [:], body: B?) async throws -> T {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = c.url ?? url
        }
        return try await Self.send(session: session, url: url, method: method, token: token, body: body, headers: headers)
    }

    static func send<T: Decodable, B: Encodable>(session: URLSession, url: URL, method: String, token: String?, body: B?, headers: [String: String] = [:]) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try EventCoding.encoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 304 { throw APIError.notModified }
        guard (200..<300).contains(status) else {
            let err = try? EventCoding.decoder().decode(APIErrorBody.self, from: data)
            switch (status, err?.error) {
            case (401, "revoked"): throw APIError.revoked
            case (401, "staff_inactive"): throw APIError.staffInactive
            // 主管授權的 PIN 不對：不是這台的登入失效（不能回登入畫面）
            case (401, APIError.wrongPinCode): throw APIError.http(status: 401, code: APIError.wrongPinCode, message: err?.message ?? APIError.wrongPinMessage)
            case (401, _): throw APIError.unauthorized
            case (403, "service_off"): throw APIError.serviceOff
            default: throw APIError.http(status: status, code: err?.error ?? "http_\(status)", message: err?.message)
            }
        }
        do {
            return try EventCoding.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
