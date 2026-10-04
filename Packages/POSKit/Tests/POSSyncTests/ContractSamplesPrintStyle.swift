import Foundation
import Testing
@testable import POSCore
@testable import POSPrinting
@testable import POSSync

/// 單據樣式的範例（docs/samples/print-style.json）與開機資料：
/// `POSKIT_WRITE_SAMPLES=1 swift test --filter ContractSamples` 和其他範例一起重新產生
struct ContractSamplesPrintStyle {
    /// 和 docs/API.md 的範例一樣的樣式（網址換成看起來像真的）
    static let sample = PrintStyle(
        mode: .image, font: .sans, scale: 1,
        docs: PrintDocs(
            receipt: DocStyle(
                header: PrintImage(url: "https://cms.example.tw/uploads/print/logo.png", width: 0.6, align: .center),
                footer: PrintImage(url: "https://cms.example.tw/uploads/print/ig-qr.png", width: 0.45, align: .center),
                background: PrintBackground(url: "https://cms.example.tw/uploads/print/paper-art.png", fit: .top, lighten: 0.75),
                overlays: [PrintOverlay(url: "https://cms.example.tw/uploads/print/stamp.png", x: 0.72, y: 0.04, width: 0.22, anchor: .top)],
                headerLines: ["黃毛丫頭・夜市滷味"],
                footerLines: ["謝謝光臨・IG @yellowgirl"]
            ),
            kitchen: DocStyle(scale: 1.3)
        )
    )

    static func json() throws -> String {
        let enc = EventCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try enc.encode(sample), as: UTF8.self)
    }

    @Test func sampleRoundTrips() throws {
        let body = try Self.json()
        #expect(try EventCoding.decoder().decode(PrintStyle.self, from: Data(body.utf8)) == Self.sample)
        if ProcessInfo.processInfo.environment["POSKIT_WRITE_SAMPLES"] == "1" {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/samples").standardized
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: dir.appendingPathComponent("print-style.json"), atomically: true, encoding: .utf8)
        }
    }

    /// 開機資料：沒給 printStyle＝nil（App 用預設）；有給讀得回來；壞掉的不會讓整份開機資料讀不進來
    @Test func bootstrapCarriesPrintStyle() throws {
        let dec = EventCoding.decoder()
        let base = try ContractSamples.samples()["bootstrap.json"]!
        let plain = try dec.decode(Bootstrap.self, from: Data(base.utf8))
        #expect(plain.printStyle == nil)

        var styled = plain
        styled.printStyle = Self.sample
        let enc = EventCoding.encoder()
        let again = try dec.decode(Bootstrap.self, from: try enc.encode(styled))
        #expect(again.printStyle == Self.sample)

        for broken in [#""printStyle": "fancy""#, #""printStyle": {"mode": 3, "docs": {"receipt": {"overlays": 7}}}"#, #""printStyle": null"#] {
            let json = base.replacingOccurrences(of: #""version" :"#, with: broken + #", "version" :"#)
            #expect(json != base)
            let b = try dec.decode(Bootstrap.self, from: Data(json.utf8))
            #expect(b.version == plain.version)
            #expect((b.printStyle ?? .standard) == .standard)
        }
    }
}
