import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import POSCore
@testable import POSSync

/// 個人的裝置拿不到 PIN 雜湊、主管授權問後台：docs/API.md「用 StudioX 帳號登入」第 5 步
struct VerifyPinTests {
    /// 個人的裝置的開機資料：staff[] 照樣有每個人，但沒有 pinHash、pinSalt、pinIterations → 讀得進來、本機驗不了 PIN
    @Test func personalBootstrapWithoutPinHashesDecodes() throws {
        let sample = try #require(try ContractSamples.samples()["bootstrap.json"])
        var root = try #require(try JSONSerialization.jsonObject(with: Data(sample.utf8)) as? [String: Any])
        var staff = try #require(root["staff"] as? [[String: Any]])
        staff = staff.map { s in
            var s = s
            for k in ["pinHash", "pinSalt", "pinIterations"] { s.removeValue(forKey: k) }
            return s
        }
        root["staff"] = staff
        var device = try #require(root["device"] as? [String: Any])
        device["personal"] = true
        device["staffId"] = "staff-leslie"
        root["device"] = device
        let data = try JSONSerialization.data(withJSONObject: root)

        let boot = try EventCoding.decoder().decode(Bootstrap.self, from: data)
        let leslie = try #require(boot.staff.first)
        #expect(boot.device.personal == true && boot.device.staffId == "staff-leslie")
        #expect(leslie.name == "Leslie" && leslie.role == .cashier && leslie.isActive)
        #expect(leslie.pinHash == nil && leslie.pinSalt == nil && leslie.pinIterations == nil && !leslie.hasPin)
        #expect(!leslie.verify(pin: "1234"))
        #expect(Staff.match(pin: "1234", in: boot.staff) == nil)

        // 存起來（DeviceStore 存開機資料）再讀：還是沒有雜湊，JSON 裡也不會多出來
        let again = try EventCoding.encoder().encode(boot)
        #expect(!String(decoding: again, as: UTF8.self).contains("pin"))
        #expect(try EventCoding.decoder().decode(Bootstrap.self, from: again).staff == boot.staff)

        // 共用的裝置（原本的範例）照舊有雜湊、本機驗得過
        let shared = try EventCoding.decoder().decode(Bootstrap.self, from: Data(sample.utf8))
        #expect(shared.staff.first?.hasPin == true && shared.staff.first?.verify(pin: "1234") == true)
    }

    @Test func requestShape() throws {
        let enc = EventCoding.encoder()
        let full = try JSONSerialization.jsonObject(with: enc.encode(VerifyPinRequest(staffId: "s1", pin: "1234", purpose: "voidTicket"))) as? [String: String]
        #expect(full == ["staffId": "s1", "pin": "1234", "purpose": "voidTicket"])
        // staffId 省略＝看 PIN 對到誰：不寫 null，整個不出現
        let anyone = try JSONSerialization.jsonObject(with: enc.encode(VerifyPinRequest(pin: "1234", purpose: "refund"))) as? [String: String]
        #expect(anyone == ["pin": "1234", "purpose": "refund"])
    }

    @Test func verifiedStaffRole() throws {
        let ok = try EventCoding.decoder().decode(VerifyPinResponse.self, from: Data(#"{"staff":{"id":"s1","name":"林老闆","role":"owner"}}"#.utf8))
        #expect(ok.staff == VerifiedStaff(id: "s1", name: "林老闆", role: "owner") && ok.staff.staffRole == .owner)
        // 不認得的職能：讀得進來、當作收銀（不多給權限）
        let odd = try EventCoding.decoder().decode(VerifyPinResponse.self, from: Data(#"{"staff":{"id":"s2","name":"x","role":"boss"}}"#.utf8))
        #expect(odd.staff.staffRole == .cashier)
    }

    private func client(token: String = "sxpos_dev.secret") -> POSClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VerifyPinStub.self]
        return POSClient(cmsURL: URL(string: "https://cms.example.tw")!, token: token, session: URLSession(configuration: config))
    }

    /// 真的 POSClient：路徑、方法、本文；wrong_pin 不是「這台登入失效」、429 的訊息、斷線、舊版後台
    @Test func clientCallsVerifyPin() async throws {
        let c = client()
        let manager = try await c.verifyPin(staffId: "staff-chen", pin: "2468", purpose: "voidTicket")
        #expect(manager == VerifiedStaff(id: "staff-chen", name: "陳店長", role: "manager"))
        let anyone = try await c.verifyPin(staffId: nil, pin: "1357", purpose: "refund")
        #expect(anyone.id == "staff-lin" && anyone.staffRole == .owner)
        let blankId = try await c.verifyPin(staffId: "", pin: "1357", purpose: "refund")
        #expect(blankId.id == "staff-lin")

        func failure(_ pin: String, token: String = "sxpos_dev.secret") async -> APIError? {
            do {
                _ = try await client(token: token).verifyPin(staffId: nil, pin: pin, purpose: "voidTicket")
                return nil
            } catch {
                return error as? APIError
            }
        }
        let wrong = await failure("0000")
        #expect(wrong == .http(status: 401, code: "wrong_pin", message: "PIN 不對"))
        #expect(wrong?.isWrongPin == true && wrong?.userMessage == "PIN 不對")
        // 後台沒給訊息：補上「PIN 不對」
        #expect(await failure("0001") == .http(status: 401, code: "wrong_pin", message: APIError.wrongPinMessage))
        let limited = await failure("9999")
        #expect(limited == .http(status: 429, code: "rate_limited", message: "錯太多次了，10 分鐘後再試"))
        #expect(limited?.isWrongPin == false)
        #expect(await failure("9998") == .http(status: 429, code: "rate_limited", message: APIError.pinRateLimitedMessage))
        // token 不對還是 unauthorized（回配對畫面那一種），和 PIN 不對分開
        #expect(await failure("1357", token: "sxpos_other.secret") == .unauthorized)
        if case .offline = await failure("5555") {} else { Issue.record("斷線要是 .offline") }
        #expect(await failure("4040") == .http(status: 404, code: "http_404", message: POSClient.verifyPinUnsupported))
    }

    /// 舊的假後台（沒有 verifyPin）：當作後台還不支援
    @Test func defaultImplementationIsUnsupported() async {
        do {
            _ = try await FakeServer().verifyPin(staffId: nil, pin: "1234", purpose: "refund")
            Issue.record("舊的假後台不能驗 PIN")
        } catch let e as APIError {
            #expect(e == .http(status: 404, code: "unsupported", message: POSClient.verifyPinUnsupported))
        } catch {
            Issue.record("\(error)")
        }
    }
}

/// 假的後台：只回 verify-pin（照本文的 PIN 決定；沒有共用的狀態，測試平行跑也不會互相影響）
final class VerifyPinStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        if body["pin"] as? String == "5555" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, text) = Self.respond(to: request, body: body)
        let url = request.url ?? URL(string: "https://cms.example.tw")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLProtocol 收到的請求本文在 httpBodyStream 裡（httpBody 是 nil）
    static func body(of r: URLRequest) -> [String: Any] {
        var data = r.httpBody ?? Data()
        if data.isEmpty, let stream = r.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func respond(to r: URLRequest, body: [String: Any]) -> (Int, String) {
        guard r.value(forHTTPHeaderField: "Authorization") == "Bearer sxpos_dev.secret", let url = r.url else {
            return (401, #"{"error":"unauthorized","message":"這台裝置還沒配對，或配對已經失效"}"#)
        }
        guard url.path == "/api/pos/v1/staff/verify-pin", r.httpMethod == "POST",
              r.value(forHTTPHeaderField: "Content-Type") == "application/json" else {
            return (400, #"{"error":"bad_request","message":"\#(r.httpMethod ?? "") \#(url.path)"}"#)
        }
        guard body["purpose"] as? String == "voidTicket" || body["purpose"] as? String == "refund" else {
            return (400, #"{"error":"invalid","message":"purpose"}"#)
        }
        let staffId = body["staffId"] as? String
        // 沒給 staffId 的時候整個不出現（不是 null、不是空字串）
        if body.keys.contains("staffId") && (staffId ?? "").isEmpty { return (400, #"{"error":"invalid","message":"staffId"}"#) }
        switch (body["pin"] as? String, staffId) {
        case ("2468", "staff-chen"): return (200, #"{"staff":{"id":"staff-chen","name":"陳店長","role":"manager"}}"#)
        case ("1357", nil): return (200, #"{"staff":{"id":"staff-lin","name":"林老闆","role":"owner"}}"#)
        case ("0001", _): return (401, #"{"error":"wrong_pin"}"#)
        case ("9999", _): return (429, #"{"error":"rate_limited","message":"錯太多次了，10 分鐘後再試"}"#)
        case ("9998", _): return (429, #"{"error":"rate_limited"}"#)
        // 舊版的後台：沒有這個路徑（Next.js 的 404 頁，不是 JSON）
        case ("4040", _): return (404, "<!DOCTYPE html><title>404</title>")
        default: return (401, #"{"error":"wrong_pin","message":"PIN 不對"}"#)
        }
    }
}
