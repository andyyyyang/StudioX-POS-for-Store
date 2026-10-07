import Foundation

/// 錢櫃怎麼開。
///
/// 市面上的收銀錢櫃（台灣常見的 330／405 型、Epson、Star、APG、XPrinter 配的）幾乎都是一條 RJ11／RJ12 的線，
/// 插在出單機背面的 DK 埠（寫 DK、DRAWER 或畫一個錢櫃）：出單機收到指令就從那個埠送一下電，錢櫃彈開。
/// 不同的地方只有三個：
///   - 指令：大部分出單機吃 ESC/POS 的 `ESC p`；Epson TM 另外有即時指令 `DLE DC4`（忙著印、缺紙時也開得了）；
///     Star 在 StarPRNT／Star Line 模式（mPOP 這類）用 `BEL`／`SUB`
///   - 接腳：DK 埠有兩組（2 號腳、5 號腳），錢櫃的線接哪一組看廠牌；大部分是 2 號，不知道就兩個都送
///   - 通電多久：一般 50 ms 就開；彈簧比較緊、線比較長的調長一點
/// 錢櫃自己有網路控制盒（自己的 IP、埠 9100）的也是收 `ESC p`：在 App 裡當成一台「不印東西、錢櫃接在這台」的出單機
public struct DrawerKick: Codable, Hashable, Sendable {
    public enum Command: String, Codable, Sendable, CaseIterable {
        /// ESC p：Epson 與相容機（XPrinter、佳博 Gprinter、HPRT、Sunmi、iMin、Star 的 ESC/POS 模式…）
        case escpos
        /// DLE DC4：Epson TM 的即時指令（出單機忙著印、缺紙、開蓋時也開得了）
        case realtime
        /// Star 的 StarPRNT／Star Line 模式：BEL（2 號腳）、SUB（5 號腳）；通電多久照出單機自己的設定
        case star
    }

    public enum Pin: String, Codable, Sendable, CaseIterable {
        /// 2 號腳（錢櫃 1）：大部分錢櫃
        case pin2
        /// 5 號腳（錢櫃 2）
        case pin5
        /// 不知道接哪一腳：兩個都送（多送的那一個沒接東西，沒有影響）
        case both
    }

    public var command: Command
    public var pin: Pin
    /// 通電多久（毫秒）
    public var pulseMs: Int

    public init(command: Command = .escpos, pin: Pin = .pin2, pulseMs: Int = 50) {
        self.command = command; self.pin = pin; self.pulseMs = pulseMs
    }

    /// 預設：ESC p 0 25 250（2 號腳、通電 50 ms）——Epson 文件與大部分錢櫃的建議值，也是以前一直送的
    public static let standard = DrawerKick()

    /// 設定頁可以選的通電長度
    public static let pulseChoices = [50, 100, 200]

    private var pins: [UInt8] {
        switch pin {
        case .pin2: [0]
        case .pin5: [1]
        case .both: [0, 1]
        }
    }

    /// 要送給出單機的位元組
    public var bytes: [UInt8] {
        switch command {
        case .escpos:
            // ESC p m t1 t2：t1 通電、t2 斷電（各 ×2 ms）；t2 要 ≥ t1
            let t1 = UInt8(min(max(pulseMs / 2, 1), 255))
            let t2 = max(t1, 250)
            return pins.flatMap { [0x1B, 0x70, $0, t1, t2] }
        case .realtime:
            // DLE DC4 1 m t：t ×100 ms（1–8）
            let t = UInt8(min(max((pulseMs + 50) / 100, 1), 8))
            return pins.flatMap { [0x10, 0x14, 0x01, $0, t] }
        case .star:
            // BEL＝錢櫃 1（2 號腳）、SUB＝錢櫃 2（5 號腳）
            return pins.map { $0 == 0 ? 0x07 : 0x1A }
        }
    }
}

extension ESCPOS {
    /// 照這台出單機的錢櫃設定開錢櫃
    public mutating func kick(_ drawer: DrawerKick) { raw(drawer.bytes) }
}
