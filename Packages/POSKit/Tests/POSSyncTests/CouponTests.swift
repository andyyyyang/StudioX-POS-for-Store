import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import POSCore
@testable import POSSync

/// 門市折價券：docs/API.md「折價券（門市）」
struct CouponTests {
    private let dec = EventCoding.decoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try dec.decode(type, from: Data(json.utf8))
    }

    @Test func lookupDecodesTheContract() throws {
        let ok = try decode(CouponLookup.self, #"""
        { "coupon": { "code": "YG-A3B2C1", "name": "新會員 100 元", "description": "第一次來店", "type": "fixed", "value": 10000,
                      "minimumOrder": 30000, "expiresAt": "2026-12-31T15:59:59.000Z", "usesLeft": 1 }, "problem": null }
        """#)
        #expect(ok.problem == nil)
        #expect(ok.coupon.type == .fixed && ok.coupon.value == 10_000 && ok.coupon.minimumOrder == Money(dollars: 300) && ok.coupon.usesLeft == 1)
        #expect(ok.coupon.reason == "折價券 新會員 100 元")
        let d = try #require(ok.coupon.discount)
        #expect(d.kind == .amount && d.value == 10_000 && d.couponCode == "YG-A3B2C1" && d.minimumOrder == Money(dollars: 300))
        #expect(d.reason == "折價券 新會員 100 元")
        #expect(d.amount(on: Money(dollars: 360)) == Money(dollars: 100))

        // 選填的都沒給、problem 沒寫
        let vip = try decode(CouponLookup.self, #"{ "coupon": { "code": "VIP10", "name": "", "type": "percentage", "value": 1000 } }"#)
        #expect(vip.problem == nil && vip.coupon.displayName == "VIP10")
        let p = try #require(vip.coupon.discount)
        #expect(p.kind == .percent && p.value == 1000 && p.label == "9 折" && p.minimumOrder == nil)
        #expect(p.amount(on: Money(dollars: 450)) == Money(dollars: 45))

        // 不能用：照樣有券（店員看得到是哪一張）；空白的 problem 當作可以用
        let expired = try decode(CouponLookup.self, #"{ "coupon": { "code": "EXPIRED", "name": "中秋 50 元", "type": "fixed", "value": 5000 }, "problem": "已經過期（9/30）" }"#)
        #expect(expired.problem == "已經過期（9/30）")
        let blank = try decode(CouponLookup.self, #"{ "coupon": { "code": "X1X1", "name": "x", "type": "fixed", "value": 5000 }, "problem": "  " }"#)
        #expect(blank.problem == nil)

        // 免運券、不認得的種類：讀得進來，但門市不能用
        let ship = try decode(CouponLookup.self, #"{ "coupon": { "code": "SHIPFREE", "name": "免運", "type": "free_shipping", "value": 0 }, "problem": "免運券不能在門市用" }"#)
        #expect(ship.coupon.type == .other("free_shipping") && ship.coupon.discount == nil)
        // 0 元、超過 100% 的也不能用
        #expect(Coupon(code: "ZERO", name: "", type: .fixed, value: 0).discount == nil)
        #expect(Coupon(code: "MORE", name: "", type: .percentage, value: 12_000).discount == nil)
        // minimumOrder 是 0＝不限
        #expect(Coupon(code: "FREE0", name: "", type: .fixed, value: 100, minimumOrder: .zero).discount?.minimumOrder == nil)
    }

    @Test func lookupEncodesProblemAsNull() throws {
        let json = String(decoding: try EventCoding.encoder().encode(CouponLookup(coupon: Coupon(code: "VIP10", name: "VIP 9 折", type: .percentage, value: 1000))), as: UTF8.self)
        #expect(json == #"{"coupon":{"code":"VIP10","name":"VIP 9 折","type":"percentage","value":1000},"problem":null}"#)
        let back = try decode(CouponLookup.self, json)
        #expect(back.coupon.type == .percentage && back.problem == nil)
    }

    /// 真的 POSClient：路徑、query、404 not_found＝沒有這張券（nil）、舊版後台的 404＝說後台還不支援
    @Test func clientMapsNotFoundToNil() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CouponStub.self]
        let client = POSClient(cmsURL: URL(string: "https://cms.example.tw")!, token: "sxpos_dev.secret", session: URLSession(configuration: config))

        let found = try await client.coupon(code: "WELCOME100", subtotal: Money(dollars: 300), memberId: "mem-1")
        #expect(found?.coupon.code == "WELCOME100" && found?.coupon.discount?.value == 10_000 && found?.problem == nil)

        let missing = try await client.coupon(code: "NOPE", subtotal: Money(dollars: 300), memberId: nil)
        #expect(missing == nil)

        do {
            _ = try await client.coupon(code: "OLDCMS", subtotal: .zero, memberId: nil)
            Issue.record("舊版後台的 404 不能當作沒有這張券")
        } catch let e as APIError {
            #expect(e == .http(status: 404, code: "http_404", message: POSClient.couponsUnsupported))
        }
    }
}

/// 假的後台：只回折價券（照路徑與 query 決定；沒有共用的狀態，測試平行跑也不會互相影響）
final class CouponStub: URLProtocol, @unchecked Sendable {
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

    static func respond(to r: URLRequest) -> (Int, String) {
        guard r.value(forHTTPHeaderField: "Authorization") == "Bearer sxpos_dev.secret", let url = r.url else {
            return (401, #"{"error":"unauthorized"}"#)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? ""
        switch url.path {
        case "/api/pos/v1/coupons/WELCOME100":
            guard query == "memberId=mem-1&subtotal=30000" else { return (400, #"{"error":"bad_query","message":"\#(query)"}"#) }
            return (200, #"{"coupon":{"code":"WELCOME100","name":"新會員 100 元","type":"fixed","value":10000,"minimumOrder":30000},"problem":null}"#)
        case "/api/pos/v1/coupons/NOPE":
            guard query == "subtotal=30000" else { return (400, #"{"error":"bad_query","message":"\#(query)"}"#) }
            return (404, #"{"error":"not_found","message":"沒有這張折價券"}"#)
        default:
            // 舊版的後台：沒有這個路徑（Next.js 的 404 頁，不是 JSON）
            return (404, "<!DOCTYPE html><title>404</title>")
        }
    }
}
