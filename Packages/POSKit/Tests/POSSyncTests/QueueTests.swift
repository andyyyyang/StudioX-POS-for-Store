import Foundation
import Testing
@testable import POSCore
@testable import POSSync

/// 叫號（號碼牌）的資料格式：docs/API.md「叫號」
struct QueueTests {
    private let dec = EventCoding.decoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try dec.decode(type, from: Data(json.utf8))
    }

    @Test func nativeStateRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let s = QueueState(mode: .native, current: 23, waiting: [24, 25], missed: [19], marked: [25], nextNo: 26, calledAt: at, updatedAt: at,
                           takenAt: ["24": at.addingTimeInterval(-600), "25": at.addingTimeInterval(-120)], servedToday: 22)
        let data = try EventCoding.encoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"calledAt\":\"2026-09-21T14:13:20.000Z\""))
        #expect(!json.contains("numbers"))
        let back = try dec.decode(QueueState.self, from: data)
        #expect(back == s)
        #expect(back.waitMinutes(24, now: at) == 10)
        #expect(back.averageWaitMinutes(now: at) == 6)
        #expect(back.takenToday == 25)
    }

    /// 舊的叫號伺服器：只有 current、waiting、missed、marked、next_no；current 可能是 null，marked 可能沒有
    @Test func legacyStateIsTolerated() throws {
        let s = try decode(QueueState.self, #"{ "current": null, "waiting": [3, 4], "missed": [1], "next_no": 5 }"#)
        #expect(s.current == nil && s.waiting == [3, 4] && s.missed == [1] && s.marked.isEmpty && s.nextNo == 5)
        #expect(s.mode == nil && s.takenAt.isEmpty && s.servedToday == nil)
        #expect(s.waitMinutes(3, now: Date()) == nil && s.averageWaitMinutes(now: Date()) == nil)
        #expect(s.highestNumber == 4)

        // 看不懂的欄位當作沒有，不要整份讀不進來
        let odd = try decode(QueueState.self, #"{ "mode": "cloud", "current": 7, "waiting": "x", "takenAt": { "8": "…", "9": "2026-10-04T07:01:10.000Z" } }"#)
        #expect(odd.mode == .native && odd.current == 7 && odd.waiting.isEmpty)
        #expect(odd.takenAt.count == 1 && odd.takenTime(of: 9) != nil)

        let empty = try decode(QueueState.self, "{}")
        #expect(empty.isEmpty && empty.highestNumber == 0)
    }

    @Test func takeResponseCarriesNumbers() throws {
        let s = try decode(QueueState.self, #"{ "mode": "legacy", "current": 2, "waiting": [3, 4, 5], "missed": [], "marked": [], "nextNo": 6, "numbers": [4, 5] }"#)
        #expect(s.numbers == [4, 5])
        #expect(s.mode == .legacy && s.mode?.canRecall == false)
    }

    @Test func actionsEncodeTheContractBodies() throws {
        let enc = EventCoding.encoder()
        func body(_ a: QueueAction) throws -> String { String(decoding: try enc.encode(a.body), as: UTF8.self) }
        #expect(QueueAction.take(count: 3, requestId: "r1").path == "take")
        #expect(try body(.take(count: 3, requestId: "r1")) == #"{"count":3,"requestId":"r1"}"#)
        // 一次最多 20 張
        #expect(try body(.take(count: 50, requestId: "r1")) == #"{"count":20,"requestId":"r1"}"#)
        #expect(try body(.next(requestId: "r2")) == #"{"requestId":"r2"}"#)
        #expect(try body(.miss(requestId: "r3")) == #"{"requestId":"r3"}"#)
        #expect(try body(.previous) == "{}")
        #expect(try body(.recall(19)) == #"{"number":19}"#)
        #expect(try body(.unmiss(19)) == #"{"number":19}"#)
        #expect(QueueAction.unmark(25).path == "unmark")
        #expect(try body(.reset(staffId: "staff-1")) == #"{"staffId":"staff-1"}"#)
        // 作廢的單放回號碼
        #expect(QueueAction.cancel(33, requestId: "cancel-t1").path == "cancel")
        #expect(try body(.cancel(33, requestId: "cancel-t1")) == #"{"number":33,"requestId":"cancel-t1"}"#)
    }

    /// 網址樣板的 {date}：營業日（號碼每天從 1 開始）；沒給日期就空白
    @Test func customerLinkFillsTheDate() throws {
        let c = try decode(QueueConfig.self, #"{ "customerUrl": "https://yellowgirl.tw/q/{number}?d={date}" }"#)
        #expect(c.customerLink(number: 33, waiting: 5, date: "20261005") == "https://yellowgirl.tw/q/33?d=20261005")
        #expect(c.customerLink(number: 33, waiting: 5) == "https://yellowgirl.tw/q/33?d=")
    }

    /// 版面：沒給的用樹莓派的預設；給一半的補齊；給錯的也印得出來
    @Test func ticketLayoutDefaults() throws {
        let none = try decode(QueueConfig.self, "{}")
        #expect(none.mode == .native && none.customerUrl == nil && none.ticket == .standard)
        #expect(none.ticket.number == QueueTicketLayout.Line(y: 140, size: 90, color: .white))
        #expect(none.ticket.waiting.y == 290 && none.ticket.waiting.size == 20 && none.ticket.waiting.color == .black)
        #expect(none.ticket.qrSide == 172 && none.ticket.qr.bottom == 100 && none.ticket.height == 640 && none.ticket.copies == 1)

        let partial = try decode(QueueConfig.self, #"""
        { "mode": "legacy", "customerUrl": " https://shop.tw/q?no={number}&waiting={waiting} ",
          "ticket": { "backgroundUrl": "", "copies": 99, "number": { "size": 120, "color": "BLACK" }, "waiting": { "text": "前面還有 {waiting} 位" }, "qr": { "size": 0.5 } } }
        """#)
        #expect(partial.mode == .legacy)
        #expect(partial.ticket.backgroundUrl == nil)
        #expect(partial.ticket.copies == 5)
        #expect(partial.ticket.number == QueueTicketLayout.Line(y: 140, size: 120, color: .black))
        #expect(partial.ticket.waitingText(waiting: 3, number: 27) == "前面還有 3 位")
        #expect(partial.ticket.qrSide == 192 && partial.ticket.qr.bottom == 100)
        #expect(partial.customerLink(number: 27, waiting: 3) == "https://shop.tw/q?no=27&waiting=3")
        #expect(QueueTicketLayout.standard.waitingText(waiting: 5, number: 1) == "目前 5 人等候中")

        let broken = try decode(QueueConfig.self, #"{ "mode": 3, "ticket": "x" }"#)
        #expect(broken.mode == .native && broken.ticket == .standard)
    }

    @Test func bootstrapWithoutQueueStillDecodes() throws {
        let s = try ContractSamples.samples()
        var json = try JSONSerialization.jsonObject(with: Data(s["bootstrap.json"]!.utf8)) as! [String: Any]
        json["queue"] = nil
        var features = json["features"] as! [String: Any]
        features["queue"] = nil
        json["features"] = features
        let b = try dec.decode(Bootstrap.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(b.queue == nil && b.features.queue == false)
    }

    /// 舊的假後台（沒實作叫號）：當作後台還不支援
    @Test func defaultImplementationSaysUnsupported() async {
        let api = FakeServer()
        await #expect(throws: APIError.self) { _ = try await api.queue() }
        await #expect(throws: APIError.self) { _ = try await api.queue(.previous) }
    }

    @Test func resetNeedsAManager() {
        #expect(Permission.resetQueue.minimumRole == .manager)
        let spec = KeypadSpec.queueTickets()
        var e = KeypadEntry(spec)
        e.press(.digit(2)); e.press(.digit(5))
        #expect(e.problem == "最多 20")
        e.press(.clear); e.press(.digit(3))
        #expect(e.canCommit && e.value == 3)
    }
}
