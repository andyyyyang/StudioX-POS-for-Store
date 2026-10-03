import Foundation
import Testing
@testable import POSCore
@testable import POSSync

/// 假的後台：照 docs/API.md 的規則收事件（雜湊、流水號、去重），給 serverSeq
actor FakeServer: POSAPI {
    var events: [POSEvent] = []
    var bySeq: [String: [Int: POSEvent]] = [:]
    var offline = false
    var pushes = 0

    func setOffline(_ v: Bool) { offline = v }

    func push(_ batch: [POSEvent]) async throws -> EventsPushResult {
        if offline { throw APIError.offline("test") }
        pushes += 1
        var accepted: [String] = [], dups: [String] = [], rejected: [EventRejection] = []
        for e in batch {
            if events.contains(where: { $0.id == e.id }) { dups.append(e.id); continue }
            guard e.isHashValid else { rejected.append(EventRejection(id: e.id, reason: "bad_hash", expectSeq: nil)); continue }
            let prev = bySeq[e.deviceId]?[e.seq - 1]
            let expected = (bySeq[e.deviceId]?.keys.max() ?? 0) + 1
            if e.seq != expected || (e.seq == 1 ? e.prevHash != POSEvent.genesis : prev?.hash != e.prevHash) {
                rejected.append(EventRejection(id: e.id, reason: "chain_gap", expectSeq: expected))
                break
            }
            var stored = e
            stored.serverSeq = events.count + 1
            events.append(stored)
            bySeq[e.deviceId, default: [:]][e.seq] = stored
            accepted.append(e.id)
        }
        return EventsPushResult(accepted: accepted, duplicates: dups, rejected: rejected, serverSeq: events.count)
    }

    func pull(after: Int, limit: Int) async throws -> EventsPage {
        if offline { throw APIError.offline("test") }
        let page = Array(events.filter { ($0.serverSeq ?? 0) > after }.prefix(limit))
        return EventsPage(events: page, next: page.last?.serverSeq ?? after, hasMore: events.count > (page.last?.serverSeq ?? after))
    }

    func bootstrap(ifNoneMatch: String?) async throws -> Bootstrap { throw APIError.notModified }
    func requestRoll(period: String, count: Int) async throws -> RollResponse { throw APIError.http(status: 409, code: "no_numbers", message: nil) }
    func heartbeat(_ h: Heartbeat) async throws -> HeartbeatResponse { HeartbeatResponse(serverTime: Date(), configVersion: "v", serverSeq: events.count) }
    func member(phone: String) async throws -> Member? { nil }
    func createMember(_ m: MemberCreate) async throws -> Member { throw APIError.serviceOff }
    func reservations(date: String) async throws -> [Reservation] { [] }
    func createReservation(_ input: ReservationInput) async throws -> Reservation { throw APIError.serviceOff }
    func updateReservation(id: String, _ input: ReservationInput) async throws -> Reservation { throw APIError.serviceOff }
    func notifyReservation(id: String) async throws {}
    func saveFloor(_ update: FloorUpdate) async throws -> FloorResponse { throw APIError.serviceOff }
}

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("poskit-\(UUID().uuidString)")
}

struct JournalTests {
    @Test func appendIsDurableAndChained() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = try EventJournal(directory: dir, deviceId: "A")
        let e1 = try j.append(.tableCleaned(TableRef(tableId: "t1")), staffId: "s")
        let e2 = try j.append(.tableCleaned(TableRef(tableId: "t2")), staffId: "s")
        #expect(e1.seq == 1 && e2.seq == 2)
        #expect(e2.prevHash == e1.hash)
        #expect(j.verifyChain() == nil)

        // 重新打開：事件、雜湊鏈、時鐘都接得上
        let j2 = try EventJournal(directory: dir, deviceId: "A")
        #expect(j2.ownEvents.count == 2)
        let e3 = try j2.append(.tableCleaned(TableRef(tableId: "t3")), staffId: "s")
        #expect(e3.seq == 3 && e3.prevHash == e2.hash && e3.lamport == 3)
    }

    @Test func truncatedLastLineIsRepaired() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = try EventJournal(directory: dir, deviceId: "A")
        try j.append(.tableCleaned(TableRef(tableId: "t1")), staffId: nil)
        // 模擬當機：最後一行只寫了一半
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("own.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"id\":\"half".utf8)); try h.close()
        let j2 = try EventJournal(directory: dir, deviceId: "A")
        #expect(j2.ownEvents.count == 1)
        let next = try j2.append(.tableCleaned(TableRef(tableId: "t2")), staffId: nil)
        #expect(next.seq == 2)
        #expect(try EventJournal(directory: dir, deviceId: "A").ownEvents.count == 2)
    }

    @Test func ingestDedupesAndVerifies() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try EventJournal(directory: dir.appendingPathComponent("a"), deviceId: "A")
        let b = try EventJournal(directory: dir.appendingPathComponent("b"), deviceId: "B")
        let e = try a.append(.tableCleaned(TableRef(tableId: "t1")), staffId: nil)
        #expect(try b.ingest([e, e]).count == 1)
        #expect(try b.ingest([e]).isEmpty)
        // 自己的事件繞一圈回來不重收
        #expect(try a.ingest([e]).isEmpty)
        // 時鐘跟上
        let mine = try b.append(.tableCleaned(TableRef(tableId: "t2")), staffId: nil)
        #expect(mine.lamport > e.lamport)
    }
}

struct SyncEngineTests {
    func makeLedger(_ dir: URL, _ id: String) throws -> Ledger { Ledger(journal: try EventJournal(directory: dir.appendingPathComponent(id), deviceId: id)) }

    @Test func twoDevicesConvergeThroughServer() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeServer()
        let a = try makeLedger(dir, "A"), b = try makeLedger(dir, "B")
        let ea = SyncEngine(api: server, ledger: a), eb = SyncEngine(api: server, ledger: b)

        try a.record(.ticketOpened(TicketOpened(ticketId: "t1", number: "A001", orderType: .dineIn, tableIds: ["x"], businessDate: "2026-10-03")), staffId: "s")
        try a.record(.linesAdded(LinesAdded(ticketId: "t1", lines: [TicketLine(id: "l1", itemId: "i", name: "珍奶", unitPrice: Money(dollars: 60), addedAt: Date(), addedBy: "s")])), staffId: "s")
        #expect(await ea.syncNow().health == .synced)
        #expect(a.journal.pendingCount == 0)

        let s = await eb.syncNow()
        #expect(s.health == .synced)
        #expect(s.lastPulled == 2)
        #expect(b.state.tickets["t1"]?.lines.count == 1)

        // B 在同一張單加點，A 拉回來
        try b.record(.linesAdded(LinesAdded(ticketId: "t1", lines: [TicketLine(id: "l2", itemId: "j", name: "紅茶", unitPrice: Money(dollars: 30), addedAt: Date(), addedBy: "s")])), staffId: "s")
        await eb.syncNow()
        await ea.syncNow()
        #expect(a.state.tickets["t1"]?.lines.map(\.id) == ["l1", "l2"])
        #expect(a.state.tickets == b.state.tickets)
    }

    @Test func offlineQueuesThenCatchesUp() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeServer()
        let a = try makeLedger(dir, "A")
        let engine = SyncEngine(api: server, ledger: a)
        await server.setOffline(true)
        for i in 1...5 { try a.record(.tableCleaned(TableRef(tableId: "t\(i)")), staffId: nil) }
        let s = await engine.syncNow()
        #expect(s.health == .offline)
        #expect(s.pending == 5)
        await server.setOffline(false)
        let s2 = await engine.syncNow()
        #expect(s2.health == .synced)
        #expect(s2.pending == 0)
        #expect(await server.events.count == 5)
    }

    @Test func chainGapRewinds() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeServer()
        let a = try makeLedger(dir, "A")
        let engine = SyncEngine(api: server, ledger: a)
        for i in 1...3 { try a.record(.tableCleaned(TableRef(tableId: "t\(i)")), staffId: nil) }
        await engine.syncNow()
        // 本機以為送到 3，但後台「掉了」最後一筆：本機再送新的會被說 chain_gap，退回去重送
        await server.dropLast()
        try a.record(.tableCleaned(TableRef(tableId: "t4")), staffId: nil)
        let s = await engine.syncNow()
        #expect(s.health == .synced)
        #expect(await server.events.map(\.seq) == [1, 2, 3, 4])
    }

    @Test func meshEnvelopeAuthentication() throws {
        let key = Crypto.randomBytes(32)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = try EventJournal(directory: dir, deviceId: "A")
        let e = try j.append(.tableCleaned(TableRef(tableId: "t1")), staffId: nil)
        let env = try MeshEnvelope(kind: .events, from: "A", events: [e], key: key)
        #expect(env.isAuthentic(key: key))
        #expect(!env.isAuthentic(key: Crypto.randomBytes(32)))
        var forged = env
        forged.from = "B"
        #expect(!forged.isAuthentic(key: key))
        #expect(!env.isAuthentic(key: key, now: Date().addingTimeInterval(600)))
        let wire = try JSONEncoder().encode(env)
        #expect(try JSONDecoder().decode(MeshEnvelope.self, from: wire).isAuthentic(key: key))
        #expect(MeshEnvelope.seen(in: [e]) == ["A": 1])
        #expect(MeshEnvelope.missing(theirs: ["A": 1], from: [e]).isEmpty)
        #expect(MeshEnvelope.missing(theirs: [:], from: [e]).count == 1)
    }
}

extension FakeServer {
    func dropLast() {
        guard let last = events.popLast() else { return }
        bySeq[last.deviceId]?[last.seq] = nil
    }
}
