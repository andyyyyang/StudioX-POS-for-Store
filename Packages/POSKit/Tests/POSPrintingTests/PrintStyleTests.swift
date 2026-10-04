import Foundation
import Testing
@testable import POSCore
@testable import POSPrinting

/// 單據樣式（開機資料的 printStyle）：照 docs/API.md 讀、讀不懂的用預設值
struct PrintStyleTests {
    static func decode(_ json: String) throws -> PrintStyle {
        try JSONDecoder().decode(PrintStyle.self, from: Data(json.utf8))
    }

    @Test func defaults() throws {
        let s = PrintStyle.standard
        #expect(s.mode == .image && s.font == .sans && s.scale == 1)
        #expect(s.imageURLs.isEmpty)
        for d in PrintDoc.allCases { #expect(!s.docs[d].hasArt && s.docs[d].headerLines.isEmpty) }
        // 空物件、少給的欄位：一樣是預設
        #expect(try Self.decode("{}") == .standard)
        #expect(try Self.decode(#"{"docs": {"bill": {}}}"#) == .standard)
        // 沒有樣式的單據（交班單、退款單）：不疊圖、照全店的大小
        #expect(!s.style(for: nil).hasArt)
        #expect(s.scale(for: nil) == 1)
    }

    /// docs/API.md 的範例
    @Test func contractExample() throws {
        let s = try Self.decode(Self.contractJSON)
        #expect(s.mode == .image && s.font == .sans && s.scale == 1)
        let r = s.docs.receipt
        #expect(r.header == PrintImage(url: "https://…/logo.png", width: 0.6, align: .center))
        #expect(r.footer?.width == 0.45)
        #expect(r.background == PrintBackground(url: "https://…/paper-art.png", fit: .top, lighten: 0.75))
        #expect(r.overlays == [PrintOverlay(url: "https://…/stamp.png", x: 0.72, y: 0.04, width: 0.22, anchor: .top)])
        #expect(r.headerLines == ["黃毛丫頭・夜市滷味"] && r.footerLines == ["謝謝光臨・IG @yellowgirl"])
        #expect(s.scale(for: .kitchen) == 1.3 && s.scale(for: .receipt) == 1)
        #expect(!s.docs.kitchen.hasArt && !s.docs.bill.hasArt && !s.docs.pickup.hasArt)
        #expect(s.imageURLs.count == 4)
    }

    /// docs/API.md 裡的那一段（文件改了、程式沒跟上就會失敗）
    @Test func apiDocMatches() throws {
        let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/API.md").standardized
        guard let text = try? String(contentsOf: doc, encoding: .utf8) else { return }
        guard let section = text.range(of: "### 單據樣式"), let open = text.range(of: "```json\n", range: section.upperBound..<text.endIndex),
              let close = text.range(of: "\n```", range: open.upperBound..<text.endIndex) else {
            Issue.record("docs/API.md 找不到單據樣式的範例")
            return
        }
        let block = String(text[open.upperBound..<close.lowerBound])
        struct Wrapper: Decodable { var printStyle: PrintStyle }
        let w = try JSONDecoder().decode(Wrapper.self, from: Data("{\(block)}".utf8))
        #expect(w.printStyle == (try Self.decode(Self.contractJSON)))
    }

    /// 新版後台多的值、型別不對、範圍外：都不要讓整份讀不進來
    @Test func lenient() throws {
        let s = try Self.decode("""
        {
          "mode": "hologram", "font": 3, "scale": 9,
          "docs": {
            "receipt": {
              "header": { "width": 0.5 },
              "footer": { "url": "  ", "width": 0.5 },
              "background": { "url": "https://x/bg.png", "fit": "mosaic", "lighten": 4 },
              "overlays": [{ "url": "https://x/a.png", "x": -1, "y": 2, "width": 0 }, { "x": 0.2 }, "oops", { "url": "https://x/b.png", "anchor": "middle" }],
              "headerLines": ["一", 2, null, "三"],
              "footerLines": "不是陣列",
              "scale": "big"
            },
            "kitchen": { "scale": 0.1 },
            "bill": "oops",
            "flyer": { "header": { "url": "https://x/flyer.png" } }
          }
        }
        """)
        #expect(s.mode == .image && s.font == .sans && s.scale == 1.6)
        let r = s.docs.receipt
        #expect(r.header == nil && r.footer == nil)
        #expect(r.background == PrintBackground(url: "https://x/bg.png", fit: .top, lighten: 1))
        #expect(r.overlays.count == 2)
        #expect(r.overlays[0] == PrintOverlay(url: "https://x/a.png", x: 0, y: 1, width: 0.02, anchor: .top))
        #expect(r.overlays[1].anchor == .top && r.overlays[1].width == 0.25)
        #expect(r.headerLines == ["一", "三"] && r.footerLines.isEmpty && r.scale == nil)
        #expect(s.docs.kitchen.scale == 0.8)
        #expect(s.docs.bill == DocStyle())
        #expect(!s.imageURLs.contains("https://x/flyer.png"))
        // 根本不是物件
        #expect(try Self.decode(#""text""#) == .standard)
        #expect(try Self.decode("[1, 2]") == .standard)
        #expect(try Self.decode(#"{"mode": "text", "docs": []}"#) == PrintStyle(mode: .text))
    }

    @Test func roundTripOmitsEmpty() throws {
        let s = try Self.decode(Self.contractJSON)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try enc.encode(s), as: UTF8.self)
        #expect(try Self.decode(json) == s)
        #expect(json.contains(#""bill":{}"#))
        #expect(json.contains(#""kitchen":{"scale":1.3}"#))
        #expect(!json.contains("null"))
    }

    /// 每台出單機的設定（auto／raster／big5／utf8）× 後台的 mode
    @Test func printerSettingWins() {
        let image = PrintStyle.standard, text = PrintStyle(mode: .text)
        #expect(PrintMode.resolve(encoding: "auto", style: image) == .image)
        #expect(PrintMode.resolve(encoding: "auto", style: text) == .text)
        #expect(PrintMode.resolve(encoding: "raster", style: text) == .image)
        #expect(PrintMode.resolve(encoding: "big5", style: image) == .text)
        #expect(PrintMode.resolve(encoding: "utf8", style: image) == .text)
        // 不認得（新版 App 的設定）：照後台
        #expect(PrintMode.resolve(encoding: "", style: image) == .image)
    }

    /// 範本標好是哪一種單據（圖片模式照那一種的樣式疊圖）
    @Test func templatesTagTheirDoc() throws {
        let (t0, floor) = PrintSamples.ticket()
        var t = t0
        t.payments = [Payment.cash(id: "p", tendered: Money(dollars: 1000), due: t.totals.amountDue, at: PrintSamples.at, by: "s", shiftId: nil)]
        let sale = SaleRecord(ticket: t, closedOn: "d", shiftId: nil, closedAt: PrintSamples.at, closedBy: "s", staffName: "Leslie", floor: floor)
        #expect(Templates.saleReceipt(sale, store: PrintSamples.store).doc == .receipt)
        #expect(Templates.saleReceipt(sale, store: PrintSamples.store, pickupNumber: "7").doc == .pickup)
        #expect(Templates.bill(t, store: PrintSamples.store, floor: floor).doc == .bill)
        #expect(Templates.kitchenTicket(t, lines: t.lines, station: nil, mode: .new, floor: floor, at: PrintSamples.at).doc == .kitchen)
        #expect(Receipt().doc == nil)
        // 店名、地址、電話的位置（店標畫在上面、headerLines 接在下面）；取餐號碼在店名上面
        let receipt = Templates.saleReceipt(sale, store: PrintSamples.store)
        #expect(receipt.storeHeader == 0..<3)
        #expect(receipt.blocks[0] == .text("晨麥手作", .title))
        let pickup = Templates.saleReceipt(sale, store: PrintSamples.store, pickupNumber: "7")
        #expect(pickup.storeHeader == 3..<6)
        #expect(Templates.bill(t, store: PrintSamples.store, floor: floor).storeHeader == 0..<1)
        #expect(Templates.kitchenTicket(t, lines: t.lines, station: nil, mode: .new, floor: floor, at: PrintSamples.at).storeHeader == nil)
    }

    static let contractJSON = """
    {
      "mode": "image",
      "font": "sans",
      "scale": 1.0,
      "docs": {
        "receipt": {
          "header": { "url": "https://…/logo.png", "width": 0.6, "align": "center" },
          "footer": { "url": "https://…/ig-qr.png", "width": 0.45, "align": "center" },
          "background": { "url": "https://…/paper-art.png", "fit": "top", "lighten": 0.75 },
          "overlays": [{ "url": "https://…/stamp.png", "x": 0.72, "y": 0.04, "width": 0.22, "anchor": "top" }],
          "headerLines": ["黃毛丫頭・夜市滷味"],
          "footerLines": ["謝謝光臨・IG @yellowgirl"]
        },
        "kitchen": { "scale": 1.3 },
        "bill": {},
        "pickup": {}
      }
    }
    """
}
