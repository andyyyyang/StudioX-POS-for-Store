import Foundation

/// ESC/POS 指令（Epson、Star 的 ESC/POS 模式、台灣常見的 58／80 mm 熱感出單機都通）。
/// 只產生位元組；怎麼送（網路 9100 埠、藍牙）在 App 的 PrinterTransport。
public struct ESCPOS: Sendable {
    public private(set) var bytes: [UInt8] = []
    /// 文字轉成出單機的編碼（台灣的機器多半是 Big5；新機型可以 UTF-8）。App 在 iPad 上用 Big5，測試用 UTF-8
    public var encode: @Sendable (String) -> [UInt8]

    public init(encode: @escaping @Sendable (String) -> [UInt8] = { Array($0.utf8) }) {
        self.encode = encode
    }

    public enum Align: UInt8, Sendable { case left = 0, center = 1, right = 2 }

    public mutating func raw(_ b: [UInt8]) { bytes += b }

    /// ESC @：清掉格式
    public mutating func initialize() { raw([0x1B, 0x40]) }
    /// ESC a n
    public mutating func align(_ a: Align) { raw([0x1B, 0x61, a.rawValue]) }
    /// ESC E n
    public mutating func bold(_ on: Bool) { raw([0x1B, 0x45, on ? 1 : 0]) }
    /// GS ! n：寬、高倍數（1–8）
    public mutating func size(width: Int = 1, height: Int = 1) {
        let w = UInt8(min(max(width, 1), 8) - 1), h = UInt8(min(max(height, 1), 8) - 1)
        raw([0x1D, 0x21, (w << 4) | h])
    }
    /// GS B n：反白
    public mutating func invert(_ on: Bool) { raw([0x1D, 0x42, on ? 1 : 0]) }
    /// ESC - n：底線
    public mutating func underline(_ on: Bool) { raw([0x1B, 0x2D, on ? 1 : 0]) }

    public mutating func text(_ s: String) { raw(encode(s)) }
    public mutating func line(_ s: String = "") { raw(encode(s) + [0x0A]) }
    /// ESC d n：走紙 n 行
    public mutating func feed(_ lines: Int = 1) { raw([0x1B, 0x64, UInt8(min(max(lines, 0), 255))]) }

    /// GS V 66 n：走紙後切紙（部分切）
    public mutating func cut(feed: Int = 3) { raw([0x1D, 0x56, 66, UInt8(min(max(feed, 0), 255))]) }

    /// ESC p m t1 t2：開錢櫃（接在出單機 RJ11 上的錢櫃）
    public mutating func openDrawer(pin: UInt8 = 0) { raw([0x1B, 0x70, pin, 25, 250]) }

    /// 嗶一聲（廚房出單提醒；ESC ( A 不是每台都支援，用 BEL 相容性較高）
    public mutating func beep() { raw([0x07]) }

    /// GS k m=69（Code 39，給長度）＋ HRI 不印（證明聯上號碼另外印）
    public mutating func code39(_ data: String, height: Int = 64, moduleWidth: Int = 1) {
        let d = Array(data.uppercased().utf8)
        raw([0x1D, 0x68, UInt8(min(max(height, 1), 255))])      // GS h 高度
        raw([0x1D, 0x77, UInt8(min(max(moduleWidth, 1), 6))])  // GS w 窄條寬
        raw([0x1D, 0x48, 0])                                    // GS H 不印字
        raw([0x1D, 0x6B, 69, UInt8(d.count)] + d)
    }

    /// GS ( k：QR Code（model 2、容錯 L、每格 size 點）
    public mutating func qr(_ data: String, moduleSize: Int = 4, errorCorrection: UInt8 = 48) {
        let d = Array(data.utf8)
        let len = d.count + 3
        raw([0x1D, 0x28, 0x6B, 4, 0, 0x31, 0x41, 0x32, 0x00])                    // model 2
        raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x43, UInt8(min(max(moduleSize, 1), 16))])  // 大小
        raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x45, errorCorrection])                 // 容錯 L=48
        raw([0x1D, 0x28, 0x6B, UInt8(len & 0xFF), UInt8(len >> 8), 0x31, 0x50, 0x30] + d)  // 存資料
        raw([0x1D, 0x28, 0x6B, 3, 0, 0x31, 0x51, 0x30])                    // 印
    }

    /// GS v 0：點陣圖。一次送太多列有些機型會亂掉，分段送（每段最多 256 列）
    public mutating func raster(_ image: Bitmap, chunkRows: Int = 256) {
        let rb = image.rowBytes
        var y = 0
        while y < image.height {
            let h = min(chunkRows, image.height - y)
            raw([0x1D, 0x76, 0x30, 0, UInt8(rb & 0xFF), UInt8(rb >> 8), UInt8(h & 0xFF), UInt8(h >> 8)])
            raw(Array(image.bytes[(y * rb)..<((y + h) * rb)]))
            y += h
        }
    }
}
