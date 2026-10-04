import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice
@testable import POSPrinting

/// 出單機實際收到的位元組（58／80 mm 各一份），給虛擬出單機（tools/escpos-emulator）畫成圖片看樣子：
///
///   POSKIT_WRITE_PRINTS=<資料夾> swift test --filter PrintSamples
///   python3 tools/escpos-emulator/escpos_emulator.py render <資料夾>/receipt-58.bin --paper 58 --encoding utf-8
///
/// 沒設環境變數時只檢查每一份都是完整的一張（開頭 ESC @、最後切紙）。
struct PrintSamples {
    static let at = Date(timeIntervalSince1970: 1_791_000_000)

    static func ticket() -> (Ticket, FloorPlan) {
        var t = Ticket(id: "t", number: "A007", deviceId: "d", orderType: .dineIn, tableIds: ["a2"], guests: 4, serviceChargeBps: 1000,
                       openedAt: at, openedBy: "s", businessDate: "2026-10-04")
        t.lines = [
            TicketLine(id: "l1", itemId: "i1", name: "珍珠奶茶", unitPrice: Money(dollars: 60),
                       modifiers: [AppliedModifier(groupId: "g", groupName: "甜度", optionId: "o", name: "半糖"),
                                   AppliedModifier(groupId: "g2", groupName: "冰塊", optionId: "o2", name: "少冰")],
                       quantity: 2, note: "一杯不要珍珠", addedAt: at, addedBy: "s"),
            TicketLine(id: "l2", itemId: "i2", name: "炙燒起司牛肉帕尼尼（附薯條）", unitPrice: Money(dollars: 220), modifiers: [], quantity: 1,
                       note: "", addedAt: at, addedBy: "s"),
            TicketLine(id: "l3", itemId: "i3", name: "Latte 拿鐵", unitPrice: Money(dollars: 120), modifiers: [], quantity: 1, note: "",
                       addedAt: at, addedBy: "s"),
        ]
        t.discount = .amount(Money(dollars: 20), reason: "熟客")
        let floor = FloorPlan(areas: [FloorArea(id: "f", name: "1F", tables: [DiningTable(id: "a2", areaId: "f", name: "A2")])])
        return (t, floor)
    }

    static let store = StoreProfile(name: "晨麥手作", address: "台南市中西區民族路二段1號", phone: "06-2220000", serviceChargeBps: 1000)

    static func samples() throws -> [(String, PaperWidth, [UInt8])] {
        let (t0, floor) = ticket()
        var t = t0
        t.payments = [Payment.cash(id: "p", tendered: Money(dollars: 1000), due: t.totals.amountDue, at: at, by: "s", shiftId: nil)]
        let sale = SaleRecord(ticket: t, closedOn: "d", shiftId: nil, closedAt: at, closedBy: "s", staffName: "Leslie", floor: floor)

        let settings = InvoiceSettings(enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", qrKey: "0123456789ABCDEF0123456789ABCDEF",
                                       rolls: [InvoiceRoll(id: "r1", period: "11510", track: "AB", start: 12345650, end: 12345699)])
        let inv = try InvoiceBuilder.issue(ticket: t, settings: settings, allocator: InvoiceAllocator(rolls: settings.rolls, used: []),
                                           deviceId: "d", at: at, randomCode: "1234")
        let proof = InvoiceProof(invoice: inv, storeName: store.name, qrKey: settings.qrKey)

        var out: [(String, PaperWidth, [UInt8])] = []
        for w in PaperWidth.allCases {
            let mm = w == .mm58 ? "58" : "80"
            out.append(("receipt-\(mm)", w, ReceiptRenderer.escpos(Templates.saleReceipt(sale, store: store), width: w)))
            out.append(("pickup-\(mm)", w, ReceiptRenderer.escpos(Templates.saleReceipt(sale, store: store, pickupNumber: "007"), width: w)))
            out.append(("kitchen-new-\(mm)", w, ReceiptRenderer.escpos(Templates.kitchenTicket(t, lines: t.lines, station: "吧台", mode: .new, floor: floor, at: at), width: w)))
            out.append(("kitchen-add-\(mm)", w, ReceiptRenderer.escpos(Templates.kitchenTicket(t, lines: [t.lines[1]], station: nil, mode: .add, floor: floor, at: at), width: w)))
            out.append(("bill-\(mm)", w, ReceiptRenderer.escpos(Templates.bill(t, store: store, floor: floor), width: w)))
            out.append(("queue-text-\(mm)", w, ReceiptRenderer.escpos(
                Templates.queueTicket(number: 128, waiting: 7, storeName: "黃毛丫頭", at: at, link: "https://cms.example.tw/q?no=128&waiting=7", paper: w), width: w)))
            out.append(("invoice-fallback-\(mm)", w, ReceiptRenderer.escpos(Templates.invoiceProofFallback(proof), width: w)))
            // 點陣圖（GS v 0）：外框、對角線、中間一塊黑（號碼牌、證明聯在 iPad 上就是畫成這種點陣圖送出去）
            var e = ESCPOS()
            e.initialize()
            e.align(.center)
            e.raster(testPattern(width: w.dots, height: 200))
            e.feed(1)
            e.cut()
            out.append(("raster-\(mm)", w, e.bytes))
        }
        return out
    }

    static func testPattern(width: Int, height: Int) -> Bitmap {
        var b = Bitmap(width: width, height: height)
        for x in 0..<width { b[x, 0] = true; b[x, 1] = true; b[x, height - 1] = true; b[x, height - 2] = true }
        for y in 0..<height { b[0, y] = true; b[1, y] = true; b[width - 1, y] = true; b[width - 2, y] = true }
        for k in 0..<min(width, height) { b[k * width / height, k] = true; b[width - 1 - k * width / height, k] = true }
        for y in (height / 2 - 30)..<(height / 2 + 30) { for x in (width / 2 - 60)..<(width / 2 + 60) { b[x, y] = true } }
        return b
    }

    @Test func everySampleIsACompleteSlip() throws {
        let list = try Self.samples()
        #expect(list.count == 16)
        for (name, _, bytes) in list {
            #expect(Array(bytes.prefix(2)) == [0x1B, 0x40], "\(name) 開頭要 ESC @")
            #expect(bytes.suffix(4).contains(0x56), "\(name) 最後要切紙")
        }
        if let dir = ProcessInfo.processInfo.environment["POSKIT_WRITE_PRINTS"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, _, bytes) in list { try Data(bytes).write(to: url.appendingPathComponent("\(name).bin")) }
        }
    }
}
