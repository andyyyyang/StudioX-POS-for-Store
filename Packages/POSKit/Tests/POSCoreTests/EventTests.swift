import Foundation
import Testing
@testable import POSCore

struct EventTests {
    @Test func hashChainAndRoundTrip() throws {
        var d = Device("A")
        let e1 = d.emit(.ticketOpened(TicketOpened(ticketId: "t1", number: "A001", orderType: .dineIn, tableIds: ["t1"], guests: 2, businessDate: "2026-09-21")))
        let e2 = d.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60)])))
        #expect(e1.prevHash == POSEvent.genesis)
        #expect(e2.prevHash == e1.hash)
        #expect(e1.isHashValid && e2.isHashValid)

        let json = try JSONEncoder().encode(e2)
        let back = try JSONDecoder().decode(POSEvent.self, from: json)
        #expect(back == e2)
        #expect(back.isHashValid)
        if case .linesAdded(let a) = back.body { #expect(a.lines.first?.name == "珍奶") } else { Issue.record("內容解不開") }

        // 改了內容 → 雜湊對不上
        var dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        dict["data"] = (dict["data"] as! String).replacingOccurrences(of: "6000", with: "100")
        let tampered = try JSONDecoder().decode(POSEvent.self, from: JSONSerialization.data(withJSONObject: dict))
        #expect(!tampered.isHashValid)
    }

    @Test func hashIsTheDocumentedString() throws {
        // docs/API.md 的規則：SHA-256(id|deviceId|seq|lamport|at|staffId|type|prevHash|data)；後台照這個驗
        let e = try POSEvent(id: "e1", deviceId: "dev", seq: 1, lamport: 7, at: Date(timeIntervalSince1970: 1_790_000_000.123),
                             staffId: nil, body: .tableCleaned(TableRef(tableId: "t9")), prevHash: POSEvent.genesis)
        #expect(e.at == "2026-09-21T14:13:20.123Z")
        #expect(e.data == #"{"tableId":"t9"}"#)
        let expected = Crypto.SHA256.hex("e1|dev|1|7|2026-09-21T14:13:20.123Z||table.cleaned|\(POSEvent.genesis)|{\"tableId\":\"t9\"}")
        #expect(e.hash == expected)
    }

    @Test func timestampRoundTrip() {
        let d = Date(timeIntervalSince1970: 1_790_000_000.5)
        let s = EventCoding.timestamp(d)
        #expect(s == "2026-09-21T14:13:20.500Z")
        #expect(EventCoding.parseTimestamp(s) == d)
        #expect(EventCoding.parseTimestamp("2026-09-21T14:13:20Z") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(EventCoding.parseTimestamp("garbage") == nil)
    }

    /// 新版 App 的事件：舊版照樣收下、原樣保留（雜湊不變、轉送不變），只是不做投影
    @Test func unknownEventTypeIsKeptVerbatim() throws {
        let body = try EventBody.decode(type: "future.thing", data: #"{"b":1,"a":2}"#)
        #expect(body == .unknown(type: "future.thing", data: #"{"b":1,"a":2}"#))
        #expect(body.type == "future.thing")
        #expect(try body.encodedData() == #"{"b":1,"a":2}"#)
        let e = try POSEvent(id: "e1", deviceId: "d", seq: 1, lamport: 1, at: Date(timeIntervalSince1970: 0), staffId: nil, body: body, prevHash: POSEvent.genesis)
        let round = try JSONDecoder().decode(POSEvent.self, from: JSONEncoder().encode(e))
        #expect(round.isHashValid)
        #expect(round.data == #"{"b":1,"a":2}"#)
        var state = StoreState()
        state.apply(round)
        #expect(state.applied == 1)
    }
}

struct StoreStateTests {
    func open(_ d: inout Device, ticket: String = "t1", table: String = "t1", number: String = "A001") -> POSEvent {
        d.emit(.ticketOpened(TicketOpened(ticketId: ticket, number: number, orderType: .dineIn, tableIds: [table], guests: 2, serviceChargeBps: 1000, businessDate: "2026-09-21")))
    }

    @Test func fullDineInFlow() throws {
        var d = Device("A")
        var events = [open(&d)]
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60, qty: 2), Fixture.line("l2", "雞排", 80, category: "fried")]))))
        events.append(d.emit(.linesSent(LinesSent(ticketId: "t1", lineIds: ["l1", "l2"]))))
        var s = StoreState.replay(events)
        #expect(s.status(of: "t1") == .ordering)
        #expect(s.tickets["t1"]?.lines.allSatisfy { $0.kitchen == .sent } == true)

        events.append(d.emit(.lineUpdated(LineUpdated(ticketId: "t1", lineId: "l1", quantity: 3))))
        events.append(d.emit(.linesVoided(LinesVoided(ticketId: "t1", lineIds: ["l2"], reason: "客人不要了", authorizedBy: "mgr"))))
        events.append(d.emit(.billPrinted(TicketRef(ticketId: "t1"))))
        events.append(d.emit(.shiftOpened(ShiftOpened(shiftId: "sh1", openingCash: Money(dollars: 2000), businessDate: "2026-09-21"))))
        s = StoreState.replay(events)
        #expect(s.status(of: "t1") == .billing)
        let t = try #require(s.tickets["t1"])
        #expect(t.totals.total == Money(dollars: 198)) // 180 + 10% 服務費
        #expect(t.lines[1].voided?.wasSent == true)

        let pay = Payment.cash(id: "p1", tendered: Money(dollars: 200), due: t.totals.amountDue, at: d.clock, by: "s1", shiftId: "sh1")
        events.append(d.emit(.paymentAdded(PaymentAdded(ticketId: "t1", payment: pay))))
        s = StoreState.replay(events)
        let paid = try #require(s.tickets["t1"])
        let sale = SaleRecord(ticket: paid, closedOn: "A", shiftId: "sh1", closedAt: d.clock, closedBy: "s1", staffName: "Leslie", floor: Fixture.floor)
        events.append(d.emit(.ticketClosed(TicketClosed(ticketId: "t1", sale: sale))))
        s = StoreState.replay(events)
        #expect(s.tickets["t1"]?.status == .closed)
        #expect(s.status(of: "t1") == .needsCleaning)
        #expect(s.expectedCash(shiftId: "sh1") == Money(dollars: 2198))

        events.append(d.emit(.tableCleaned(TableRef(tableId: "t1"))))
        s = StoreState.replay(events)
        #expect(s.status(of: "t1") == .available)
        #expect(s.nextTicketNumber(deviceCode: "A", businessDate: "2026-09-21") == "A002")
        #expect(s.nextTicketNumber(deviceCode: "B", businessDate: "2026-09-21") == "B001")

        let summary = s.dailySummary(businessDate: "2026-09-21")
        #expect(summary.tickets == 1)
        #expect(summary.total == Money(dollars: 198))
        #expect(summary.byTender.first?.tender == .cash)
        #expect(summary.voidedItems == 1)
        #expect(summary.topItems.first?.name == "珍奶")
        #expect(summary.topItems.first?.quantity == 3)
    }

    @Test func replayIsOrderIndependent() {
        // 兩台各做各的，事件以不同順序到達，結果一樣
        var a = Device("A"), b = Device("B")
        var ea = [open(&a)]
        ea.append(a.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60)]))))
        b.observe(ea)
        let eb = [b.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l2", "紅茶", 30)]))),
                  b.emit(.lineUpdated(LineUpdated(ticketId: "t1", lineId: "l1", quantity: 2)))]
        let s1 = StoreState.replay(ea + eb)
        let s2 = StoreState.replay(eb.reversed() + ea.reversed())
        #expect(s1.tickets == s2.tickets)
        #expect(s1.tickets["t1"]?.totals.itemsGross == Money(dollars: 150))
    }

    @Test func duplicatesAreHarmless() {
        var d = Device("A")
        let o = open(&d)
        let add = d.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60)])))
        var s = StoreState()
        for e in [o, add, add, o] { s.apply(e) }
        #expect(s.tickets["t1"]?.lines.count == 1)
    }

    @Test func offlineDoubleCloseIsFlagged() throws {
        var a = Device("A"), b = Device("B")
        var shared = [open(&a)]
        shared.append(a.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60)]))))
        b.observe(shared)
        let base = StoreState.replay(shared)
        let t = try #require(base.tickets["t1"])

        // 斷網：兩台都收錢結帳
        func close(_ dev: inout Device, _ pid: String) -> [POSEvent] {
            let p = Payment(id: pid, tender: .cash, amount: Money(dollars: 66), at: dev.clock, by: "s1")
            var paid = t
            paid.payments = [p]
            let sale = SaleRecord(ticket: paid, closedOn: dev.id, shiftId: nil, closedAt: dev.clock, closedBy: "s1", staffName: "x", floor: Fixture.floor)
            return [dev.emit(.paymentAdded(PaymentAdded(ticketId: "t1", payment: p))), dev.emit(.ticketClosed(TicketClosed(ticketId: "t1", sale: sale)))]
        }
        let fromA = close(&a, "pa"), fromB = close(&b, "pb")
        let merged = StoreState.replay(shared + fromA + fromB)
        // 兩筆錢都記著（真的收了），第二次結帳被擋下來並留一筆衝突給店長
        #expect(merged.tickets["t1"]?.payments.count == 2)
        #expect(merged.tickets["t1"]?.totals.balance == Money(dollars: -66))
        #expect(merged.unresolvedConflicts.map(\.kind) == [.doubleClose])
        #expect(merged.sales.count == 1)

        // 結帳的事件先到、另一台的收款晚到：記成「結帳後又收錢」
        var c = Device("C")
        c.observe(shared + fromA)
        let afterClose = c.emit(.paymentAdded(PaymentAdded(ticketId: "t1", payment: Payment(id: "pc", tender: .card, amount: Money(dollars: 66), at: c.clock, by: "s1"))))
        let s3 = StoreState.replay(shared + fromA + [afterClose])
        #expect(s3.unresolvedConflicts.map(\.kind) == [.paymentAfterClose])
    }

    @Test func splitAndMerge() throws {
        var d = Device("A")
        var ev = [open(&d)]
        ev.append(d.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 60, qty: 3), Fixture.line("l2", "雞排", 80)]))))
        ev.append(d.emit(.ticketSplit(TicketSplit(
            sourceId: "t1",
            opened: TicketOpened(ticketId: "t2", number: "A002", orderType: .dineIn, tableIds: ["t1"], guests: 1, serviceChargeBps: 1000, businessDate: "2026-09-21"),
            moves: [SplitMove(lineId: "l1", quantity: 1, newLineId: "l1b"), SplitMove(lineId: "l2", quantity: 1, newLineId: "l2b")]
        ))))
        var s = StoreState.replay(ev)
        #expect(s.tickets["t1"]?.lines.map(\.quantity) == [2])
        #expect(s.tickets["t2"]?.lines.map(\.id) == ["l1b", "l2b"])
        #expect(s.tickets["t2"]?.splitFrom == "t1")
        #expect(s.openTickets(at: "t1").count == 2)

        ev.append(d.emit(.ticketsMerged(TicketsMerged(targetId: "t1", sourceId: "t2"))))
        s = StoreState.replay(ev)
        #expect(s.tickets["t1"]?.itemCount == 4)
        #expect(s.tickets["t2"]?.mergedInto == "t1")
        #expect(s.dailySummary(businessDate: "2026-09-21").voidedTickets == 0)
    }

    @Test func shiftReport() throws {
        var d = Device("A")
        var ev = [d.emit(.shiftOpened(ShiftOpened(shiftId: "sh", openingCash: Money(dollars: 1000), businessDate: "2026-09-21")))]
        ev.append(d.emit(.cashMoved(CashMoved(shiftId: "sh", move: CashMove(id: "m1", kind: .payOut, amount: Money(dollars: 300), reason: "買冰塊", at: d.clock, by: "s1")))))
        ev.append(open(&d))
        ev.append(d.emit(.linesAdded(LinesAdded(ticketId: "t1", lines: [Fixture.line("l1", "珍奶", 100)]))))
        let s0 = StoreState.replay(ev)
        let t = try #require(s0.tickets["t1"])
        let p = Payment.cash(id: "p", tendered: Money(dollars: 200), due: t.totals.amountDue, at: d.clock, by: "s1", shiftId: "sh")
        var paid = t; paid.payments = [p]
        ev.append(d.emit(.paymentAdded(PaymentAdded(ticketId: "t1", payment: p))))
        ev.append(d.emit(.ticketClosed(TicketClosed(ticketId: "t1", sale: SaleRecord(ticket: paid, closedOn: "A", shiftId: "sh", closedAt: d.clock, closedBy: "s1", staffName: "x", floor: Fixture.floor)))))
        let s = StoreState.replay(ev)
        #expect(s.expectedCash(shiftId: "sh") == Money(dollars: 810)) // 1000 − 300 + 110
        var count = CashCount()
        count.set(.d500, 1); count.set(.d100, 3); count.set(.d10, 1)
        let report = ShiftReport(shift: try #require(s.shifts["sh"]), state: s, now: d.clock, counted: count)
        #expect(report.countedCash == Money(dollars: 810))
        #expect(report.difference == .zero)
        #expect(report.payOuts == Money(dollars: 300))
        #expect(report.summary.tickets == 1)

        let json = try JSONEncoder().encode(count)
        #expect(String(decoding: json, as: UTF8.self).contains("\"500\":1"))
    }

    @Test func invoiceRanges() {
        #expect(SalesSummary.ranges(["AB00000003", "AB00000001", "AB00000002", "AB00000007", "CD00000008"]) ==
                ["AB00000001–AB00000003", "AB00000007", "CD00000008"])
    }

    @Test func staffPin() {
        let hash = Staff.hash(pin: "1234", salt: "abc", iterations: 100)
        let s = StaffMember(id: "s", name: "Leslie", role: .cashier, pinHash: hash, pinSalt: "abc", pinIterations: 100)
        #expect(s.verify(pin: "1234"))
        #expect(!s.verify(pin: "1235"))
        #expect(s.can(.sell))
        #expect(!s.can(.refund))
        #expect(StaffRole.owner > .manager)
        #expect(Staff.match(pin: "1234", in: [s]) == s)
    }
}

struct WireFormatTests {
    func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try EventCoding.encoder().encode(v), as: UTF8.self) }

    @Test func moneyIsPlainCents() throws {
        #expect(try json(Money(dollars: 12)) == "1200")
        #expect(try EventCoding.decoder().decode(Money.self, from: Data("1500".utf8)) == Money(dollars: 15))
    }

    @Test func invoiceBuyerShapes() throws {
        #expect(try json(InvoiceBuyer.paper) == #"{"kind":"consumer"}"#)
        #expect(try json(InvoiceBuyer.consumer(carrier: .mobileBarcode("/ABC+123"))) == #"{"carrier":{"id":"/ABC+123","type":"3J0002"},"kind":"consumer"}"#)
        #expect(try json(InvoiceBuyer.business(taxId: "22099131", title: "台積電")) == #"{"kind":"business","taxId":"22099131","title":"台積電"}"#)
        #expect(try json(InvoiceBuyer.donation(loveCode: "919")) == #"{"kind":"donation","loveCode":"919"}"#)
        for b in [InvoiceBuyer.paper, .consumer(carrier: .citizenCertificate("AB12345678901234")), .business(taxId: "22099131", title: nil), .donation(loveCode: "8455")] {
            #expect(try EventCoding.decoder().decode(InvoiceBuyer.self, from: Data(json(b).utf8)) == b)
        }
    }
}

struct StoreProfileDecodingTests {
    @Test func missingFieldsUseDefaults() throws {
        let p = try EventCoding.decoder().decode(StoreProfile.self, from: Data(#"{"name":"晨麥手作","serviceChargeBps":1000}"#.utf8))
        #expect(p.name == "晨麥手作")
        #expect(p.serviceChargeBps == 1000)
        #expect(p.serviceModes == ServiceMode.allCases)
        #expect(p.defaultServiceMode == .tableService)
        #expect(p.businessDayCutoffHour == 4)
    }

    @Test func unknownModesAreSkippedAndDefaultMustBeEnabled() throws {
        let json = #"{"name":"攤位","serviceModes":["retail","hologram"],"defaultServiceMode":"tableService"}"#
        let p = try EventCoding.decoder().decode(StoreProfile.self, from: Data(json.utf8))
        #expect(p.serviceModes == [.retail])
        #expect(p.defaultServiceMode == .retail)
        let back = try EventCoding.decoder().decode(StoreProfile.self, from: EventCoding.encoder().encode(p))
        #expect(back == p)
    }

    @Test func modes() {
        #expect(ServiceMode.counter.payFirst)
        #expect(!ServiceMode.tableService.payFirst)
        #expect(!ServiceMode.retail.usesKitchen)
        #expect(ServiceMode.cafe.printsPickupNumber)
        #expect(ServiceMode.counter.defaultOrderType == .takeout)
        let f = try? EventCoding.decoder().decode(FeatureFlags.self, from: Data("{}".utf8))
        #expect(f?.seating == true)
        #expect(f?.invoice == false)
    }
}
