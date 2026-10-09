import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import POSCore
@testable import POSSync

/// 門市掃碼付（docs/API.md「掃碼付」）：開機資料（舊版後台沒有也讀得進來）、請求與回應的格式、付款上的 intentId、路徑。
struct WalletPayTests {
    let enc: JSONEncoder = {
        let e = EventCoding.encoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    let dec = EventCoding.decoder()

    func json<T: Encodable>(_ v: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try enc.encode(v)) as! [String: Any]
    }

    func decode<T: Decodable>(_ type: T.Type, _ s: String) throws -> T {
        try dec.decode(type, from: Data(s.utf8))
    }

    // MARK: 開機資料

    /// 舊版後台（沒有 features.walletScan、沒有 walletScan）：照舊手動記電子支付
    @Test func oldBootstrapStillDecodes() throws {
        let s = try ContractSamples.samples()
        var root = try JSONSerialization.jsonObject(with: Data(s["bootstrap.json"]!.utf8)) as! [String: Any]
        var features = root["features"] as! [String: Any]
        features["walletScan"] = nil
        root["features"] = features
        root["walletScan"] = nil
        let b = try dec.decode(Bootstrap.self, from: try JSONSerialization.data(withJSONObject: root))
        #expect(b.features.walletScan == false)
        #expect(b.walletScan == nil)
    }

    @Test func bootstrapCarriesWalletScan() throws {
        let s = try ContractSamples.samples()
        var root = try JSONSerialization.jsonObject(with: Data(s["bootstrap.json"]!.utf8)) as! [String: Any]
        var features = root["features"] as! [String: Any]
        features["walletScan"] = true
        root["features"] = features
        root["walletScan"] = ["methods": ["jko_pay", "twqr", "line_pay", "plus_pay", "line_pay"], "pollMs": 3000, "windowMinutes": 20] as [String: Any]
        let b = try dec.decode(Bootstrap.self, from: try JSONSerialization.data(withJSONObject: root))
        #expect(b.features.walletScan)
        // 照後台的順序；台灣Pay、這版不認得的不列；重複的只列一次
        #expect(b.walletScan?.tenders == [.jkoPay, .linePay])
        #expect(b.walletScan?.pollMs == 3000 && b.walletScan?.windowMinutes == 20)
        // 寫回去再讀一次一樣（App 把開機資料存在這台）
        let again = try dec.decode(Bootstrap.self, from: try enc.encode(b))
        #expect(again.walletScan == b.walletScan && again.features == b.features)
    }

    /// 少了欄位、值不對：用預設，不讓整份開機資料讀不進來
    @Test func walletScanConfigIsLenient() throws {
        let empty = try decode(WalletScanConfig.self, "{}")
        #expect(empty.methods.isEmpty && empty.pollMs == 3000 && empty.windowMinutes == 20)
        let odd = try decode(WalletScanConfig.self, #"{ "methods": "line_pay", "pollMs": 10, "windowMinutes": 999 }"#)
        #expect(odd.methods.isEmpty && odd.pollMs == 1000 && odd.windowMinutes == 60)
        #expect(FeatureFlags().walletScan == false, "要後台開通：預設關")
        let flags = try json(FeatureFlags(walletScan: true))
        #expect(flags["walletScan"] as? Bool == true)
    }

    @Test func methodCodesMatchTheBackend() {
        for t in [Tender.linePay, .jkoPay, .pxPay, .easyWallet] {
            let code = WalletMethod.code(for: t)
            #expect(code != nil && WalletMethod.tender(for: code!) == t)
        }
        #expect(WalletMethod.code(for: .linePay) == "line_pay" && WalletMethod.code(for: .easyWallet) == "easy_wallet")
        #expect(WalletMethod.code(for: .card) == nil && WalletMethod.tender(for: "twqr") == nil)
        // 條碼機多打的空白、換行去掉；只能是 6–64 個英數字
        #expect(WalletMethod.normalize(" 1234 5678 9012 3456\n") == "1234567890123456")
        #expect(WalletMethod.normalize("12345") == nil)
        #expect(WalletMethod.normalize("ABC-123456") == nil)
        #expect(WalletMethod.normalize("１２３４５６７") == nil, "全形數字不是付款碼")
        #expect(WalletMethod.normalize(String(repeating: "9", count: 65)) == nil)
    }

    // MARK: 請求、回應

    @Test func scanRequestShape() throws {
        let r = WalletScanRequest(paymentId: "pay-1", ticketId: "tkt-1", amount: Money(dollars: 1_280), method: "line_pay", code: "123456789012345678", staffId: "staff-1")
        let o = try json(r)
        #expect(o["amount"] as? Int == 128_000, "金額是分")
        #expect(o["paymentId"] as? String == "pay-1" && o["ticketId"] as? String == "tkt-1" && o["method"] as? String == "line_pay")
        #expect(o["code"] as? String == "123456789012345678" && o["staffId"] as? String == "staff-1")
        // 只查：同一筆、不帶付款碼（不會扣款）
        let lookup = try json(r.lookup)
        #expect(lookup["code"] == nil && lookup["paymentId"] as? String == "pay-1" && lookup["amount"] as? Int == 128_000)
        let refund = try json(WalletRefundRequest(intentId: "pi_1", amount: nil, refundId: "ref-1", reason: "客人不要了"))
        #expect(refund["amount"] == nil && refund["managerPin"] == nil && refund["refundId"] as? String == "ref-1")
    }

    @Test func resultsDecode() throws {
        let ok = try decode(WalletPayResult.self, #"{"status":"succeeded","intentId":"pi_abc","amount":128000,"method":"line_pay","pspTransactionId":"2026100912345678","wallet":"line_pay","paidAt":"2026-10-09T14:00:03+08:00"}"#)
        #expect(ok.status == .succeeded && ok.amount == Money(dollars: 1_280) && ok.pspTransactionId == "2026100912345678")
        #expect(ok.paidAt == "2026-10-09T14:00:03+08:00", "錢包的時間格式不一樣也照收")
        let wait = try decode(WalletPayResult.self, #"{"status":"processing","intentId":"pi_abc","amount":128000,"message":"等客人在手機上確認","pollAfterMs":3000,"pollUntil":"2026-10-09T06:21:00.000Z"}"#)
        #expect(wait.status == .processing && wait.pollAfterMs == 3000)
        #expect(wait.pollUntil == EventCoding.parseTimestamp("2026-10-09T06:21:00.000Z"))
        let bad = try decode(WalletPayResult.self, #"{"status":"failed","intentId":"pi_abc","amount":128000,"code":"wallet_code_expired","message":"付款碼過期了"}"#)
        #expect(bad.status == .failed && bad.code == "wallet_code_expired" && !bad.isConflicted)
        #expect(try decode(WalletPayResult.self, #"{"status":"failed","amount":100,"code":"conflicted"}"#).isConflicted)
        // 看不懂的時間不能讓結果讀不進來；新版後台多了不認得的狀態：當作處理中（繼續查，不能當失敗）
        let odd = try decode(WalletPayResult.self, #"{"status":"settling","intentId":"pi_abc","amount":100,"pollUntil":"later","cancelable":false}"#)
        #expect(odd.status == .processing && odd.pollUntil == nil && odd.cancelable == false)
        let refund = try decode(WalletRefundResult.self, #"{"refundId":"re_1","status":"requires_manual_action","amount":50000,"message":"這個錢包要到錢包業者的後台退款"}"#)
        #expect(refund.status == .requiresManualAction && refund.amount == Money(dollars: 500))
        #expect(try decode(WalletRefundResult.self, #"{"refundId":"re_1","status":"queued","amount":1}"#).status == .pending)
    }

    @Test func uncertainErrors() {
        #expect(APIError.offline("逾時").isUncertain)
        #expect(APIError.decoding("x").isUncertain)
        #expect(APIError.http(status: 502, code: "pay_unreachable", message: nil).isUncertain)
        #expect(!APIError.http(status: 409, code: "wallet_not_enabled", message: nil).isUncertain)
        #expect(!APIError.serviceOff.isUncertain)
        #expect(APIError.http(status: 403, code: "manager_approval_required", message: "要店長核准").needsManagerApproval)
        #expect(!APIError.http(status: 403, code: "forbidden", message: nil).needsManagerApproval)
    }

    // MARK: 付款上的 intentId

    /// 掃碼付收的帶 intentId（退款照它退）；其他付款不帶：JSON 裡不出現，以前的事件雜湊不變
    @Test func paymentCarriesIntentId() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let plain = Payment(id: "pay-1", tender: .linePay, amount: Money(dollars: 120), reference: "1234", at: at, by: "s1")
        #expect(try json(plain)["intentId"] == nil)
        let scanned = Payment(id: "pay-2", tender: .linePay, amount: Money(dollars: 120), reference: "2026100912345678", at: at, by: "s1", intentId: "pi_abc")
        #expect(try json(scanned)["intentId"] as? String == "pi_abc")
        #expect(try dec.decode(Payment.self, from: try enc.encode(scanned)) == scanned)
        // 舊版 App 記的付款（沒有這個欄位）照樣讀得進來
        let old = try decode(Payment.self, #"{"id":"p","tender":"jkoPay","amount":100,"change":0,"status":"approved","at":"2026-09-21T14:13:20.000Z","by":"s"}"#)
        #expect(old.intentId == nil)
    }

    // MARK: 路徑

    static func stubbed() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WalletStub.self]
        return URLSession(configuration: config)
    }

    @Test func clientTalksTheContract() async throws {
        let client = POSClient(cmsURL: URL(string: "https://cms.example.tw")!, token: "sxpos_dev.x", session: Self.stubbed())
        let r = try await client.walletScan(WalletScanRequest(paymentId: "pay-1", ticketId: "tkt-1", amount: Money(dollars: 120), method: "line_pay", code: "123456789012"))
        #expect(r.status == .processing && r.intentId == "pi_abc")
        let now = try await client.walletIntent(id: "pi_abc")
        #expect(now.status == .succeeded)
        let c = try await client.cancelWalletIntent(id: "pi_abc")
        #expect(c.cancelable == false)
        await #expect(throws: APIError.http(status: 403, code: "manager_approval_required", message: "POS 退款超過 NT$1,000 要店長核准")) {
            _ = try await client.walletRefund(WalletRefundRequest(intentId: "pi_abc", amount: nil, refundId: "ref-1", reason: nil))
        }
        // 假的網站照 token 分（不靠讀本文）：店長核准過的、PIN 不對的
        let manager = POSClient(cmsURL: URL(string: "https://cms.example.tw")!, token: "sxpos_dev.manager", session: Self.stubbed())
        let approved = try await manager.walletRefund(WalletRefundRequest(intentId: "pi_abc", amount: nil, refundId: "ref-1", reason: nil, managerPin: "9999"))
        #expect(approved.status == .succeeded && approved.refundId == "re_1")
        // 店長 PIN 不對：不是這台的登入失效
        let wrong = POSClient(cmsURL: URL(string: "https://cms.example.tw")!, token: "sxpos_dev.wrong", session: Self.stubbed())
        await #expect(throws: APIError.http(status: 401, code: "wrong_pin", message: "PIN 不對")) {
            _ = try await wrong.walletRefund(WalletRefundRequest(intentId: "pi_abc", amount: nil, refundId: "ref-1", reason: nil, managerPin: "0000"))
        }
    }

    /// 舊的假後台（沒實作掃碼付）：當作後台還不支援
    @Test func defaultImplementationSaysUnsupported() async {
        let api = FakeServer()
        await #expect(throws: APIError.http(status: 404, code: "unsupported", message: APIError.walletPayUnsupported)) {
            _ = try await api.walletIntent(id: "pi_abc")
        }
    }
}

/// 假的網站：照方法、路徑與本文回掃碼付的回應
final class WalletStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.respond(to: request)
        let url = request.url ?? URL(string: "https://cms.example.tw")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// 請求的本文（URLProtocol 裡有時只拿得到 stream）
    static func body(of r: URLRequest) -> String {
        if let d = r.httpBody { return String(decoding: d, as: UTF8.self) }
        guard let s = r.httpBodyStream else { return "" }
        s.open()
        defer { s.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: size)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func respond(to r: URLRequest) -> (Int, String) {
        let token = r.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        guard token.hasPrefix("sxpos_dev.") else { return (401, #"{"error":"unauthorized"}"#) }
        let body = Self.body(of: r)
        switch (r.httpMethod ?? "GET", r.url?.path ?? "") {
        case ("POST", "/api/pos/v1/pay/scan"):
            // 讀得到本文就檢查（金額是分、付款 id）
            if !body.isEmpty, !(body.contains(#""paymentId":"pay-1""#) && body.contains(#""amount":12000"#)) { return (400, #"{"error":"invalid","message":"本文不對"}"#) }
            return (200, #"{"status":"processing","intentId":"pi_abc","amount":12000,"pollAfterMs":3000,"pollUntil":"2026-10-09T06:21:00.000Z"}"#)
        case ("GET", "/api/pos/v1/pay/intents/pi_abc"):
            return (200, #"{"status":"succeeded","intentId":"pi_abc","amount":12000,"pspTransactionId":"2026100912345678"}"#)
        case ("POST", "/api/pos/v1/pay/intents/pi_abc/cancel"):
            return (200, #"{"status":"processing","intentId":"pi_abc","amount":12000,"cancelable":false,"message":"錢包正在處理，現在不能取消"}"#)
        case ("POST", "/api/pos/v1/pay/refunds"):
            if token == "sxpos_dev.manager" { return (200, #"{"refundId":"re_1","status":"succeeded","amount":12000}"#) }
            if token == "sxpos_dev.wrong" { return (401, #"{"error":"wrong_pin","message":"PIN 不對"}"#) }
            return (403, #"{"error":"manager_approval_required","message":"POS 退款超過 NT$1,000 要店長核准"}"#)
        default:
            return (404, #"{"error":"not_found"}"#)
        }
    }
}
