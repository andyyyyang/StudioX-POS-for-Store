import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice
@testable import POSPrinting

struct PrintingTests {
    @Test func cjkWidth() {
        #expect(TextWidth.of("ABC") == 3)
        #expect(TextWidth.of("珍珠奶茶") == 8)
        #expect(TextWidth.of("（半糖）") == 8)
        // 「…」在出單機上也佔 2 格
        #expect(TextWidth.truncate("珍珠奶茶大杯", to: 7) == "珍珠…")
        #expect(TextWidth.of("拿鐵 ×2") == 8)  // × 是全形（Big5 雙位元組）
        #expect(TextWidth.of("Latte") == 5)
        // Big5 沒有的字換掉、表情符號拿掉
        #expect(PrintText.printable("折扣 −20・半糖🔥") == "折扣 -20·半糖")
        #expect(PrintText.printable("☕️ 拿鐵") == " 拿鐵")
        #expect(TextWidth.wrap("珍珠奶茶大杯", width: 4) == ["珍珠", "奶茶", "大杯"])
        let row = TextWidth.row("雞排", "80", width: 10)
        #expect(row == ["雞排    80"])
        let long = TextWidth.row("非常非常長的品項名稱", "1,280", width: 16)
        #expect(long.count == 2)
        #expect(TextWidth.of(long[1]) == 16)
        #expect(long[1].hasSuffix("1,280"))
    }

    @Test func escposBasics() {
        var p = ESCPOS()
        p.initialize(); p.align(.center); p.bold(true); p.size(width: 2, height: 2); p.line("Hi"); p.cut(); p.openDrawer()
        #expect(p.bytes == [0x1B, 0x40, 0x1B, 0x61, 1, 0x1B, 0x45, 1, 0x1D, 0x21, 0x11, 0x48, 0x69, 0x0A, 0x1D, 0x56, 66, 3, 0x1B, 0x70, 0, 25, 250])
        var q = ESCPOS()
        q.qr("AB")
        // model（9 bytes）、大小（8）、容錯（8）之後是存資料：pL = 長度＋3
        let store = q.bytes[25...]
        #expect(Array(store.prefix(8)) == [0x1D, 0x28, 0x6B, 5, 0, 0x31, 0x50, 0x30])
    }

    @Test func rasterEncoding() {
        var b = Bitmap(width: 10, height: 2)
        b[0, 0] = true; b[9, 0] = true; b[8, 1] = true
        #expect(b.rowBytes == 2)
        #expect(b.bytes == [0x80, 0x40, 0x00, 0x80])
        var p = ESCPOS()
        p.raster(b)
        #expect(Array(p.bytes.prefix(8)) == [0x1D, 0x76, 0x30, 0, 2, 0, 2, 0])
        #expect(p.bytes.count == 8 + 4)
        let big = Bitmap(width: 8, height: 300)
        var p2 = ESCPOS()
        p2.raster(big, chunkRows: 256)
        #expect(p2.bytes.count == (8 + 256) + (8 + 44))
        #expect(b.scaled(3).width == 30)
    }

    @Test func dither() {
        let gray = [UInt8](repeating: 128, count: 100)
        let half = Bitmap(gray: gray, width: 10, height: 10, dither: true)
        #expect(half.inkRatio > 0.3 && half.inkRatio < 0.7)
        let solid = Bitmap(gray: [UInt8](repeating: 0, count: 16), width: 4, height: 4)
        #expect(solid.inkRatio == 1)
    }

    @Test func receiptsLookRight() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        var t = Ticket(id: "t", number: "A007", deviceId: "d", orderType: .dineIn, tableIds: ["a1"], guests: 2, serviceChargeBps: 1000, openedAt: at, openedBy: "s", businessDate: "2026-10-03")
        t.lines = [TicketLine(id: "l", itemId: "i", name: "珍珠奶茶", unitPrice: Money(dollars: 60),
                              modifiers: [AppliedModifier(groupId: "g", groupName: "甜度", optionId: "o", name: "半糖")], quantity: 2, note: "去冰", addedAt: at, addedBy: "s")]
        t.payments = [Payment.cash(id: "p", tendered: Money(dollars: 200), due: Money(dollars: 132), at: at, by: "s", shiftId: nil)]
        let floor = FloorPlan(areas: [FloorArea(id: "f", name: "1F", tables: [DiningTable(id: "a1", areaId: "f", name: "A1")])])
        let sale = SaleRecord(ticket: t, closedOn: "d", shiftId: nil, closedAt: at, closedBy: "s", staffName: "Leslie", floor: floor)
        let store = StoreProfile(name: "晨麥手作", address: "台南市中西區民族路二段1號", phone: "06-2220000", serviceChargeBps: 1000)
        let text = Templates.saleReceipt(sale, store: store).plainText(width: .mm58)
        #expect(text.contains("總計"))
        #expect(text.contains("132"))
        #expect(text.contains("找零"))
        #expect(text.contains("68"))
        for line in text.split(separator: "\n") { #expect(TextWidth.of(String(line)) <= 32, "\(line)") }

        let kitchen = Templates.kitchenTicket(t, lines: t.lines, station: "吧台", mode: .add, floor: floor, at: at)
        let kt = kitchen.plainText(width: .mm80)
        #expect(kt.contains("【加點】吧台"))
        #expect(kt.contains("※ 去冰"))
        let bytes = ReceiptRenderer.escpos(kitchen, width: .mm80)
        #expect(bytes.first == 0x1B)
        #expect(bytes.contains(0x07))

        let pickup = Templates.saleReceipt(sale, store: store, pickupNumber: Templates.pickupNumber("A007")).plainText(width: .mm58)
        #expect(pickup.hasPrefix("            取餐號碼") || pickup.contains("取餐號碼"))
        #expect(Templates.pickupNumber("B120") == "120")
        // 58 mm 與 80 mm：每一行都放得進紙寬
        for w in PaperWidth.allCases {
            for line in Templates.saleReceipt(sale, store: store).plainText(width: w).split(separator: "\n") {
                #expect(TextWidth.of(String(line)) <= w.columns, "\(w) \(line)")
            }
        }

        let bill = Templates.bill(t, store: store, floor: floor).plainText(width: .mm80)
        #expect(bill.contains("A1"))
        #expect(bill.contains("服務費 10%"))
    }

    /// 號碼牌的文字版：號碼放到最大，58／80 mm 都放得進紙寬；有網址才印 QR Code
    @Test func queueTicketFitsBothPapers() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        for w in PaperWidth.allCases {
            let r = Templates.queueTicket(number: 1000, waiting: 12, storeName: "黃毛丫頭", at: at, link: "https://shop.tw/q?no=1000&waiting=12", paper: w)
            let text = r.plainText(width: w)
            #expect(text.contains("1000"))
            #expect(text.contains("目前 12 人等候中"))
            #expect(text.contains("[QR https://shop.tw/q?no="))
            for line in text.split(separator: "\n") { #expect(TextWidth.of(String(line)) <= w.columns, "\(w) \(line)") }
            let big = r.blocks.compactMap { b -> Int? in if case .text("1000", let st) = b { st.scale } else { nil } }
            #expect(big == [w == .mm58 ? 4 : 6])
        }
        let plain = Templates.queueTicket(number: 7, waiting: 0, storeName: "晨麥手作", at: at, link: nil, waitingText: "前面還有 0 位")
        #expect(!plain.blocks.contains { if case .qr = $0 { true } else { false } })
        #expect(plain.plainText(width: .mm58).contains("前面還有 0 位"))
        #expect(plain.blocks.last == .cut)
    }
}
