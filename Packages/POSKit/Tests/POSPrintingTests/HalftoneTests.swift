import Foundation
import Testing
@testable import POSPrinting

/// 擴散網點（照片、插畫）、門檻（字）、字的白邊、三層疊起來、分段送出單機
struct HalftoneTests {
    /// 一整塊同樣的灰
    static func flat(_ v: UInt8, _ w: Int, _ h: Int) -> [UInt8] { [UInt8](repeating: v, count: w * h) }

    /// 左黑右白的漸層
    static func ramp(_ w: Int, _ h: Int) -> [UInt8] {
        var g = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { g[y * w + x] = UInt8(x * 255 / max(w - 1, 1)) } }
        return g
    }

    static func ink(_ mask: [UInt8]) -> Double { Double(mask.reduce(0) { $0 + Int($1) }) / Double(max(mask.count, 1)) }

    @Test func lighten() {
        #expect(Halftone.lighten([0, 128, 255], amount: 0) == [0, 128, 255])
        #expect(Halftone.lighten([0, 128, 255], amount: 1) == [255, 255, 255])
        // 黑變淡 75%＝255 − 255×0.25
        #expect(Halftone.lighten([0, 255], amount: 0.75) == [191, 255])
        // 範圍外的當 0–1
        #expect(Halftone.lighten([0], amount: 7) == [255])
        #expect(Halftone.lighten([0], amount: -1) == [0])
        #expect(Halftone.darkest([10, 200, 90], [50, 20, 90]) == [10, 20, 90])
    }

    /// 平的灰：印黑的比例≈有多暗
    @Test func flatGrays() {
        let w = 64, h = 64
        #expect(Self.ink(Halftone.diffuse(Self.flat(255, w, h), width: w, height: h)) == 0)
        #expect(Self.ink(Halftone.diffuse(Self.flat(0, w, h), width: w, height: h)) == 1)
        for (v, expected) in [(UInt8(64), 0.75), (128, 0.5), (192, 0.25), (230, 0.1)] {
            let ratio = Self.ink(Halftone.diffuse(Self.flat(v, w, h), width: w, height: h))
            #expect(abs(ratio - expected) < 0.03, "灰 \(v)：\(ratio)")
        }
        // 50% 灰是交錯的點，不是一整塊黑一整塊白
        let half = Halftone.diffuse(Self.flat(128, w, h), width: w, height: h)
        let firstRow = half[0..<w].reduce(0) { $0 + Int($1) }
        #expect(firstRow > w / 3 && firstRow < w * 2 / 3)
    }

    /// 漸層：左邊（黑）點多、右邊（白）點少，整體約一半
    @Test func gradient() {
        let w = 96, h = 24
        let dots = Halftone.diffuse(Self.ramp(w, h), width: w, height: h)
        func columns(_ r: Range<Int>) -> Double {
            var on = 0
            for y in 0..<h { for x in r { on += Int(dots[y * w + x]) } }
            return Double(on) / Double(r.count * h)
        }
        let quarters = [columns(0..<24), columns(24..<48), columns(48..<72), columns(72..<96)]
        #expect(quarters[0] > 0.8 && quarters[3] < 0.2)
        #expect(quarters[0] > quarters[1] && quarters[1] > quarters[2] && quarters[2] > quarters[3])
        #expect(abs(Self.ink(dots) - 0.5) < 0.05)
        // 點陣圖和 0／1 一樣
        let bmp = Halftone.floydSteinberg(Self.ramp(w, h), width: w, height: h)
        #expect(bmp.width == w && bmp.height == h)
        #expect(abs(bmp.inkRatio - Self.ink(dots)) < 0.0001)
        #expect(bmp[0, 0] && !bmp[w - 1, h - 1])
    }

    /// 和 Bitmap(gray:dither:) 一模一樣（後台「單據樣式」的預覽照 Bitmap.swift 的規則打網點，預覽才會等於印出來的）
    @Test func sameAsBitmapDither() {
        var seed: UInt32 = 12345
        func noise() -> UInt8 {
            seed = seed &* 1_103_515_245 &+ 12345
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
        let w = 77, h = 41
        let random = (0..<(w * h)).map { _ in noise() }
        for (gray, width, height) in [(random, w, h), (Self.ramp(96, 24), 96, 24), (Self.flat(100, 33, 9), 33, 9)] {
            let ours = Halftone.floydSteinberg(gray, width: width, height: height)
            let reference = Bitmap(gray: gray, width: width, height: height, threshold: 128, dither: true)
            #expect(ours == reference)
        }
    }

    /// 圖照透明度畫在變淡的底圖上面（後台的順序：底圖 → 店標、頁尾 → 貼圖）
    @Test func paintOrder() {
        let base: [UInt8] = [200, 200, 200, 0]
        // 透明的地方看得到底圖；不透明的白蓋掉底圖；半透明的黑在中間
        let art: [UInt8] = [255, 255, 128, 255]
        let alpha: [UInt8] = [0, 255, 255, 0]
        #expect(Halftone.over(art, alpha: alpha, base: base) == [200, 255, 128, 0])
        #expect(Halftone.over([128], alpha: [128], base: [255]) == [128])
        // 不透明的白色店標蓋在黑底圖上：那一塊不印；旁邊（透明）照底圖打網點
        let w = 16, h = 16
        var logo = Self.flat(255, w, h), opaque = Self.flat(0, w, h)
        for y in 0..<8 { for x in 0..<w { logo[y * w + x] = 255; opaque[y * w + x] = 255 } }
        let out = Halftone.compose(SlipLayers(width: w, height: h, text: Self.flat(255, w, h), art: logo, artAlpha: opaque,
                                              background: Self.flat(0, w, h), lighten: 0))
        #expect((0..<w).allSatisfy { !out[$0, 2] } && (0..<w).allSatisfy { out[$0, 12] })
    }

    @Test func thresholdAndPack() {
        let g: [UInt8] = [0, 149, 150, 255, 20, 200, 10, 10, 10, 0]
        let b = Halftone.threshold(g, width: 10, height: 1)
        #expect((0..<10).map { b[$0, 0] } == [true, true, false, false, true, false, true, true, true, true])
        #expect(b.rowBytes == 2 && b.bytes == [0b1100_1011, 0b1100_0000])
    }

    @Test func dilate() {
        var m = [UInt8](repeating: 0, count: 9 * 9)
        m[4 * 9 + 4] = 1
        #expect(Halftone.dilate(m, width: 9, height: 9, radius: 1).reduce(0) { $0 + Int($1) } == 9)
        #expect(Halftone.dilate(m, width: 9, height: 9, radius: 2).reduce(0) { $0 + Int($1) } == 25)
        #expect(Halftone.dilate(m, width: 9, height: 9, radius: 0) == m)
        // 角落：長到紙外的不算
        var corner = [UInt8](repeating: 0, count: 16)
        corner[0] = 1
        #expect(Halftone.dilate(corner, width: 4, height: 4, radius: 1).reduce(0) { $0 + Int($1) } == 4)
    }

    /// 字疊在全黑的圖上：字是黑的、字旁邊挖白（看得出字）、遠一點的圖照樣黑
    @Test func textOverDarkArt() {
        let w = 40, h = 20
        var text = Self.flat(255, w, h)
        for x in 10..<30 { text[10 * w + x] = 0 }  // 一條橫的筆畫
        let out = Halftone.compose(SlipLayers(width: w, height: h, text: text, art: Self.flat(0, w, h), halo: 2))
        for x in 10..<30 { #expect(out[x, 10]) }
        #expect(!out[15, 9] && !out[15, 11] && !out[15, 8] && !out[15, 12])
        #expect(out[15, 7] && out[15, 13] && out[3, 3])
    }

    /// 底圖先變淡再打網點：全黑的底圖 lighten 0.75 → 約 25% 的點；不變淡就是全黑
    @Test func backgroundIsLightened() {
        let w = 64, h = 64
        let white = Self.flat(255, w, h)
        let light = Halftone.compose(SlipLayers(width: w, height: h, text: white, background: Self.flat(0, w, h), lighten: 0.75))
        #expect(abs(light.inkRatio - 0.25) < 0.03)
        let dark = Halftone.compose(SlipLayers(width: w, height: h, text: white, background: Self.flat(0, w, h), lighten: 0))
        #expect(dark.inkRatio == 1)
        // 店標（不變淡）疊在底圖上：取比較暗的
        var logo = Self.flat(255, w, h)
        for i in 0..<(w * 8) { logo[i] = 0 }
        let both = Halftone.compose(SlipLayers(width: w, height: h, text: white, art: logo, background: Self.flat(0, w, h), lighten: 0.75))
        #expect((0..<w).allSatisfy { both[$0, 2] })
        // 沒有圖：只有字（門檻 150）
        let plain = Halftone.compose(SlipLayers(width: 4, height: 1, text: [0, 149, 150, 255]))
        #expect((0..<4).map { plain[$0, 0] } == [true, true, false, false])
    }

    /// 長單：GS v 0 每段最多 256 列；廚房單先嗶一聲、最後切紙
    @Test func rasterBands() {
        let bmp = Bitmap(width: 384, height: 600)
        let bytes = ReceiptRenderer.raster(Receipt([.beep, .text("x", .body), .cut], doc: .kitchen), image: bmp)
        var heights: [Int] = []
        var i = 0
        while i + 8 <= bytes.count {
            if bytes[i] == 0x1D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x30 {
                #expect(Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8 == 48)
                let h = Int(bytes[i + 6]) | Int(bytes[i + 7]) << 8
                heights.append(h)
                i += 8 + 48 * h
            } else {
                i += 1
            }
        }
        #expect(heights == [256, 256, 88])
        #expect(Array(bytes.prefix(3)) == [0x1B, 0x40, 0x07])
        #expect(Array(bytes.suffix(4)) == [0x1D, 0x56, 66, 3])
        // 沒有切紙的單：走紙就好
        let noCut = ReceiptRenderer.raster(Receipt([.drawer]), image: Bitmap(width: 8, height: 1))
        #expect(Array(noCut.suffix(8)) == [0x1B, 0x70, 0, 25, 250, 0x1B, 0x64, 3])
    }
}
