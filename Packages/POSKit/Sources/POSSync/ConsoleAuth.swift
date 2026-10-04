import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import POSCore

// 用 StudioX 帳號登入（docs/API.md「用 StudioX 帳號登入」）：
//
//   1. OAuth 2.1＋PKCE 登入 console（和 StudioX App 同一個帳號；client_id=studiox-pos、scope=pos:staff）
//   2. GET  {console}/api/pos/sites          這個人是成員、而且開通了門市 POS 的店
//   3. POST {console}/api/pos/personal-pair  console 代轉到那家店的 POST /pair/personal，回應和 POST /pair 一樣（多了店的網址、是不是個人的、綁的人）
//
// console 的 token 只拿來配對、換店，不拿來同步：之後和用配對碼配對的裝置一樣，用網站發的裝置 token。
// token 存在哪裡由 App 決定（Keychain）；這裡只管格式、換 token、帶 token 呼叫。

// MARK: - console 的網站

/// GET {console}/api/pos/sites 的一家店
public struct ConsoleSite: Codable, Sendable, Hashable, Identifiable {
    /// console 的網站 id（personal-pair 帶的 siteId）
    public var id: String
    public var name: String
    /// 網站的圖示（console 自動抓的；沒有就顯示店名的第一個字）
    public var icon: ConsoleSiteIcon?
    /// 這個人在這家店的職能（console 的 level：owner｜manager｜fulfillment｜staff）
    public var level: String?
    public var cmsUrl: String

    public init(id: String, name: String, icon: ConsoleSiteIcon? = nil, level: String? = nil, cmsUrl: String) {
        self.id = id; self.name = name; self.icon = icon; self.level = level; self.cmsUrl = cmsUrl
    }

    /// 負責人、管理者才能新增店裡共用的裝置（和在後台產生配對碼的權限一樣）；其他人 403 forbidden
    public var canAddSharedDevices: Bool {
        switch level {
        case "owner", "manager", "負責人", "管理者": true
        default: false
        }
    }
}

/// 網站的圖示：`{ "src": "data:image/png;base64,…" | "https://…", "fill": true }`，或直接一個網址字串（兩種都收）
public struct ConsoleSiteIcon: Codable, Sendable, Hashable {
    public var src: String
    /// 圖示本身是滿版的方塊（不用留白邊）
    public var fill: Bool

    public init(src: String, fill: Bool = false) {
        self.src = src
        self.fill = fill
    }

    private enum CodingKeys: String, CodingKey { case src, fill }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.init(src: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(src: try c.decode(String.self, forKey: .src), fill: try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(src, forKey: .src)
        try c.encode(fill, forKey: .fill)
    }

    /// data:image/png;base64,… 的內容（SVG 畫不出來：回 nil，改顯示店名的第一個字）
    public var imageData: Data? {
        guard src.hasPrefix("data:image/"), !src.hasPrefix("data:image/svg"), let comma = src.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(src[src.index(after: comma)...]))
    }

    /// 一般的圖片網址（https）
    public var url: URL? {
        guard src.hasPrefix("https://") else { return nil }
        return URL(string: src)
    }
}

public struct ConsoleSiteList: Codable, Sendable, Hashable {
    public var sites: [ConsoleSite]
    public init(sites: [ConsoleSite]) { self.sites = sites }
}

// MARK: - 用帳號配對

/// 這台是誰的：個人的（綁著登入的人，不用 PIN）或店裡共用的（和配對碼配對的一樣，大家用 PIN 登入）
public enum DevicePairMode: String, Codable, Sendable, Hashable, CaseIterable {
    case personal
    case shared
}

/// POST {console}/api/pos/personal-pair
public struct PersonalPairRequest: Codable, Sendable, Hashable {
    public var siteId: String
    public var device: DeviceInfo
    /// 沒給＝personal
    public var mode: DevicePairMode?
    /// 店裡共用的：崗位、名稱（「櫃台 iPad」）
    public var role: DeviceRole?
    public var name: String?

    public init(siteId: String, device: DeviceInfo, mode: DevicePairMode? = nil, role: DeviceRole? = nil, name: String? = nil) {
        self.siteId = siteId; self.device = device; self.mode = mode; self.role = role; self.name = name
    }

    /// 我自己的（個人手機、個人 iPad）：只帶 siteId 與 device
    public static func personal(siteId: String, device: DeviceInfo) -> PersonalPairRequest {
        PersonalPairRequest(siteId: siteId, device: device)
    }

    /// 店裡共用的：崗位與名稱（只有負責人、管理者可以）
    public static func shared(siteId: String, device: DeviceInfo, role: DeviceRole, name: String) -> PersonalPairRequest {
        PersonalPairRequest(siteId: siteId, device: device, mode: .shared, role: role, name: name)
    }
}

/// 綁著這台的門市人員（個人的才有）
public struct PersonalStaff: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// 網站的門市人員職能（cashier｜supervisor｜manager｜owner）；用字串收：不認得的值也不會讓整個回應讀不進來
    public var role: String

    public init(id: String, name: String, role: String) {
        self.id = id; self.name = name; self.role = role
    }
}

/// POST {console}/api/pos/personal-pair 的回應：和 POST /pair（PairResponse）一樣，另外多了店的網址、店名、是不是個人的、綁的人
public struct PersonalPairResponse: Codable, Sendable, Hashable {
    public var deviceId: String
    /// 之後每個請求的 Authorization: Bearer <token>（只會給這一次，存在 Keychain）
    public var token: String
    public var deviceCode: String
    public var role: DeviceRole
    public var storeName: String
    /// 那家店的後台（之後同步都到這裡）
    public var cmsUrl: String
    public var siteName: String
    /// true＝綁著 staff 那個人（不用 PIN）；false＝店裡共用的（大家用 PIN 登入）
    public var personal: Bool
    public var staff: PersonalStaff?

    public init(deviceId: String, token: String, deviceCode: String, role: DeviceRole, storeName: String, cmsUrl: String, siteName: String,
                personal: Bool, staff: PersonalStaff?) {
        self.deviceId = deviceId; self.token = token; self.deviceCode = deviceCode; self.role = role; self.storeName = storeName
        self.cmsUrl = cmsUrl; self.siteName = siteName; self.personal = personal; self.staff = staff
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, token, deviceCode, role, storeName, cmsUrl, siteName, personal, staff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        token = try c.decode(String.self, forKey: .token)
        deviceCode = try c.decode(String.self, forKey: .deviceCode)
        role = try c.decode(DeviceRole.self, forKey: .role)
        cmsUrl = try c.decode(String.self, forKey: .cmsUrl)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName) ?? ""
        storeName = try c.decodeIfPresent(String.self, forKey: .storeName) ?? siteName
        personal = try c.decodeIfPresent(Bool.self, forKey: .personal) ?? false
        staff = try c.decodeIfPresent(PersonalStaff.self, forKey: .staff)
    }

    /// 當成一般的配對回應（存起來的方式和配對碼一模一樣）
    public var pair: PairResponse {
        PairResponse(deviceId: deviceId, token: token, deviceCode: deviceCode, role: role, storeName: storeName)
    }

    /// 真的綁著一個人（個人的、而且有給是誰）
    public var boundStaff: PersonalStaff? { personal ? staff : nil }
}

extension DeviceProfile {
    /// 個人的裝置（GET /bootstrap 的 device.personal）：開 App 直接是 staffId 那位，鎖定用 Face ID
    public var isPersonal: Bool { personal == true }
}

// MARK: - console 的 token

/// console 的 access／refresh token（access 1 小時、refresh 30 天、每次換都輪替）
public struct ConsoleTokens: Codable, Sendable, Hashable {
    public var access: String
    public var refresh: String
    public var expiresAt: Date

    public init(access: String, refresh: String, expiresAt: Date) {
        self.access = access; self.refresh = refresh; self.expiresAt = expiresAt
    }

    /// 還有一分鐘以上才過期
    public func isFresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) > 60 }
}

/// 登入 console 的錯誤（給人看的一句話在 userMessage）
public enum ConsoleAuthError: Error, Equatable, Sendable {
    /// 自己關掉了登入視窗
    case cancelled
    /// console 拒絕了（沒有權限、沒有完成）
    case denied(String)
    /// refresh token 也失效了：要重新登入
    case expired
    case server(String)
    case offline(String)

    public var userMessage: String {
        switch self {
        case .cancelled: "登入取消了"
        case .denied(let why), .server(let why): why
        case .expired: "登入已經過期，請重新登入"
        case .offline: "連不上網路，請稍後再試"
        }
    }
}

/// console 的 OAuth（和 StudioX Console App 的 Auth.swift 同一套，client 換成門市 POS）
public enum ConsoleOAuth {
    public static let clientId = "studiox-pos"
    /// 登入視窗攔下來的網址（App 也用這個 scheme 收後台的配對 QR Code：studiox-pos://pair）
    public static let callbackScheme = "studiox-pos"
    public static let redirectURI = "studiox-pos://oauth"
    public static let scope = "pos:staff"

    /// 一次登入：PKCE 的 verifier（只留在這台）與防偽的 state
    public struct Request: Sendable, Hashable {
        public let verifier: String
        public let state: String

        public init(verifier: String = ConsoleOAuth.random(32), state: String = ConsoleOAuth.random(16)) {
            self.verifier = verifier
            self.state = state
        }

        /// S256：base64url(SHA-256(verifier))
        public var challenge: String { ConsoleOAuth.challenge(for: verifier) }

        /// {console}/api/oauth/authorize?…：在系統的登入視窗打開（和 Safari 共用登入狀態）
        public func authorizeURL(consoleURL: URL) -> URL {
            let base = consoleURL.appendingPathComponent("api/oauth/authorize")
            var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
            c?.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: ConsoleOAuth.clientId),
                URLQueryItem(name: "redirect_uri", value: ConsoleOAuth.redirectURI),
                URLQueryItem(name: "scope", value: ConsoleOAuth.scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            return c?.url ?? base
        }
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Crypto.SHA256.hash(verifier))
    }

    /// 隨機的 base64url 字串（SystemRandomNumberGenerator 在每個平台都是密碼學等級的亂數）
    public static func random(_ bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return base64URL((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    static func base64URL<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 登入視窗回來的 studiox-pos://oauth?code=…&state=… → 授權碼
    public static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if let why = value("error_description"), !why.isEmpty { throw ConsoleAuthError.denied(why) }
            throw ConsoleAuthError.denied(error == "access_denied" ? "這個帳號沒有授權門市 POS 登入" : "登入沒有完成，請再試一次")
        }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw ConsoleAuthError.denied("登入沒有完成，請再試一次")
        }
        return code
    }

    /// 授權碼 → token（POST {console}/api/oauth/token）
    public static func exchange(code: String, verifier: String, consoleURL: URL, session: URLSession = .shared) async throws -> ConsoleTokens {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ], consoleURL: consoleURL, session: session)
    }

    /// 用 refresh token 換新的一組（舊的 refresh token 同時作廢）
    public static func refresh(_ tokens: ConsoleTokens, consoleURL: URL, session: URLSession = .shared) async throws -> ConsoleTokens {
        try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": tokens.refresh,
        ], consoleURL: consoleURL, session: session)
    }

    /// 撤銷 token（登出這支手機）；網路不通也不管，本機照樣清掉
    public static func revoke(_ tokens: ConsoleTokens, consoleURL: URL, session: URLSession = .shared) async {
        for token in [tokens.refresh, tokens.access] {
            var req = URLRequest(url: consoleURL.appendingPathComponent("api/oauth/revoke"), timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(["token": token, "client_id": clientId])
            _ = try? await session.data(for: req)
        }
    }

    static func tokenRequest(_ form: [String: String], consoleURL: URL, session: URLSession) async throws -> ConsoleTokens {
        var req = URLRequest(url: consoleURL.appendingPathComponent("api/oauth/token"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formBody(form)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ConsoleAuthError.offline(error.localizedDescription)
        }
        return try tokens(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// token 端點的回應 → ConsoleTokens（invalid_grant＝要重新登入）
    public static func tokens(from data: Data, status: Int, now: Date = Date()) throws -> ConsoleTokens {
        struct Body: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var error: String?
            var error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        guard status == 200, let access = body?.access_token, let refresh = body?.refresh_token else {
            if body?.error == "invalid_grant" { throw ConsoleAuthError.expired }
            throw ConsoleAuthError.server(body?.error_description ?? "登入沒有完成（\(status)），請再試一次")
        }
        return ConsoleTokens(access: access, refresh: refresh, expiresAt: now.addingTimeInterval(body?.expires_in ?? 3600))
    }

    static func formBody(_ form: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents 不會編碼 +，token 裡可能有
        let encoded = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}

// MARK: - 帶 token 呼叫、過期就換

/// 登入 console 之後的狀態：快過期就先換一組（同時好幾個請求只換一次），401 就換一次再試；
/// refresh token 也失效（invalid_grant）＝登出（tokens 變 nil，persist(nil)）。token 不印、不記到任何 log
public actor ConsoleSession {
    public typealias Refresher = @Sendable (ConsoleTokens) async throws -> ConsoleTokens
    public typealias Persist = @Sendable (ConsoleTokens?) -> Void

    public private(set) var tokens: ConsoleTokens?
    private let refresher: Refresher
    private let persist: Persist
    private var refreshing: Task<ConsoleTokens, any Error>?

    /// refresher：換 token 的方式（測試用假的）；persist：換到新的、或登出時存起來（App 存 Keychain）
    public init(tokens: ConsoleTokens?, refresher: @escaping Refresher, persist: @escaping Persist) {
        self.tokens = tokens
        self.refresher = refresher
        self.persist = persist
    }

    public init(tokens: ConsoleTokens?, consoleURL: URL, session: URLSession = .shared, persist: @escaping Persist) {
        self.init(tokens: tokens, refresher: { try await ConsoleOAuth.refresh($0, consoleURL: consoleURL, session: session) }, persist: persist)
    }

    public var isSignedIn: Bool { tokens != nil }

    /// 剛登入拿到的（或換了帳號）
    public func replace(_ next: ConsoleTokens?) {
        refreshing?.cancel()
        refreshing = nil
        tokens = next
        persist(next)
    }

    /// 現在可以用的 access token（快過期就先換）
    public func accessToken(forceRefresh: Bool = false, now: Date = Date()) async throws -> String {
        guard let current = tokens else { throw ConsoleAuthError.expired }
        if current.isFresh(now: now) && !forceRefresh { return current.access }
        return try await refresh().access
    }

    /// 帶 token 呼叫；401 就換一次 token 再試（還是 401 就照樣丟出去）
    public func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        let token = try await accessToken()
        do {
            return try await call(token)
        } catch APIError.unauthorized {
            return try await call(try await accessToken(forceRefresh: true))
        }
    }

    /// 登出：清掉並回傳原本的（拿去撤銷）
    public func signOut() -> ConsoleTokens? {
        let old = tokens
        replace(nil)
        return old
    }

    private func refresh() async throws -> ConsoleTokens {
        if let refreshing { return try await refreshing.value }
        guard let current = tokens else { throw ConsoleAuthError.expired }
        let refresher = self.refresher
        let task = Task { try await refresher(current) }
        refreshing = task
        do {
            let next = try await task.value
            if refreshing == task { refreshing = nil }
            tokens = next
            persist(next)
            return next
        } catch ConsoleAuthError.expired {
            if refreshing == task { refreshing = nil }
            tokens = nil
            persist(nil)
            throw ConsoleAuthError.expired
        } catch {
            if refreshing == task { refreshing = nil }
            throw error
        }
    }
}

// MARK: - console 的門市 POS API

/// {console}/api/pos/*（帶 console 的 access token）
public struct ConsoleClient: Sendable {
    public let consoleURL: URL
    let session: URLSession

    public init(consoleURL: URL, session: URLSession = .shared) {
        self.consoleURL = consoleURL
        self.session = session
    }

    /// GET /api/pos/sites：這個人是成員、而且開通了門市 POS 的店
    public func sites(accessToken: String) async throws -> [ConsoleSite] {
        let r: ConsoleSiteList = try await POSClient.send(session: session, url: consoleURL.appendingPathComponent("api/pos/sites"), method: "GET",
                                                          token: accessToken, body: Optional<POSClient.Empty>.none)
        return r.sites
    }

    /// POST /api/pos/personal-pair：個人的（綁著登入的人）
    public func personalPair(siteId: String, device: DeviceInfo, accessToken: String) async throws -> PersonalPairResponse {
        try await personalPair(.personal(siteId: siteId, device: device), accessToken: accessToken)
    }

    /// POST /api/pos/personal-pair：個人的或店裡共用的（mode: shared 帶崗位、名稱）。
    /// 403 staff_inactive：這個人在那家店的門市人員被停用；403 forbidden：不是負責人、管理者，不能新增共用的裝置
    public func personalPair(_ request: PersonalPairRequest, accessToken: String) async throws -> PersonalPairResponse {
        try await POSClient.send(session: session, url: consoleURL.appendingPathComponent("api/pos/personal-pair"), method: "POST",
                                 token: accessToken, body: request)
    }
}

extension POSClient {
    /// 登出這支手機（個人的）：POST /devices/self/revoke（網站停用這台）。回應的內容不管（空的也算成功）
    public func revokeSelf() async throws {
        struct Done: Decodable {}
        do {
            let _: Done = try await call("devices/self/revoke", method: "POST", body: Empty())
        } catch APIError.decoding {
            // 204 或不是 JSON：網站已經停用了
        }
    }
}
