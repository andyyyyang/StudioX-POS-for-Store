import Foundation

/// 熱感紙只有黑白：照片、插畫用擴散網點（Floyd–Steinberg），字用門檻（150）——字永遠是清楚的黑。
///
/// App（PrintComposer）把一張單據用 SwiftUI 畫三層灰階（底圖、其他的圖、字；ImageRenderer 只能在主執行緒），
/// 疊成黑白在這裡算（純函式、值型別，可以丟到背景）。和後台「單據樣式」設計頁的預覽同一套規則：
///
///   1. 圖那一層：底圖先變淡（lighten：255 − (255 − g)·(1 − lighten)，只有底圖），上面照順序畫店標、頁尾、貼圖（照透明度疊），
///      一起打擴散網點（Floyd–Steinberg、門檻 128，和 Bitmap(gray:dither:) 一模一樣）
///   2. 字那一層：門檻 150
///   3. 任一層是黑就印黑；字旁邊 halo 點以內的網點先挖掉（深色的圖上面的字也看得清楚；後台的預覽沒有這一步）
public enum Halftone {
    /// 變淡：amount 0＝原樣、1＝全白。v' = 255 − (255 − v)·(1 − amount)
    public static func lighten(_ gray: [UInt8], amount: Double) -> [UInt8] {
        let a = amount.isFinite ? min(max(amount, 0), 1) : 0
        guard a > 0 else { return gray }
        let keep = 1 - a
        var table = [UInt8](repeating: 255, count: 256)
        for v in 0..<256 { table[v] = UInt8(clamping: Int((255 - Double(255 - v) * keep).rounded())) }
        return gray.map { table[Int($0)] }
    }

    /// 兩層灰階取比較暗的（沒有透明度時的疊法）
    public static func darkest(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        guard a.count == b.count else { return a.count > b.count ? a : b }
        var out = a
        for i in 0..<out.count where b[i] < out[i] { out[i] = b[i] }
        return out
    }

    /// 把圖照透明度畫在 base 上面。art 是那張圖疊在白底上的灰、alpha 是不透明度（0＝透明、255＝不透明）：
    /// 結果 = a·g + (1 − a)·base = art − (1 − a)·(255 − base)
    public static func over(_ art: [UInt8], alpha: [UInt8], base: [UInt8]) -> [UInt8] {
        guard art.count == alpha.count, art.count == base.count else { return darkest(art, base) }
        var out = art
        for i in 0..<out.count {
            let v = Int(art[i]) - (255 - Int(alpha[i])) * (255 - Int(base[i])) / 255
            out[i] = UInt8(clamping: v)
        }
        return out
    }

    /// Floyd–Steinberg 擴散網點，和 `Bitmap(gray:width:height:threshold:dither: true)` 一模一樣（後台的預覽照這個驗）：
    /// 一列一列由左往右；誤差右 7/16、左下 3/16、下 5/16、右下 1/16（整數除法），擴散到紙外的丟掉；比門檻暗的印黑。
    /// gray：0＝黑、255＝白；回傳 0／1（1＝印黑）。只留兩列的誤差，長單也不佔記憶體
    public static func diffuse(_ gray: [UInt8], width w: Int, height h: Int, threshold: Int = 128) -> [UInt8] {
        guard w > 0, h > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: w * h)
        guard gray.count >= w * h else { return out }
        // 這一列、下一列的誤差；左右各多一格（index＝x＋1），擴散到紙外的寫在多的那一格、不會再讀
        var cur = [Int](repeating: 0, count: w + 2)
        var next = [Int](repeating: 0, count: w + 2)
        gray.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    cur.withUnsafeMutableBufferPointer { c in
                        next.withUnsafeMutableBufferPointer { n in
                            for x in 0..<w {
                                let e = x + 1
                                let old = Int(src[row + x]) + c[e]
                                let black = old < threshold
                                if black { dst[row + x] = 1 }
                                let err = old - (black ? 0 : 255)
                                c[e + 1] += err * 7 / 16
                                n[e - 1] += err * 3 / 16
                                n[e] += err * 5 / 16
                                n[e + 1] += err / 16
                            }
                        }
                    }
                    swap(&cur, &next)
                    for k in 0..<next.count { next[k] = 0 }
                }
            }
        }
        return out
    }

    /// 灰階 → 擴散網點的點陣圖
    public static func floydSteinberg(_ gray: [UInt8], width: Int, height: Int, threshold: Int = 128) -> Bitmap {
        pack(diffuse(gray, width: width, height: height, threshold: threshold), width: width, height: height)
    }

    /// 比 level 暗的＝1
    public static func mask(_ gray: [UInt8], level: UInt8) -> [UInt8] {
        gray.map { $0 < level ? 1 : 0 }
    }

    /// 灰階 → 門檻的點陣圖（字、條碼、QR Code 要銳利）
    public static func threshold(_ gray: [UInt8], width: Int, height: Int, level: UInt8 = 150) -> Bitmap {
        pack(mask(gray, level: level), width: width, height: height)
    }

    /// 往外長 radius 點（方形）：字的白邊
    public static func dilate(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard r > 0, w > 0, h > 0, mask.count >= w * h else { return mask }
        // 先橫的、再直的；滑動視窗數有幾個黑點（每一點只看一次）
        var across = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            var count = 0
            for x in 0..<min(r, w) { count += Int(mask[row + x]) }
            for x in 0..<w {
                if x + r < w { count += Int(mask[row + x + r]) }
                if x - r - 1 >= 0 { count -= Int(mask[row + x - r - 1]) }
                if count > 0 { across[row + x] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            var count = 0
            for y in 0..<min(r, h) { count += Int(across[y * w + x]) }
            for y in 0..<h {
                if y + r < h { count += Int(across[(y + r) * w + x]) }
                if y - r - 1 >= 0 { count -= Int(across[(y - r - 1) * w + x]) }
                if count > 0 { out[y * w + x] = 1 }
            }
        }
        return out
    }

    /// 0／1 → 出單機的點陣圖（每列 ceil(w/8) bytes、高位元在左）
    public static func pack(_ mask: [UInt8], width w: Int, height h: Int) -> Bitmap {
        let rowBytes = (w + 7) / 8
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        guard mask.count >= w * h else { return Bitmap(width: w, height: h, bytes: bytes) }
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] != 0 {
                bytes[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8)
            }
        }
        return Bitmap(width: w, height: h, bytes: bytes)
    }

    /// 三層疊成要印的黑白（見最上面）
    public static func compose(_ l: SlipLayers) -> Bitmap {
        let n = l.width * l.height
        guard n > 0, l.text.count >= n else { return Bitmap(width: max(l.width, 0), height: max(l.height, 0)) }
        let text = mask(l.text, level: l.textLevel)
        // 圖那一層：變淡的底圖，上面畫店標、頁尾、貼圖
        let base = l.background.flatMap { $0.count == n ? lighten($0, amount: l.lighten) : nil }
        var art = l.art.flatMap { $0.count == n ? $0 : nil }
        if let base {
            if let top = art {
                art = l.artAlpha.map { $0.count == n ? over(top, alpha: $0, base: base) : darkest(top, base) } ?? darkest(top, base)
            } else {
                art = base
            }
        }
        guard let art else { return pack(text, width: l.width, height: l.height) }
        let dots = diffuse(art, width: l.width, height: l.height, threshold: Int(l.artLevel))
        let halo = dilate(text, width: l.width, height: l.height, radius: l.halo)
        var out = text
        for i in 0..<n where dots[i] != 0 && halo[i] == 0 { out[i] = 1 }
        return pack(out, width: l.width, height: l.height)
    }
}

/// 一張單據畫成的三層灰階（0＝黑、255＝白，一列一列，三層一樣大）
public struct SlipLayers: Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// 字、線、QR Code（圖都拿掉）：門檻
    public var text: [UInt8]
    /// 店標、頁尾、貼圖（字都拿掉）疊在白底上的灰；沒有圖是 nil
    public var art: [UInt8]?
    /// 那幾張圖的不透明度（0＝透明、255＝不透明）：照透明度畫在底圖上面；nil＝取比較暗的
    public var artAlpha: [UInt8]?
    /// 底圖（疊在白底上、還沒變淡）：沒有是 nil
    public var background: [UInt8]?
    /// 底圖變淡多少（0–1）
    public var lighten: Double
    /// 字的門檻（比它暗的印黑；字細，用 150 讓字粗一點）
    public var textLevel: UInt8
    /// 圖的網點門檻（128）
    public var artLevel: UInt8
    /// 字旁邊挖掉幾點的網點
    public var halo: Int

    public init(width: Int, height: Int, text: [UInt8], art: [UInt8]? = nil, artAlpha: [UInt8]? = nil, background: [UInt8]? = nil,
                lighten: Double = 0.75, textLevel: UInt8 = 150, artLevel: UInt8 = 128, halo: Int = 2) {
        self.width = width
        self.height = height
        self.text = text
        self.art = art
        self.artAlpha = artAlpha
        self.background = background
        self.lighten = lighten
        self.textLevel = textLevel
        self.artLevel = artLevel
        self.halo = halo
    }
}

extension ReceiptRenderer {
    /// 圖片模式：整張單據已經畫成點陣圖（App 的 PrintComposer），前後補上單據裡的控制指令：
    /// 嗶一聲（廚房單）、開錢櫃、切紙。點陣圖照 ESCPOS.raster 分段送（每段最多 chunkRows 列，緩衝小的機器也吃得下）
    public static func raster(_ r: Receipt, image: Bitmap, chunkRows: Int = 256) -> [UInt8] {
        var p = ESCPOS()
        p.initialize()
        if r.blocks.contains(.beep) { p.beep() }
        p.raster(image, chunkRows: chunkRows)
        if r.blocks.contains(.drawer) { p.openDrawer() }
        if r.blocks.contains(.cut) { p.cut() } else { p.feed(3) }
        return p.bytes
    }
}
