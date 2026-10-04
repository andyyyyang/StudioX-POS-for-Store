import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 示範店的單據樣式（printStyle）。圖不是真的店標：在 iPad 上用 SwiftUI 的形狀和字畫成 PNG，
/// 網址是 `demo-art://…`，PrintAssets 看到就在本機畫、存進單據樣式的圖庫（和下載來的圖一樣）。
///
/// - 黃毛丫頭：小鴨店標（圓形灰底＋鴨子的剪影）、「謝謝光臨」的頁尾、淡淡的圓點底圖（照紙寬往下重複）、「好吃」印章
/// - 晨麥手作：麥穗店標、店家自己的字（營業時間、自備杯）
enum DemoPrintArt {
    static let scheme = "demo-art://"

    enum Piece: String, CaseIterable {
        case duckLogo = "yellowgirl/duck-logo.png"
        case thanks = "yellowgirl/thanks.png"
        case dots = "yellowgirl/dots.png"
        case stamp = "yellowgirl/stamp.png"
        case wheat = "chenmai/wheat-logo.png"

        var url: String { DemoPrintArt.scheme + rawValue }
    }

    // MARK: 樣式

    /// 黃毛丫頭：交易明細與取餐單疊圖；廚房單只放大、不疊圖
    static var yellowgirlStyle: PrintStyle {
        let slip = DocStyle(
            header: PrintImage(url: Piece.duckLogo.url, width: 0.42, align: .center),
            footer: PrintImage(url: Piece.thanks.url, width: 0.8, align: .center),
            background: PrintBackground(url: Piece.dots.url, fit: .tile, lighten: 0.7),
            // 「好吃」章蓋在店標的右邊（不壓到品項、金額）
            overlays: [PrintOverlay(url: Piece.stamp.url, x: 0.70, y: 0.30, width: 0.26, anchor: .top)],
            headerLines: ["夜市滷味・現點現滷"],
            footerLines: ["辣度、蔥蒜，夾菜的時候跟我們說"]
        )
        return PrintStyle(mode: .image, font: .rounded, scale: 1,
                          docs: PrintDocs(receipt: slip, kitchen: DocStyle(scale: 1.3),
                                          bill: DocStyle(header: PrintImage(url: Piece.duckLogo.url, width: 0.32)), pickup: slip))
    }

    /// 晨麥手作：麥穗店標＋店家自己的字（列印實測用這一份：-demo cafe）
    static var cafeStyle: PrintStyle {
        let logo = PrintImage(url: Piece.wheat.url, width: 0.34, align: .center)
        let slip = DocStyle(header: logo, headerLines: ["手作麵包・自家烘焙咖啡"], footerLines: ["每天 8:00 出爐・週一公休", "自備杯外帶折 5 元"])
        return PrintStyle(mode: .image, font: .sans, scale: 1,
                          docs: PrintDocs(receipt: slip, kitchen: DocStyle(scale: 1.15), bill: DocStyle(header: logo), pickup: slip))
    }

    // MARK: 畫成 PNG

    /// demo-art:// 的網址 → PNG（底圖 1 倍：剛好是 80 mm 的紙寬；其他 2 倍，縮到紙寬時比較細）
    static func png(for url: String) -> Data? {
        guard url.hasPrefix(scheme), let piece = Piece(rawValue: String(url.dropFirst(scheme.count))) else { return nil }
        let renderer = ImageRenderer(content: view(piece).environment(\.colorScheme, .light))
        renderer.scale = piece == .dots ? 1 : 2
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }

    @ViewBuilder
    private static func view(_ piece: Piece) -> some View {
        switch piece {
        case .duckLogo: DemoDuckLogo()
        case .thanks: DemoThanksBanner()
        case .dots: DemoDotTile()
        case .stamp: DemoTastyStamp()
        case .wheat: DemoWheatLogo()
        }
    }
}

// 印出來是黑白：這些圖只用黑、白、灰（灰色會打成網點）

/// 小鴨店標：灰色圓底（打成網點）、黑色鴨子剪影、外圈
private struct DemoDuckLogo: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.72))
            Circle().strokeBorder(Color.black, lineWidth: 7)
            Circle().strokeBorder(Color.black, lineWidth: 2).padding(14)
            duck
                .offset(x: 6, y: 8)
        }
        .frame(width: 200, height: 200)
    }

    private var duck: some View {
        ZStack {
            // 身體、尾巴
            Ellipse().frame(width: 104, height: 62).offset(x: 10, y: 16)
            Capsule().frame(width: 40, height: 20).rotationEffect(.degrees(-35)).offset(x: 58, y: 2)
            // 頭、嘴
            Circle().frame(width: 50, height: 50).offset(x: -32, y: -24)
            Capsule().frame(width: 30, height: 13).offset(x: -64, y: -18)
            // 眼睛、翅膀（白）
            Circle().fill(Color.white).frame(width: 9, height: 9).offset(x: -38, y: -32)
            Ellipse().stroke(Color.white, lineWidth: 4).frame(width: 52, height: 26).offset(x: 18, y: 14)
        }
        .foregroundStyle(Color.black)
    }
}

/// 頁尾：黑色緞帶上反白的「謝謝光臨」，兩邊星星，下面一排灰點
private struct DemoThanksBanner: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                star
                Text("謝謝光臨")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                    .background(Color.black, in: .capsule)
                star
            }
            HStack(spacing: 12) {
                ForEach(0..<9, id: \.self) { i in
                    Circle().fill(Color(white: i % 2 == 0 ? 0.35 : 0.65)).frame(width: 10, height: 10)
                }
            }
        }
        .padding(8)
        .frame(width: 420)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(Color.black)
    }
}

/// 底圖的一段（576×96：一張紙寬，tile 照紙寬往下一直重複）：兩排錯開的圓點
private struct DemoDotTile: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(0..<12, id: \.self) { i in
                dot.offset(x: CGFloat(i * 48 + 17), y: 17)
                dot.offset(x: CGFloat(i * 48 + 41), y: 65)
            }
        }
        .frame(width: 576, height: 96)
    }

    private var dot: some View {
        Circle().fill(Color.black).frame(width: 14, height: 14)
    }
}

/// 「好吃」印章：雙圈、斜斜的
private struct DemoTastyStamp: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.black, lineWidth: 7)
            Circle().strokeBorder(Color.black, lineWidth: 2).padding(13)
            VStack(spacing: 0) {
                Text("★ 黃毛 ★")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("好吃")
                    .font(.system(size: 52, weight: .black, design: .rounded))
            }
            .foregroundStyle(Color.black)
        }
        .frame(width: 150, height: 150)
        .rotationEffect(.degrees(-14))
        .padding(6)
    }
}

/// 晨麥手作的店標：三支麥穗（莖＋一對一對的麥粒），下面一行英文小字
private struct DemoWheatLogo: View {
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                stalk.rotationEffect(.degrees(-22), anchor: .bottom)
                stalk
                stalk.rotationEffect(.degrees(22), anchor: .bottom)
            }
            .frame(width: 190, height: 150)
            Text("CHENMAI BAKERY")
                .font(.system(size: 17, weight: .semibold))
                .tracking(3)
        }
        .foregroundStyle(Color.black)
        .padding(8)
    }

    private var stalk: some View {
        ZStack(alignment: .bottom) {
            Capsule().frame(width: 5, height: 140)
            VStack(spacing: 2) {
                Ellipse().frame(width: 14, height: 26)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2) {
                        Ellipse().frame(width: 13, height: 24).rotationEffect(.degrees(-32))
                        Ellipse().frame(width: 13, height: 24).rotationEffect(.degrees(32))
                    }
                }
            }
            .padding(.bottom, 44)
        }
        .frame(width: 40, height: 150, alignment: .bottom)
    }
}
