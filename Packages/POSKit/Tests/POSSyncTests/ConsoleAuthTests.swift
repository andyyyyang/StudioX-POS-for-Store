import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import POSCore
@testable import POSSync

/// 用 StudioX 帳號登入（docs/API.md「用 StudioX 帳號登入」）：PKCE、回呼、token、console 的回應格式、換 token。
/// 範例 JSON：POSKIT_WRITE_SAMPLES=1 swift test --filter ConsoleAuthTests 寫到 docs/samples/（console-sites.json、personal-pair-response.json）
struct ConsoleAuthTests {
    static let device = DeviceInfo(name: "王小美的 iPhone", model: "iPhone18,1", systemVersion: "26.1", appVersion: "1.0 (2610041200)")

    // MARK: OAuth

    /// RFC 7636 附錄 B 的範例
    @Test func pkceChallengeMatchesTheRFC() {
        #expect(ConsoleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomIsURLSafeAndLongEnough() {
        let a = ConsoleOAuth.random(32), b = ConsoleOAuth.random(32)
        #expect(a.count == 43)
        #expect(a != b)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func authorizeURLCarriesTheContract() throws {
        let req = ConsoleOAuth.Request(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s-123")
        let url = req.authorizeURL(consoleURL: URL(string: "https://console.studiox.tw")!)
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.host == "console.studiox.tw" && c.path == "/api/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["response_type"] == "code")
        #expect(q["client_id"] == "studiox-pos")
        #expect(q["redirect_uri"] == "studiox-pos://oauth")
        #expect(q["scope"] == "pos:staff")
        #expect(q["state"] == "s-123")
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["code_challenge_method"] == "S256")
    }

    @Test func callbackGivesTheCodeOnlyForOurState() throws {
        let ok = URL(string: "studiox-pos://oauth?code=abc&state=s-1")!
        #expect(try ConsoleOAuth.code(from: ok, state: "s-1") == "abc")
        #expect(throws: ConsoleAuthError.self) { try ConsoleOAuth.code(from: ok, state: "s-2") }
        let denied = URL(string: "studiox-pos://oauth?error=access_denied&state=s-1")!
        #expect(throws: ConsoleAuthError.denied("這個帳號沒有授權門市 POS 登入")) { try ConsoleOAuth.code(from: denied, state: "s-1") }
        let described = URL(string: "studiox-pos://oauth?error=access_denied&error_description=%E6%B2%92%E6%9C%89%E6%AC%8A%E9%99%90&state=s-1")!
        #expect(throws: ConsoleAuthError.denied("沒有權限")) { try ConsoleOAuth.code(from: described, state: "s-1") }
    }

    @Test func tokenEndpointResponses() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ok = Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        let t = try ConsoleOAuth.tokens(from: ok, status: 200, now: now)
        #expect(t.access == "a1" && t.refresh == "r1" && t.expiresAt == now.addingTimeInterval(3600))
        #expect(t.isFresh(now: now) && !t.isFresh(now: now.addingTimeInterval(3550)))
        let expired = Data(#"{"error":"invalid_grant","error_description":"refresh token 已失效"}"#.utf8)
        #expect(throws: ConsoleAuthError.expired) { try ConsoleOAuth.tokens(from: expired, status: 400) }
        let other = Data(#"{"error":"invalid_client","error_description":"不認識的 client"}"#.utf8)
        #expect(throws: ConsoleAuthError.server("不認識的 client")) { try ConsoleOAuth.tokens(from: other, status: 401) }
        #expect(throws: ConsoleAuthError.self) { try ConsoleOAuth.tokens(from: Data("<html>".utf8), status: 502) }
    }

    @Test func formBodyEncodesPlus() {
        let body = String(decoding: ConsoleOAuth.formBody(["token": "a+b/c=", "client_id": "studiox-pos"]), as: UTF8.self)
        #expect(body == "client_id=studiox-pos&token=a%2Bb/c%3D" || body == "client_id=studiox-pos&token=a%2Bb/c=")
    }

    // MARK: console 的回應

    @Test func sitesDecodeEitherIconShape() throws {
        let json = """
        { "sites": [
          { "id": "site-1", "name": "晨麥手作", "level": "owner", "cmsUrl": "https://cms.example.tw",
            "icon": { "src": "data:image/png;base64,iVBORw0KGgo=", "fill": true } },
          { "id": "site-2", "name": "黃毛丫頭", "level": "staff", "cmsUrl": "https://yellowgirl.tw", "icon": "https://yellowgirl.tw/icon.png" },
          { "id": "site-3", "name": "Mori Hair", "level": "manager", "cmsUrl": "https://mori.example.tw", "icon": null },
          { "id": "site-4", "name": "沒有圖示", "cmsUrl": "https://x.example.tw" }
        ] }
        """
        let list = try EventCoding.decoder().decode(ConsoleSiteList.self, from: Data(json.utf8))
        #expect(list.sites.count == 4)
        #expect(list.sites[0].icon?.fill == true && list.sites[0].icon?.imageData != nil)
        #expect(list.sites[1].icon?.url?.host == "yellowgirl.tw" && list.sites[1].icon?.imageData == nil)
        #expect(list.sites[2].icon == nil)
        #expect(list.sites[3].icon == nil && list.sites[3].level == nil)
        // SVG 畫不出來：當作沒有圖
        #expect(ConsoleSiteIcon(src: "data:image/svg+xml;base64,PHN2Zz4=").imageData == nil)
    }

    @Test func personalPairResponseIsAPairResponse() throws {
        let personal = """
        { "deviceId": "dev-p", "token": "sxpos_dev-p.x", "deviceCode": "C", "role": "handheld", "storeName": "晨麥手作",
          "cmsUrl": "https://cms.example.tw", "siteName": "晨麥手作", "personal": true,
          "staff": { "id": "staff-may", "name": "王小美", "role": "cashier" } }
        """
        let r = try EventCoding.decoder().decode(PersonalPairResponse.self, from: Data(personal.utf8))
        #expect(r.personal && r.boundStaff?.id == "staff-may" && r.boundStaff?.name == "王小美")
        #expect(r.pair == PairResponse(deviceId: "dev-p", token: "sxpos_dev-p.x", deviceCode: "C", role: .handheld, storeName: "晨麥手作"))

        // 店裡共用的：沒有 staff、personal: false（沒給也當 false）
        let shared = """
        { "deviceId": "dev-s", "token": "sxpos_dev-s.y", "deviceCode": "D", "role": "kitchen", "storeName": "晨麥手作",
          "cmsUrl": "https://cms.example.tw", "siteName": "晨麥手作" }
        """
        let s = try EventCoding.decoder().decode(PersonalPairResponse.self, from: Data(shared.utf8))
        #expect(!s.personal && s.boundStaff == nil && s.role == .kitchen)

        // 新的人是 cashier（契約）；將來多了這版不認得的職能也讀得進來
        let odd = personal.replacingOccurrences(of: "\"cashier\"", with: "\"trainee\"")
        #expect(try EventCoding.decoder().decode(PersonalPairResponse.self, from: Data(odd.utf8)).staff?.role == "trainee")
    }

    @Test func pairRequestCarriesTheRole() throws {
        let enc = EventCoding.encoder()
        let p = try JSONSerialization.jsonObject(with: enc.encode(PersonalPairRequest(siteId: "site-1", device: Self.device))) as? [String: Any]
        #expect(p?["siteId"] as? String == "site-1")
        #expect(p?["role"] == nil && p?["mode"] == nil)
        #expect((p?["device"] as? [String: Any])?["model"] as? String == "iPhone18,1")

        let r = try JSONSerialization.jsonObject(with: enc.encode(PersonalPairRequest(siteId: "site-1", device: Self.device, role: .register))) as? [String: Any]
        #expect(r?["role"] as? String == "register" && r?["mode"] == nil)
    }

    @Test func bootstrapDeviceCarriesPersonal() throws {
        let dec = EventCoding.decoder()
        let personal = try dec.decode(DeviceProfile.self, from: Data(#"{"id":"dev-p","name":"王小美的手機","code":"C","role":"handheld","stations":[],"personal":true,"staffId":"staff-may"}"#.utf8))
        #expect(personal.isPersonal && personal.staffId == "staff-may")
        let shared = try dec.decode(DeviceProfile.self, from: Data(#"{"id":"dev-a","name":"櫃台 1","code":"A","role":"register","stations":[]}"#.utf8))
        #expect(!shared.isPersonal && shared.staffId == nil)
        // 沒有的欄位不寫出去（舊的範例、舊版後台不受影響）
        let out = String(decoding: try EventCoding.encoder().encode(shared), as: UTF8.self)
        #expect(!out.contains("personal") && !out.contains("staffId"))
    }

    // MARK: 換 token

    actor Counter {
        var count = 0
        var saved: [ConsoleTokens?] = []
        func bump() -> Int { count += 1; return count }
        func save(_ t: ConsoleTokens?) { saved.append(t) }
    }

    @Test func freshTokensAreUsedAsIs() async throws {
        let counter = Counter()
        let s = ConsoleSession(tokens: ConsoleTokens(access: "a0", refresh: "r0", expiresAt: Date().addingTimeInterval(3600)),
                               refresher: { _ in _ = await counter.bump(); return ConsoleTokens(access: "x", refresh: "x", expiresAt: .distantFuture) },
                               persist: { _ in })
        #expect(try await s.accessToken() == "a0")
        #expect(await counter.count == 0)
    }

    @Test func expiredTokensRefreshOnceForManyCallers() async throws {
        let counter = Counter()
        let s = ConsoleSession(tokens: ConsoleTokens(access: "a0", refresh: "r0", expiresAt: Date().addingTimeInterval(-10)),
                               refresher: { old in
                                   let n = await counter.bump()
                                   try await Task.sleep(for: .milliseconds(50))
                                   return ConsoleTokens(access: "a\(n)", refresh: "r\(n)", expiresAt: Date().addingTimeInterval(3600))
                               },
                               persist: { t in Task { await counter.save(t) } })
        async let one = s.accessToken()
        async let two = s.accessToken()
        async let three = s.accessToken()
        let all = try await [one, two, three]
        #expect(all == ["a1", "a1", "a1"])
        #expect(await counter.count == 1)
        #expect(await s.tokens?.refresh == "r1")
    }

    @Test func revokedRefreshSignsOut() async {
        let counter = Counter()
        let s = ConsoleSession(tokens: ConsoleTokens(access: "a0", refresh: "r0", expiresAt: Date().addingTimeInterval(-10)),
                               refresher: { _ in throw ConsoleAuthError.expired },
                               persist: { t in Task { await counter.save(t) } })
        await #expect(throws: ConsoleAuthError.expired) { try await s.accessToken() }
        #expect(await s.isSignedIn == false)
        await #expect(throws: ConsoleAuthError.expired) { try await s.accessToken() }
    }

    @Test func unauthorizedRetriesOnceWithAFreshToken() async throws {
        let counter = Counter()
        let s = ConsoleSession(tokens: ConsoleTokens(access: "stale", refresh: "r0", expiresAt: Date().addingTimeInterval(3600)),
                               refresher: { _ in ConsoleTokens(access: "new", refresh: "r1", expiresAt: Date().addingTimeInterval(3600)) },
                               persist: { _ in })
        let got = try await s.authorized { token -> String in
            _ = await counter.bump()
            if token == "stale" { throw APIError.unauthorized }
            return "ok:\(token)"
        }
        #expect(got == "ok:new")
        #expect(await counter.count == 2)
    }

    // MARK: 傳輸（假的 console 與網站）

    static func stubbed() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConsoleStub.self]
        return URLSession(configuration: config)
    }

    @Test func consoleClientTalksTheContract() async throws {
        let client = ConsoleClient(consoleURL: URL(string: "https://console.example.tw")!, session: Self.stubbed())
        let sites = try await client.sites(accessToken: "ok")
        #expect(sites.map(\.id) == ["site-1"] && sites[0].icon?.fill == true)
        let paired = try await client.personalPair(siteId: "site-1", device: Self.device, accessToken: "ok")
        #expect(paired.personal && paired.boundStaff?.id == "staff-may" && paired.cmsUrl == "https://cms.example.tw")
    }

    /// console 轉回來的錯誤：403／429 帶網站的那一句；網站連不上是 502 upstream
    @Test func personalPairErrorsKeepTheirCodeAndMessage() async {
        let client = ConsoleClient(consoleURL: URL(string: "https://console.example.tw")!, session: Self.stubbed())
        let cases: [(String, APIError)] = [
            ("inactive", .http(status: 403, code: "staff_inactive", message: "你的門市人員已經停用")),
            ("member", .http(status: 403, code: "forbidden", message: "要店長才能新增店裡的裝置")),
            ("busy", .http(status: 429, code: "rate_limited", message: "登入太多次了，請稍後再試")),
            ("down", .http(status: 502, code: "upstream", message: "「晨麥手作」的後台暫時連不上，請稍後再試")),
        ]
        for (token, expected) in cases {
            await #expect(throws: expected) { _ = try await client.personalPair(siteId: "site-1", device: Self.device, accessToken: token) }
        }
    }

    /// 網站的兩種 401：裝置被停用（清掉這台）和綁的人被停用（資料要留著）是不同的錯
    @Test func siteDistinguishesRevokedFromStaffInactive() async throws {
        let cms = URL(string: "https://cms.example.tw")!
        let inactive = POSClient(cmsURL: cms, token: "sxpos_inactive", session: Self.stubbed())
        await #expect(throws: APIError.staffInactive) { _ = try await inactive.bootstrap(ifNoneMatch: nil) }
        let revoked = POSClient(cmsURL: cms, token: "sxpos_revoked", session: Self.stubbed())
        await #expect(throws: APIError.revoked) { _ = try await revoked.bootstrap(ifNoneMatch: nil) }
        // 綁的人被停用了也能登出這支手機
        try await inactive.revokeSelf()
    }

    // MARK: 範例

    @Test func samples() throws {
        let enc = EventCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let sites = ConsoleSiteList(sites: [
            ConsoleSite(id: "site-1", name: "晨麥手作", icon: ConsoleSiteIcon(src: "data:image/png;base64,iVBORw0KGgo…", fill: true), level: "owner", cmsUrl: "https://cms.example.tw"),
            ConsoleSite(id: "site-2", name: "黃毛丫頭", level: "staff", cmsUrl: "https://yellowgirl.tw"),
        ])
        let pair = PersonalPairResponse(deviceId: "dev-p", token: "sxpos_dev-p.Qm…", deviceCode: "C", role: .handheld, storeName: "晨麥手作",
                                        cmsUrl: "https://cms.example.tw", siteName: "晨麥手作", personal: true,
                                        staff: PersonalStaff(id: "staff-may", name: "王小美", role: "cashier"))
        let out = [
            "console-sites.json": String(decoding: try enc.encode(sites), as: UTF8.self),
            "personal-pair-response.json": String(decoding: try enc.encode(pair), as: UTF8.self),
        ]
        let dec = EventCoding.decoder()
        #expect(try dec.decode(ConsoleSiteList.self, from: Data(out["console-sites.json"]!.utf8)) == sites)
        #expect(try dec.decode(PersonalPairResponse.self, from: Data(out["personal-pair-response.json"]!.utf8)) == pair)
        if ProcessInfo.processInfo.environment["POSKIT_WRITE_SAMPLES"] == "1" {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/samples").standardized
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in out { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
    }
}

/// 假的 console 與網站：照路徑與 Bearer 決定回什麼（沒有共用的狀態，測試平行跑也不會互相影響）
final class ConsoleStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.respond(to: request)
        let url = request.url ?? URL(string: "https://console.example.tw")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func respond(to r: URLRequest) -> (Int, String) {
        let token = r.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        switch (r.httpMethod ?? "GET", r.url?.path ?? "") {
        case ("GET", "/api/pos/sites"):
            return (200, #"{"sites":[{"id":"site-1","name":"晨麥手作","level":"owner","cmsUrl":"https://cms.example.tw","icon":{"src":"data:image/png;base64,iVBORw0KGgo=","fill":true}}]}"#)
        case ("POST", "/api/pos/personal-pair"):
            switch token {
            case "ok":
                return (200, #"{"deviceId":"dev-p","token":"sxpos_dev-p.x","deviceCode":"C","role":"handheld","storeName":"晨麥手作","cmsUrl":"https://cms.example.tw","siteName":"晨麥手作","personal":true,"staff":{"id":"staff-may","name":"王小美","role":"cashier"}}"#)
            case "inactive": return (403, #"{"error":"staff_inactive","message":"你的門市人員已經停用"}"#)
            case "member": return (403, #"{"error":"forbidden","message":"要店長才能新增店裡的裝置"}"#)
            case "busy": return (429, #"{"error":"rate_limited","message":"登入太多次了，請稍後再試"}"#)
            default: return (502, #"{"error":"upstream","message":"「晨麥手作」的後台暫時連不上，請稍後再試"}"#)
            }
        case ("GET", "/api/pos/v1/bootstrap"):
            if token == "sxpos_inactive" { return (401, #"{"error":"staff_inactive","message":"這支手機的門市人員已經停用，請找店長"}"#) }
            return (401, #"{"error":"revoked","message":"這台裝置已經從後台移除"}"#)
        case ("POST", "/api/pos/v1/devices/self/revoke"):
            return (200, #"{"ok":true}"#)
        default:
            return (404, #"{"error":"not_found"}"#)
        }
    }
}
