import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

// 圖片模式（預設）：每一張單據照後台的單據樣式（printStyle）畫成點陣圖再送出單機（GS v 0）。
// 和後台「單據樣式」設計頁的預覽同一套規則（店長在後台看到的＝印出來的）：
//
//   ┌──────────────────┐
//   │ （取餐號碼）      │  取餐單的號碼照樣在最上面
//   │      [店標]       │  header：在店名上面；寬度是紙寬的比例、靠左／中／右
//   │ 店名、地址、電話  │
//   │   headerLines     │  店家自己的字（廚房單沒有店名：放在最上面）
//   │ 明細、總計…       │  ReceiptPaper：24 點的字 × scale（2 倍字＝2×），不留左右邊：58 mm 一行 16 個中文字、80 mm 24 個
//   │   footerLines     │
//   │      [頁尾]       │  footer：最後
//   └──────────────────┘  底圖墊在整張下面：top＝照紙寬放在最上面一次、tile＝照紙寬往下一直重複、stretch＝拉滿整張；
//                         貼圖：x＝左緣、y＝離上緣（或下緣）的距離、寬，都是紙寬的比例，高照圖的比例
//
// 同一個版面畫三次（只留一層看得到，其他層留著位置）：底圖、圖（店標、頁尾、貼圖，透明底）、字。
// ImageRenderer 要在主執行緒（很快：一張單幾十毫秒）；疊成黑白在背景（Halftone.compose，純函式）：
// 底圖變淡 → 照透明度畫上店標、頁尾、貼圖 → 一起打擴散網點（門檻 128）；字用門檻 150；任一層是黑就印黑，
// 字旁邊 2 點的網點先挖掉（深色的圖上的字也看得清楚；後台的預覽沒有這一步）。熱感紙是黑白：這裡的顏色只有黑與白。

extension PrintFont {
    var design: Font.Design {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .rounded: .rounded
        }
    }

    var label: String {
        switch self {
        case .sans: "黑體"
        case .serif: "明體"
        case .rounded: "圓體"
        }
    }
}

extension PrintAlign {
    var alignment: Alignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// 要送出去的位元組；preview：印出來的樣子（「最近列印」看得到）
struct PrintPayload {
    var bytes: [UInt8]
    var preview: UIImage?
}

enum PrintComposer {
    /// 字旁邊挖掉幾點的網點
    static let halo = 2

    /// 一層的灰階（疊在白底上）；alpha：不透明度（圖那一層才要）
    struct Gray {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var alpha: [UInt8]?
    }

    /// 主執行緒：照單據樣式畫三層灰階（1 pt＝1 點：58 mm 384、80 mm 576）。印的時候才讀圖，沒有的圖就不畫
    static func layers(_ r: Receipt, style: PrintStyle, paper: PaperWidth, assets: PrintAssets) -> SlipLayers? {
        let doc = style.style(for: r.doc)
        let art = SlipArt(doc, assets: assets)
        let scale = CGFloat(style.scale(for: r.doc))
        func slip(_ layer: PrintedSlip.Layer, height: CGFloat?) -> PrintedSlip {
            PrintedSlip(receipt: r, doc: doc, art: art, design: style.font.design, scale: scale, paper: paper, layer: layer, height: height)
        }
        guard let text = gray(slip(.text, height: nil), width: paper.dots, height: nil) else { return nil }
        let h = CGFloat(text.height)
        let artLayer = art.hasArt ? gray(slip(.art, height: h), width: text.width, height: text.height, alpha: true) : nil
        let backLayer = art.background != nil ? gray(slip(.background, height: h), width: text.width, height: text.height) : nil
        return SlipLayers(width: text.width, height: text.height, text: text.pixels, art: artLayer?.pixels, artAlpha: artLayer?.alpha,
                          background: backLayer?.pixels, lighten: doc.background?.lighten ?? 0, halo: halo)
    }

    /// 背景：打網點、疊成黑白（長單在 iPad 上也要一點時間，不卡畫面）
    static func dither(_ layers: SlipLayers) async -> Bitmap {
        await Task.detached(priority: .userInitiated) { Halftone.compose(layers) }.value
    }

    /// 畫＋打網點（設定頁的預覽）
    static func render(_ r: Receipt, style: PrintStyle, paper: PaperWidth, assets: PrintAssets) async -> Bitmap? {
        guard let drawn = layers(r, style: style, paper: paper, assets: assets) else { return nil }
        return await dither(drawn)
    }

    /// 印出來的樣子（白底黑點、1 px＝1 點）：直接用出單機的位元組當 1-bit 灰階（1＝黑，所以 decode 反過來），不用另外轉
    static func image(_ b: Bitmap) -> UIImage? {
        guard b.width > 0, b.height > 0, let provider = CGDataProvider(data: Data(b.bytes) as CFData) else { return nil }
        let decode: [CGFloat] = [1, 0]
        guard let cg = CGImage(width: b.width, height: b.height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: b.rowBytes,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: decode, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// SwiftUI → 灰階（0＝黑、255＝白，疊在白底上）。height 給了就照那個高（靠上），三層才會一樣大。
    /// alpha：另外讀不透明度（圖那一層：照透明度畫在底圖上面）
    static func gray<V: View>(_ view: V, width: Int, height: Int?, alpha wantsAlpha: Bool = false) -> Gray? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: height.map { CGFloat($0) })
        guard let cg = renderer.cgImage else { return nil }
        let w = width, h = height ?? cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // CG 的原點在左下：靠上對齊
            ctx.draw(cg, in: CGRect(x: 0, y: h - cg.height, width: cg.width, height: cg.height))
            return true
        }
        guard ok else { return nil }
        return Gray(pixels: pixels, width: w, height: h, alpha: wantsAlpha ? opacity(cg, width: w, height: h) : nil)
    }

    /// 不透明度（RGBA 8 位元畫一次、取 A；靠上對齊）
    private static func opacity(_ cg: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: h - cg.height, width: cg.width, height: cg.height))
            return true
        }
        guard ok else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = rgba[i * 4 + 3] }
        return alpha
    }
}

/// 這張單據用到、而且已經在 iPad 上的圖（還沒下載好的就沒有：不印、也不佔位置）
struct SlipArt {
    struct Overlay {
        let spec: PrintOverlay
        let image: UIImage
    }

    var header: UIImage?
    var footer: UIImage?
    var background: UIImage?
    var overlays: [Overlay] = []

    init(_ doc: DocStyle, assets: PrintAssets) {
        header = assets.image(for: doc.header?.url)
        footer = assets.image(for: doc.footer?.url)
        background = assets.image(for: doc.background?.url)
        overlays = doc.overlays.compactMap { o in assets.image(for: o.url).map { Overlay(spec: o, image: $0) } }
    }

    /// 店標、頁尾、貼圖（底圖另外一層）
    var hasArt: Bool { header != nil || footer != nil || !overlays.isEmpty }
}

/// 一張單據印出來的版面（黑白、1 pt＝1 點）。layer：這一次只畫哪一層，三層疊起來是整張
struct PrintedSlip: View {
    enum Layer { case background, art, text }

    let receipt: Receipt
    let doc: DocStyle
    let art: SlipArt
    let design: Font.Design
    let scale: CGFloat
    let paper: PaperWidth
    let layer: Layer
    /// 圖那兩層照字那一層量出來的高度畫
    var height: CGFloat?

    private var width: CGFloat { CGFloat(paper.dots) }
    /// 廚房單：整張加粗（站得遠也看得清楚）、店家的字在最上面
    private var kitchen: Bool { receipt.doc == .kitchen }
    /// 24 點 × 單據樣式的大小（和 ReceiptPaper 一樣）
    private var base: CGFloat { 24 * scale }

    var body: some View {
        content
            .frame(width: width)
            .background(alignment: .top) { backgroundArt }
            .overlay(alignment: .topLeading) { overlayArt }
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .foregroundStyle(Color.black)
            // 圖那一層是透明底（照透明度畫在底圖上面）；字、底圖疊在白紙上
            .background(layer == .art ? Color.clear : Color.white)
            .environment(\.colorScheme, .light)
    }

    /// 店標在店名上面、店家的字接在店名（地址、電話）下面；廚房單沒有店名，店家的字放在最上面
    private var content: some View {
        let parts = Self.split(receipt)
        return VStack(spacing: 3) {
            if kitchen { lines(doc.headerLines) }
            blocks(parts.before)
            if let img = art.header, let spec = doc.header {
                picture(img, spec)
                    .padding(.bottom, 6)
            }
            blocks(parts.store)
            if !kitchen { lines(doc.headerLines) }
            blocks(parts.rest)
            lines(doc.footerLines)
            if let img = art.footer, let spec = doc.footer {
                picture(img, spec)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 10)
    }

    /// 店名那幾行的前面（取餐號碼）、店名那幾行、後面（沒標店名的單據：全部在後面）
    static func split(_ r: Receipt) -> (before: [ReceiptBlock], store: [ReceiptBlock], rest: [ReceiptBlock]) {
        let b = r.blocks
        guard let h = r.storeHeader, h.lowerBound >= 0, h.upperBound <= b.count else { return ([], [], b) }
        return (Array(b[..<h.lowerBound]), Array(b[h]), Array(b[h.upperBound...]))
    }

    @ViewBuilder
    private func blocks(_ list: [ReceiptBlock]) -> some View {
        if !list.isEmpty {
            ReceiptPaper(receipt: Receipt(list, doc: receipt.doc), paper: paper, forPrint: true, design: design, scale: scale, heavy: kitchen)
                .opacity(layer == .text ? 1 : 0)
        }
    }

    private func picture(_ img: UIImage, _ spec: PrintImage) -> some View {
        Image(uiImage: img)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: width * spec.width)
            .frame(maxWidth: .infinity, alignment: spec.align.alignment)
            .opacity(layer == .art ? 1 : 0)
    }

    @ViewBuilder
    private func lines(_ rows: [String]) -> some View {
        if !rows.isEmpty {
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: base, weight: kitchen ? .semibold : .regular, design: design))
            .multilineTextAlignment(.center)
            .padding(.vertical, 4)
            .opacity(layer == .text ? 1 : 0)
        }
    }

    @ViewBuilder
    private var backgroundArt: some View {
        if let img = art.background, let spec = doc.background {
            GeometryReader { geo in
                backdrop(img, fit: spec.fit, slipHeight: geo.size.height)
            }
            .clipped()
            .opacity(layer == .background ? 1 : 0)
        }
    }

    /// top：照紙寬放在最上面一次；tile：照紙寬往下一直重複；stretch：拉滿整張
    @ViewBuilder
    private func backdrop(_ img: UIImage, fit: PrintFit, slipHeight: CGFloat) -> some View {
        switch fit {
        case .top:
            Image(uiImage: img).resizable().interpolation(.high).frame(width: width, height: scaledHeight(img))
        case .tile:
            tiled(img, slipHeight: slipHeight)
        case .stretch:
            Image(uiImage: img).resizable().interpolation(.high).frame(width: width, height: slipHeight)
        }
    }

    private func tiled(_ img: UIImage, slipHeight: CGFloat) -> some View {
        let h = scaledHeight(img)
        let count = min(max(Int((slipHeight / h).rounded(.up)), 1), 400)
        return VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                Image(uiImage: img).resizable().interpolation(.high).frame(width: width, height: h)
            }
        }
    }

    /// 照紙寬放大（縮小）之後的高
    private func scaledHeight(_ img: UIImage) -> CGFloat {
        max(width * img.size.height / max(img.size.width, 1), 1)
    }

    @ViewBuilder
    private var overlayArt: some View {
        if !art.overlays.isEmpty {
            GeometryReader { geo in
                ForEach(Array(art.overlays.enumerated()), id: \.offset) { _, o in
                    sticker(o, slipHeight: geo.size.height)
                }
            }
            .opacity(layer == .art ? 1 : 0)
        }
    }

    /// 貼圖：x、y、寬都是紙寬的比例；anchor top＝圖的上緣離紙的上緣 y，bottom＝圖的下緣離紙的下緣 y
    private func sticker(_ o: SlipArt.Overlay, slipHeight: CGFloat) -> some View {
        let w = width * o.spec.width
        let h = w * o.image.size.height / max(o.image.size.width, 1)
        let y = o.spec.anchor == .top ? width * o.spec.y : slipHeight - width * o.spec.y - h
        return Image(uiImage: o.image)
            .resizable()
            .interpolation(.high)
            .frame(width: w, height: h)
            .offset(x: width * o.spec.x, y: y)
    }
}

// MARK: - 出單機

extension PrinterHub {
    /// 開機資料來了：換樣式、準備圖（下載、示範的在本機畫；沒用到的清掉）。印的時候不等圖
    func applyStyle(_ s: PrintStyle?) {
        style = s ?? .standard
        let assets = self.assets, next = style
        Task { await assets.sync(next) }
    }

    /// 這台實際怎麼印：出單機自己的設定優先，「自動」照後台的單據樣式（預設圖片）
    func mode(of p: PrinterConfig) -> PrintMode {
        PrintMode.resolve(encoding: p.encoding, style: style)
    }

    /// 圖片模式：主執行緒畫三層 → 背景打網點 → 照順序送。畫不出來就印文字（Big5／UTF-8）。
    /// style：要用別的樣式（列印實測印示範店的樣式）；沒給就是後台的
    func printImage(_ r: Receipt, to p: PrinterConfig, title: String, style custom: PrintStyle? = nil) {
        guard let layers = PrintComposer.layers(r, style: custom ?? style, paper: p.paper, assets: assets) else {
            let bytes = ReceiptRenderer.escpos(r, width: p.paper, encode: Self.encoder(p))
            deliver(to: p, title: title, receipt: r) { PrintPayload(bytes: bytes) }
            return
        }
        deliver(to: p, title: title, receipt: nil) {
            let bitmap = await PrintComposer.dither(layers)
            return PrintPayload(bytes: ReceiptRenderer.raster(r, image: bitmap), preview: PrintComposer.image(bitmap))
        }
    }
}
