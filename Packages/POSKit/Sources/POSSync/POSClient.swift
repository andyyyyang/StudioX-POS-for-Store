import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import POSCore

/// 後台 API 的錯誤（App 依這個決定要重試、回配對畫面、還是提示）
public enum APIError: Error, Equatable, Sendable {
    /// 沒網路、逾時：等一下再試
    case offline(String)
    /// token 不對：回配對畫面
    case unauthorized
    /// 後台移除了這台：清資料、回配對畫面
    case revoked
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

    // MARK: 配對（還沒有 token）

    public static func resolve(code: String, consoleURL: URL, session: URLSession = .shared) async throws -> ResolveResponse {
        try await send(session: session, url: consoleURL.appendingPathComponent("api/pos/resolve"), method: "POST", token: nil, body: ResolveRequest(code: code))
    }

    public static func pair(cmsURL: URL, request: PairRequest, session: URLSession = .shared) async throws -> PairResponse {
        try await send(session: session, url: cmsURL.appendingPathComponent("api/pos/v1/pair"), method: "POST", token: nil, body: request)
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
