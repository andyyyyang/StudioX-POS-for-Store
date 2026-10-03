import Foundation

/// 1-bit 點陣圖（出單機的「點」：true＝印黑）。證明聯（兩個 QR Code 並排）、Logo、用品牌字型排的收據都先畫成點陣圖再送出去。
public struct Bitmap: Sendable, Hashable {
    public let width: Int
    public let height: Int
    /// 一列一列、每列 ceil(width/8) bytes、高位元在左
    public private(set) var bytes: [UInt8]

    public var rowBytes: Int { (width + 7) / 8 }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: ((width + 7) / 8) * height)
    }

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return bytes[y * rowBytes + x / 8] & (0x80 >> UInt8(x % 8)) != 0
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let i = y * rowBytes + x / 8
            let mask: UInt8 = 0x80 >> UInt8(x % 8)
            if newValue { bytes[i] |= mask } else { bytes[i] &= ~mask }
        }
    }

    /// 灰階（0＝黑、255＝白，一列一列）轉黑白。dither：Floyd–Steinberg（照片、Logo）；不 dither：門檻（文字、條碼要銳利）
    public init(gray: [UInt8], width: Int, height: Int, threshold: UInt8 = 128, dither: Bool = false) {
        self.init(width: width, height: height)
        guard gray.count >= width * height else { return }
        if !dither {
            for y in 0..<height { for x in 0..<width where gray[y * width + x] < threshold { self[x, y] = true } }
            return
        }
        var buf = gray.map { Int($0) }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let old = buf[i]
                let new = old < Int(threshold) ? 0 : 255
                if new == 0 { self[x, y] = true }
                let err = old - new
                if x + 1 < width { buf[i + 1] += err * 7 / 16 }
                if y + 1 < height {
                    if x > 0 { buf[i + width - 1] += err * 3 / 16 }
                    buf[i + width] += err * 5 / 16
                    if x + 1 < width { buf[i + width + 1] += err / 16 }
                }
            }
        }
    }

    /// 把另一張貼上來（左上角在 x, y）
    public mutating func draw(_ other: Bitmap, x: Int, y: Int) {
        for oy in 0..<other.height {
            for ox in 0..<other.width where other[ox, oy] { self[x + ox, y + oy] = true }
        }
    }

    public mutating func fill(x: Int, y: Int, width w: Int, height h: Int) {
        for yy in y..<(y + h) { for xx in x..<(x + w) { self[xx, yy] = true } }
    }

    /// 放大（QR Code 的一格變成 scale×scale 個點）
    public func scaled(_ scale: Int) -> Bitmap {
        guard scale > 1 else { return self }
        var out = Bitmap(width: width * scale, height: height * scale)
        for y in 0..<height { for x in 0..<width where self[x, y] { out.fill(x: x * scale, y: y * scale, width: scale, height: scale) } }
        return out
    }

    /// 由黑白矩陣建（QR Code 的模組）
    public init(modules: [[Bool]]) {
        let h = modules.count, w = modules.first?.count ?? 0
        self.init(width: w, height: h)
        for y in 0..<h { for x in 0..<w where modules[y][x] { self[x, y] = true } }
    }

    /// Code 39 一維條碼（窄條 narrow 個點、高 height 個點）
    public static func barcode(bars: [Bool], height: Int) -> Bitmap {
        var b = Bitmap(width: bars.count, height: height)
        for (x, black) in bars.enumerated() where black { b.fill(x: x, y: 0, width: 1, height: height) }
        return b
    }

    /// 印黑的點數占多少（測試、預估耗紙）
    public var inkRatio: Double {
        var on = 0
        for y in 0..<height { for x in 0..<width where self[x, y] { on += 1 } }
        return width * height > 0 ? Double(on) / Double(width * height) : 0
    }
}
