import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice
@testable import POSSync

/// 文件與後台用的範例 JSON（docs/samples/）。POSKIT_WRITE_SAMPLES=1 swift test --filter ContractSamples 重新產生；
/// 平常跑測試只檢查「產生得出來、解得回去」
struct ContractSamples {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func sampleTicket() -> Ticket {
        var t = Ticket(id: "6f1c2a9e-0b7d-4c1e-9a55-2f3b8d1e7c40", number: "A023", deviceId: "dev-a", orderType: .dineIn, tableIds: ["tbl-a1"],
                       guests: 2, serviceChargeBps: 1000, openedAt: at, openedBy: "staff-leslie", businessDate: "2026-09-21")
        t.lines = [
            TicketLine(id: "ln-1", itemId: "itm-milktea", name: "珍珠奶茶", categoryId: "cat-drinks", categoryName: "飲料", unitPrice: Money(dollars: 60),
                       modifiers: [AppliedModifier(groupId: "grp-sugar", groupName: "甜度", optionId: "opt-half", name: "半糖"),
                                   AppliedModifier(groupId: "grp-ice", groupName: "冰塊", optionId: "opt-less", name: "少冰")],
                       quantity: 2, station: "吧台", addedAt: at, addedBy: "staff-leslie", sentAt: at, kitchen: .sent),
            TicketLine(id: "ln-2", itemId: "itm-chicken", name: "鹽酥雞", categoryId: "cat-fried", categoryName: "炸物", unitPrice: Money(dollars: 80),
                       quantity: 1, station: "廚房", addedAt: at, addedBy: "staff-leslie", sentAt: at, kitchen: .served),
        ]
        t.invoiceBuyer = .business(taxId: "22099131", title: "台灣積體電路製造股份有限公司")
        return t
    }

    static func samples() throws -> [String: String] {
        let enc = EventCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        func j<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }

        var t = sampleTicket()
        let settings = InvoiceSettings(enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", sellerAddress: "台南市中西區民族路二段1號",
                                       qrKey: "0123456789ABCDEF0123456789ABCDEF",
                                       rolls: [InvoiceRoll(id: "roll-1", period: "11510", track: "AB", start: 12345650, end: 12345699)])
        let alloc = InvoiceAllocator(rolls: settings.rolls, used: [])
        let invoice = try InvoiceBuilder.issue(ticket: t, settings: settings, allocator: alloc, deviceId: "dev-a", at: at, randomCode: "4821")
        t.invoice = invoice.stamp
        t.payments = [Payment.cash(id: "pay-1", tendered: Money(dollars: 300), due: t.totals.amountDue, at: at, by: "staff-leslie", shiftId: "shift-1")]
        let sale = SaleRecord(ticket: t, closedOn: "dev-a", shiftId: "shift-1", closedAt: at, closedBy: "staff-leslie", staffName: "Leslie", floor: FloorPlan())

        let e1 = try POSEvent(id: "evt-0001", deviceId: "dev-a", seq: 41, lamport: 1207, at: at, staffId: "staff-leslie",
                              body: .linesAdded(LinesAdded(ticketId: t.id, lines: t.lines)), prevHash: String(repeating: "a", count: 64))
        let e2 = try POSEvent(id: "evt-0002", deviceId: "dev-a", seq: 42, lamport: 1208, at: at, staffId: "staff-leslie",
                              body: .invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: invoice)), prevHash: e1.hash)
        let e3 = try POSEvent(id: "evt-0003", deviceId: "dev-a", seq: 43, lamport: 1209, at: at, staffId: "staff-leslie",
                              body: .ticketClosed(TicketClosed(ticketId: t.id, sale: sale)), prevHash: e2.hash)

        let bootstrap = Bootstrap(
            version: "v-3f9a1c", serverTime: at,
            device: DeviceProfile(id: "dev-a", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(name: "晨麥手作", legalName: "晨麥手作有限公司", taxId: "04595257", address: "台南市中西區民族路二段1號", phone: "06-2220000",
                                serviceChargeBps: 1000, tableTimeLimitMinutes: 90),
            features: .all,
            catalog: Catalog(
                categories: [MenuCategory(id: "cat-drinks", name: "飲料", swatch: .lavender, sortOrder: 1, station: "吧台")],
                items: [MenuItem(id: "itm-milktea", categoryId: "cat-drinks", name: "珍珠奶茶", shortName: "珍奶", price: Money(dollars: 60),
                                 plu: "101", modifierGroupIds: ["grp-sugar"], unit: "杯")],
                modifierGroups: [ModifierGroup(id: "grp-sugar", name: "甜度", minSelect: 1, maxSelect: 1, options: [
                    ModifierOption(id: "opt-full", name: "正常", isDefault: true), ModifierOption(id: "opt-half", name: "半糖"),
                ])]
            ),
            floor: FloorPlan(areas: [FloorArea(id: "area-1f", name: "1F", tables: [DiningTable(id: "tbl-a1", areaId: "area-1f", name: "A1", seats: 4, x: 10, y: 10)])]),
            staff: [StaffMember(id: "staff-leslie", name: "Leslie", role: .cashier, pinHash: Staff.hash(pin: "1234", salt: "8c1f0e5a"), pinSalt: "8c1f0e5a", swatch: .lavender)],
            invoice: settings,
            mesh: MeshConfig(key: String(repeating: "ab", count: 32), enabled: true)
        )

        return [
            "event-lines-added.json": try j(e1),
            "event-invoice-issued.json": try j(e2),
            "event-ticket-closed.json": try j(e3),
            "bootstrap.json": try j(bootstrap),
            "events-push-result.json": try j(EventsPushResult(accepted: ["evt-0001", "evt-0002"], duplicates: [], rejected: [EventRejection(id: "evt-0003", reason: "chain_gap", expectSeq: 42)], serverSeq: 98113)),
            "pair-response.json": try j(PairResponse(deviceId: "dev-a", token: "sxpos_dev-a.9Jq…", deviceCode: "A", role: .register, storeName: "晨麥手作")),
            "reservation.json": try j(Reservation(id: "rsv-1", kind: .reservation, name: "王小明", phone: "0912345678", partySize: 4, startsAt: at, tableIds: ["tbl-a1"], note: "靠窗", createdAt: at)),
            "invoice-qr.txt": {
                let p = InvoiceProof(invoice: invoice, storeName: "晨麥手作", qrKey: settings.qrKey)
                return "barcode: \(p.barcode)\nleft:  \(p.qrLeft ?? "")\nright: \(p.qrRight ?? "")\n"
            }(),
        ]
    }

    @Test func samplesRoundTrip() throws {
        let s = try Self.samples()
        let dec = EventCoding.decoder()
        for name in ["event-lines-added.json", "event-invoice-issued.json", "event-ticket-closed.json"] {
            let e = try dec.decode(POSEvent.self, from: Data(s[name]!.utf8))
            #expect(e.isHashValid, "\(name)")
        }
        _ = try dec.decode(Bootstrap.self, from: Data(s["bootstrap.json"]!.utf8))
        if ProcessInfo.processInfo.environment["POSKIT_WRITE_SAMPLES"] == "1" {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/samples").standardized
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in s { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
    }
}
