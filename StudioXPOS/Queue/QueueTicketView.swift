import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 一張號碼牌要印的東西。iPad 直接印（取代樹莓派）：版面照後台的 `queue.ticket`，和樹莓派原本印的一模一樣
struct QueueTicket {
    var layout: QueueTicketLayout
    var number: Int
    /// 目前幾人等候：取號後 waiting 的人數（和樹莓派的 len(waiting) 一樣）
    var waiting: Int
    /// QR Code 的網址（後台沒設網址樣板就沒有）
    var link: String?
    var storeName: String
    var at: Date
    /// 後台的背景圖（沒有設、或還沒下載好是 nil：用預設版面）
    var background: UIImage?

    var waitingText: String { layout.waitingText(waiting: waiting, number: number) }

    func view(dots: Int) -> QueueTicketView { QueueTicketView(ticket: self, dots: dots) }

    /// 出單機的點陣圖：58 mm 384 點、80 mm 576 點（座標等比放大）。門檻 128（樹莓派也是）：黑框裡的白字才不會被吃掉
    func bitmap(paper: PaperWidth) -> Bitmap? {
        Raster.bitmap(view(dots: paper.dots), width: paper.dots, threshold: 128)
    }

    /// 畫面上看的（設定頁的「最近列印」）
    func preview() -> UIImage? {
        let r = ImageRenderer(content: view(dots: QueueTicketLayout.baseWidth))
        r.scale = 2
        return r.uiImage
    }

    /// 文字版：出單機畫不出圖時印這個，「最近列印」也看得到
    func fallback(paper: PaperWidth) -> Receipt {
        Templates.queueTicket(number: number, waiting: waiting, storeName: storeName, at: at, link: link, paper: paper, waitingText: waitingText)
    }
}

/// 號碼牌印出來的樣子（熱感紙：黑白；印出來的單據例外，顏色寫死、不跟深淺色）。
///
///   有背景圖（後台的版面）：照樹莓派的 compose_ticket_image 一模一樣的座標
///     ┌──────────────┐  背景圖照比例裁滿 384×height、置中
///     │    (小雞)     │
///     │ ┌ 你的號碼 ┐  │  號碼：白字、置中、ascender 線在 y=140、90 點
///     │ │   24    │  │
///     │ └─────────┘  │  等候人數：y=290、20 點
///     │ 目前 5 人等候中 │
///     │ 查看現在叫號   │  QR：寬 0.45×384、離底部 100 點
///     │    ▣▣▣       │
///     └──────────────┘
///   沒有背景圖：StudioX 的預設版面（店名、黑底大號碼、等候人數、時間、QR）
struct QueueTicketView: View {
    let ticket: QueueTicket
    /// 紙寬的點數：58 mm 384、80 mm 576（座標都以 384 為準等比放大）
    var dots = QueueTicketLayout.baseWidth

    /// 預設版面的長度（384 寬時）
    static let standardHeight: CGFloat = 640

    private var k: CGFloat { CGFloat(dots) / CGFloat(QueueTicketLayout.baseWidth) }
    private var width: CGFloat { CGFloat(dots) }

    var body: some View {
        Group {
            if let bg = ticket.background {
                designed(bg)
            } else {
                standard
            }
        }
        .foregroundStyle(Color.black)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: 後台的版面（樹莓派的座標）

    private func designed(_ bg: UIImage) -> some View {
        let layout = ticket.layout
        let height = CGFloat(layout.height) * k
        let side = CGFloat(layout.qrSide) * k
        let qrTop = height - side - CGFloat(layout.qr.bottom) * k
        return ZStack(alignment: .top) {
            // 背景：照比例裁滿、置中（cover）
            Image(uiImage: bg)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
            line(String(ticket.number), layout.number, digits: true)
            line(ticket.waitingText, layout.waiting, digits: false)
            if let link = ticket.link {
                qr(link, side: side)
                    .alignmentGuide(.top) { [qrTop] _ in -qrTop }
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipped()
    }

    /// 一行字，水平置中。y 是字型的 ascender 線（PIL 的 draw.text 預設錨點 "la"），
    /// 所以基線＝y＋1.16 em（Noto Sans TC 的 ascender）；用基線對齊，換字型也不會跑掉
    private func line(_ text: String, _ spec: QueueTicketLayout.Line, digits: Bool) -> some View {
        let size = CGFloat(spec.size) * k
        let baseline = CGFloat(spec.y) * k + size * 1.16
        let font = digits ? Font.system(size: size, weight: .semibold).monospacedDigit() : Font.system(size: size, weight: .semibold)
        return Text(text)
            .font(font)
            .foregroundStyle(spec.color == .white ? Color.white : Color.black)
            .lineLimit(1)
            .fixedSize()
            .alignmentGuide(.top) { [baseline] d in d[.firstTextBaseline] - baseline }
    }

    /// QR Code：白底（和樹莓派一樣留一圈白邊）、容錯 M
    @ViewBuilder
    private func qr(_ link: String, side: CGFloat) -> some View {
        if let img = Raster.qr(link, maxSide: Int(side), correction: "M") {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .padding(side * 0.04)
                .frame(width: side, height: side)
                .background(Color.white)
        }
    }

    // MARK: 預設版面（沒有背景圖、還沒下載好、示範店）

    private var standard: some View {
        VStack(spacing: 0) {
            Text(ticket.storeName)
                .font(.system(size: 26 * k, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24 * k)
                .padding(.top, 34 * k)
            Text("你的號碼")
                .font(.system(size: 17 * k, weight: .semibold))
                .padding(.top, 14 * k)
            Text(String(ticket.number))
                .font(.system(size: 104 * k, weight: .bold).monospacedDigit())
                .tracking(-2 * k)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: 150 * k)
                .background(Color.black, in: .rect(cornerRadius: 26 * k, style: .continuous))
                .padding(.horizontal, 34 * k)
                .padding(.top, 10 * k)
            Text(ticket.waitingText)
                .font(.system(size: 20 * k, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 18 * k)
            Text(TaipeiTime.dayString(ticket.at) + "  " + TaipeiTime.clock(ticket.at))
                .font(.system(size: 15 * k, weight: .medium).monospacedDigit())
                .padding(.top, 6 * k)
            if let link = ticket.link {
                Text("掃描看現在叫到幾號")
                    .font(.system(size: 15 * k, weight: .semibold))
                    .padding(.top, 22 * k)
                qr(link, side: 150 * k)
                    .padding(.top, 6 * k)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Self.standardHeight * k, alignment: .top)
    }
}

/// 號碼牌的背景圖：下載一次存在 Caches（照網址），之後都用存著的。
/// 下載好之前用預設版面（不等：號碼牌一定印得出來）
@Observable
final class QueueTicketArt {
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// 已經在手上的（沒有就是 nil；要的話先 prefetch）
    func image(for url: String?) -> UIImage? {
        guard let url else { return nil }
        return images[url]
    }

    /// 先看 Caches 有沒有，沒有就下載（失敗不要緊：照樣用預設版面，下次再試）
    func prefetch(_ url: String?) async {
        guard let url, images[url] == nil, !loading.contains(url), let remote = URL(string: url) else { return }
        loading.insert(url)
        defer { loading.remove(url) }
        let file = Self.cacheFile(for: url)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            images[url] = img
            return
        }
        guard let result = try? await URLSession.shared.data(from: remote) else { return }
        let (data, response) = result
        guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 300, let img = UIImage(data: data) else { return }
        try? data.write(to: file, options: .atomic)
        images[url] = img
    }

    static func cacheFile(for url: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("queue-ticket", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
        return dir.appendingPathComponent(Crypto.SHA256.hex(url) + (ext.isEmpty ? "" : ".\(ext)"))
    }
}
