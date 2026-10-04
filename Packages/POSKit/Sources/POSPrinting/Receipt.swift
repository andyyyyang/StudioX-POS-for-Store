import Foundation

/// 一張單據（收據、廚房單、交班單…）的內容，和出單機無關。
/// ESC/POS 的文字模式用 `ReceiptRenderer.escpos`；App 也可以把同一份內容畫成點陣圖（品牌字型）或在畫面上預覽。
public struct ReceiptStyle: Sendable, Hashable {
    public var align: ESCPOS.Align
    public var bold: Bool
    /// 字放大（1＝一般、2＝兩倍寬高）
    public var scale: Int
    public var invert: Bool

    public init(align: ESCPOS.Align = .left, bold: Bool = false, scale: Int = 1, invert: Bool = false) {
        self.align = align; self.bold = bold; self.scale = scale; self.invert = invert
    }

    public static let body = ReceiptStyle()
    public static let center = ReceiptStyle(align: .center)
    public static let title = ReceiptStyle(align: .center, bold: true, scale: 2)
    public static let strong = ReceiptStyle(bold: true)
    public static let big = ReceiptStyle(bold: true, scale: 2)
}

public enum ReceiptBlock: Sendable, Hashable {
    case text(String, ReceiptStyle)
    /// 左邊說明、右邊金額
    case row(String, String, ReceiptStyle)
    /// 縮排的小字（加料、備註）
    case detail(String)
    case rule
    case doubleRule
    case feed(Int)
    case barcode39(String)
    case qr(String)
    case image(Bitmap)
    case drawer
    case beep
    case cut
}

public struct Receipt: Sendable, Hashable {
    public var blocks: [ReceiptBlock]
    public init(_ blocks: [ReceiptBlock] = []) { self.blocks = blocks }

    public mutating func add(_ b: ReceiptBlock) { blocks.append(b) }
    public mutating func add(_ bs: [ReceiptBlock]) { blocks += bs }

    /// 純文字（預覽、測試、沒有出單機時存成文字檔）
    public func plainText(width: PaperWidth) -> String {
        var lines: [String] = []
        let w = width.columns
        for b in blocks {
            switch b {
            case .text(let s, let st):
                let cols = max(w / max(st.scale, 1), 1)
                for l in TextWidth.wrap(s, width: cols) {
                    switch st.align {
                    case .left: lines.append(l)
                    case .center: lines.append(String(repeating: " ", count: max((cols - TextWidth.of(l)) / 2, 0)) + l)
                    case .right: lines.append(TextWidth.pad(l, to: cols, alignRight: true))
                    }
                }
            case .row(let l, let r, let st): lines += TextWidth.row(l, r, width: max(w / max(st.scale, 1), 1))
            case .detail(let s): lines += TextWidth.wrap(s, width: w - 2).map { "  " + $0 }
            case .rule: lines.append(String(repeating: "-", count: w))
            case .doubleRule: lines.append(String(repeating: "=", count: w))
            case .feed(let n): lines += [String](repeating: "", count: n)
            case .barcode39(let s): lines.append("[條碼 \(s)]")
            case .qr(let s): lines.append("[QR \(s.prefix(24))…]")
            case .image(let img): lines.append("[圖 \(img.width)×\(img.height)]")
            case .drawer, .beep, .cut: break
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ReceiptRenderer {
    /// 文字模式的 ESC/POS（快、省電；中文要出單機支援 Big5 或 UTF-8）
    public static func escpos(_ r: Receipt, width: PaperWidth, encode: @escaping @Sendable (String) -> [UInt8] = { Array($0.utf8) }) -> [UInt8] {
        var p = ESCPOS(encode: encode)
        p.initialize()
        let w = width.columns
        for b in r.blocks {
            switch b {
            case .text(let s, let st):
                apply(&p, st)
                for l in TextWidth.wrap(PrintText.printable(s), width: max(w / max(st.scale, 1), 1)) { p.line(l) }
                reset(&p)
            case .row(let l, let r, let st):
                apply(&p, ReceiptStyle(align: .left, bold: st.bold, scale: st.scale, invert: st.invert))
                for line in TextWidth.row(PrintText.printable(l), PrintText.printable(r), width: max(w / max(st.scale, 1), 1)) { p.line(line) }
                reset(&p)
            case .detail(let s):
                for l in TextWidth.wrap(PrintText.printable(s), width: w - 2) { p.line("  " + l) }
            case .rule: p.line(String(repeating: "-", count: w))
            case .doubleRule: p.line(String(repeating: "=", count: w))
            case .feed(let n): p.feed(n)
            case .barcode39(let s):
                p.align(.center); p.code39(s); p.line(); p.align(.left)
            case .qr(let s):
                p.align(.center); p.qr(s); p.line(); p.align(.left)
            case .image(let img):
                p.align(.center); p.raster(img); p.align(.left)
            case .drawer: p.openDrawer()
            case .beep: p.beep()
            case .cut: p.cut()
            }
        }
        return p.bytes
    }

    private static func apply(_ p: inout ESCPOS, _ st: ReceiptStyle) {
        p.align(st.align)
        if st.bold { p.bold(true) }
        if st.scale > 1 { p.size(width: st.scale, height: st.scale) }
        if st.invert { p.invert(true) }
    }

    private static func reset(_ p: inout ESCPOS) {
        p.align(.left); p.bold(false); p.size(); p.invert(false)
    }
}
