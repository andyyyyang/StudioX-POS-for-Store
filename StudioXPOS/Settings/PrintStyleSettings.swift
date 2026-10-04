import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

// 設定 → 出單機：每台的「列印方式」、單據樣式的預覽（每種單據印出來的樣子、測試列印）

// MARK: - 列印方式

/// 一台出單機的列印方式（存在 PrinterConfig.encoding：auto／raster／big5／utf8）
enum PrintMethod: String, CaseIterable, Identifiable {
    case auto, image, text

    var id: String { rawValue }

    init(encoding: String) {
        switch encoding {
        case "raster": self = .image
        case "big5", "utf8": self = .text
        default: self = .auto
        }
    }

    var title: String {
        switch self {
        case .auto: "自動"
        case .image: "圖片"
        case .text: "文字"
        }
    }

    var detail: String {
        switch self {
        case .auto: "照後台的單據樣式"
        case .image: "樣式一致、可以疊圖"
        case .text: "快，舊機器或藍牙慢時"
        }
    }

    /// 選這個時存的值（文字：原本是 UTF-8 的照舊，其他用 Big5）
    func encoding(from current: String) -> String {
        switch self {
        case .auto: "auto"
        case .image: "raster"
        case .text: current == "utf8" ? "utf8" : "big5"
        }
    }

    /// 列表、測試頁上的一句：「自動（圖片）」「圖片」「文字・Big5」
    static func label(_ encoding: String, style: PrintStyle) -> String {
        switch PrintMethod(encoding: encoding) {
        case .auto: "自動（\(style.mode == .image ? "圖片" : "文字")）"
        case .image: "圖片"
        case .text: encoding == "utf8" ? "文字・UTF-8" : "文字・Big5"
        }
    }
}

/// 出單機編輯頁的「列印方式」：自動／圖片／文字（文字再選 Big5、UTF-8）
struct PrintMethodPanel: View {
    @Binding var encoding: String
    let style: PrintStyle

    private var method: PrintMethod { PrintMethod(encoding: encoding) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("列印方式")
            HStack(spacing: 10) {
                ForEach(PrintMethod.allCases) { m in
                    choice(m)
                }
            }
            if method == .text {
                HStack(spacing: 8) {
                    OptionChip(title: "Big5", detail: "大多是這個", selected: encoding == "big5") { encoding = "big5" }
                    OptionChip(title: "UTF-8", detail: "新一點的機器", selected: encoding == "utf8") { encoding = "utf8" }
                }
            }
            Text(hint)
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel(padding: 22)
    }

    private func choice(_ m: PrintMethod) -> some View {
        Button {
            encoding = m.encoding(from: encoding)
        } label: {
            VStack(spacing: 4) {
                Text(m.title)
                    .font(.brand(15, .semibold))
                Text(m.detail)
                    .font(.brand(11.5, .regular))
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.choice(method == m, height: 80))
    }

    private var hint: String {
        switch method {
        case .auto: "後台的單據樣式現在是「\(style.mode == .image ? "圖片" : "文字")」。"
        case .image: "整張畫成圖再印：每台一樣、不缺字；藍牙的機器比較慢。"
        case .text: "印出來的中文是亂碼或問號，就換一個編碼再按「測試列印」。"
        }
    }
}

// MARK: - 單據樣式（列表上的一列 → 預覽）

/// 出單機列表上的「單據樣式」：點開看每種單據印出來的樣子
struct PrintStyleEntry: View {
    @Environment(PrinterHub.self) private var printers
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            row
        }
        .buttonStyle(.row)
        .clipShape(.rect(cornerRadius: Metric.radius, style: .continuous))
        .panel(padding: 0)
        .accessibilityHint("看每一種單據印出來的樣子、測試列印")
        .sheet(isPresented: $showing) {
            PrintStyleSheet()
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 14) {
            HeroIcon("swatch", size: 22)
                .foregroundStyle(Theme.ink2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("單據樣式")
                    .font(.brand(16, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(PrintStyleSummary.style(printers.style))
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.ink2)
                Text("後台設定；點開看每一種單據印出來的樣子")
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            HeroIcon("chevron-right", size: 14)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(.rect)
    }
}

/// 單據樣式的說明文字
enum PrintStyleSummary {
    /// 「圖片・黑體・字 1.0 倍・疊圖：交易明細、取餐單」
    static func style(_ s: PrintStyle) -> String {
        var parts = [s.mode == .image ? "圖片" : "文字", s.font.label, String(format: "字 %.1f 倍", s.scale)]
        let styled = PrintDoc.allCases.filter { s.docs[$0].hasArt }.map(\.label)
        parts.append(styled.isEmpty ? "不疊圖" : "疊圖：" + styled.joined(separator: "、"))
        return parts.joined(separator: "・")
    }

    /// 這種單據：「店標、底圖、1 張貼圖、頁尾・店家的字 2 行・字 1.3 倍」
    static func doc(_ d: DocStyle, scale: Double) -> String {
        var art: [String] = []
        if d.header != nil { art.append("店標") }
        if d.background != nil { art.append("底圖") }
        if !d.overlays.isEmpty { art.append("\(d.overlays.count) 張貼圖") }
        if d.footer != nil { art.append("頁尾") }
        var parts = [art.isEmpty ? "不疊圖" : art.joined(separator: "、")]
        let lines = d.headerLines.count + d.footerLines.count
        if lines > 0 { parts.append("店家的字 \(lines) 行") }
        parts.append(String(format: "字 %.1f 倍", scale))
        return parts.joined(separator: "・")
    }
}

/// 每一種單據印出來的樣子（打好網點的點陣圖，白底：熱感紙是白的，深色模式也一樣），可以測試列印
struct PrintStyleSheet: View {
    @Environment(POSModel.self) private var model
    @Environment(PrinterHub.self) private var printers
    @Environment(\.dismiss) private var dismiss

    @State private var doc: PrintDoc = .receipt
    @State private var paper: PaperWidth = .mm80
    @State private var preview: UIImage?

    /// 換單據、紙寬、樣式，或新的圖下載好了：重畫
    private struct RenderKey: Hashable {
        var doc: PrintDoc
        var paper: PaperWidth
        var style: PrintStyle
        var revision: Int
    }

    private var key: RenderKey { RenderKey(doc: doc, paper: paper, style: printers.style, revision: printers.assets.revision) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "單據樣式", subtitle: "照後台的單據樣式畫成圖片再印：下面就是印出來的樣子", close: { dismiss() })
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pickers
                    summary
                    slip
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            Rule()
            testButton
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(Theme.sheet)
        .task(id: key) { await render() }
        .posSheet()
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(PrintDoc.allCases, id: \.self) { d in
                    OptionChip(title: d.label, selected: doc == d) { doc = d }
                }
            }
            HStack(spacing: 8) {
                ForEach(PaperWidth.allCases, id: \.self) { w in
                    OptionChip(title: w.label, selected: paper == w) { paper = w }
                }
            }
        }
    }

    private var summary: some View {
        let style = printers.style
        let missing = printers.assets.missing(in: style)
        return VStack(alignment: .leading, spacing: 8) {
            ValueRow(label: "全店", value: PrintStyleSummary.style(style))
            ValueRow(label: doc.label, value: PrintStyleSummary.doc(style.docs[doc], scale: style.scale(for: doc)))
            if missing > 0 {
                Banner(text: "\(missing) 張圖還沒下載好：下載好之前印的時候先跳過那張圖", tone: .warning)
            }
            if doc == .kitchen && !style.docs.kitchen.hasArt {
                Text("廚房單不疊圖、整張加粗：站得遠也看得清楚。")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
        }
        .panel(padding: 18)
    }

    @ViewBuilder
    private var slip: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: CGFloat(paper.dots))
                // 印出來的單據：熱感紙是白的（單據例外，深、淺色都一樣）
                .background(Color.white)
                .overlay { Rectangle().strokeBorder(Theme.line, lineWidth: 1) }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(doc.label)印出來的樣子")
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private var testButton: some View {
        Button {
            testPrint()
        } label: {
            HStack(spacing: 8) {
                HeroIcon("printer", size: 18)
                Text("測試列印這張\(doc.label)")
            }
        }
        .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
    }

    private func render() async {
        let sample = PrintStyleSamples.receipt(doc, store: model.store, items: model.catalog.items)
        guard let bitmap = await PrintComposer.render(sample, style: printers.style, paper: paper, assets: printers.assets) else {
            preview = nil
            return
        }
        if Task.isCancelled { return }
        preview = PrintComposer.image(bitmap)
    }

    private func testPrint() {
        let role: PrinterRole = doc == .kitchen ? .kitchen : .receipt
        printers.print(PrintStyleSamples.receipt(doc, store: model.store, items: model.catalog.items), role: role)
        if printers.targets(role).isEmpty {
            model.show("沒有\(role.label)出單機：留在「最近列印」", tone: .neutral)
        } else {
            model.show("已送出測試列印", tone: .neutral)
        }
    }
}

// MARK: - 範例單據

/// 預覽、測試列印用的單據：這家店的店名與菜單（前三樣），金額是真的算出來的
enum PrintStyleSamples {
    static func receipt(_ doc: PrintDoc, store: StoreProfile, items: [MenuItem], at: Date = Date()) -> Receipt {
        let floor = FloorPlan(areas: [FloorArea(id: "sample-area", name: "1F", tables: [DiningTable(id: "sample-a2", areaId: "sample-area", name: "A2")])])
        var t = Ticket(id: "sample", number: "A023", deviceId: "sample", orderType: doc == .bill ? .dineIn : .takeout,
                       tableIds: doc == .bill ? ["sample-a2"] : [], guests: doc == .bill ? 2 : 0, openedAt: at, openedBy: "sample",
                       businessDate: TaipeiTime.businessDate(at))
        t.lines = lines(items, at: at)
        switch doc {
        case .kitchen:
            return Templates.kitchenTicket(t, lines: t.lines, station: nil, mode: .new, floor: floor, at: at)
        case .bill:
            return Templates.bill(t, store: store, floor: floor)
        case .receipt, .pickup:
            let due = t.totals.amountDue
            let tendered = Money(cents: max((due.cents + 9_999) / 10_000, 1) * 10_000)
            t.payments = [Payment.cash(id: "sample-pay", tendered: tendered, due: due, at: at, by: "sample", shiftId: nil)]
            let sale = SaleRecord(ticket: t, closedOn: "sample", shiftId: nil, closedAt: at, closedBy: "sample", staffName: "店長", floor: floor)
            return Templates.saleReceipt(sale, store: store, pickupNumber: doc == .pickup ? "23" : nil)
        }
    }

    private static func lines(_ items: [MenuItem], at: Date) -> [TicketLine] {
        let picks = Array(items.filter { $0.isAvailable && $0.price.cents > 0 }.prefix(3))
        guard !picks.isEmpty else {
            return [TicketLine(id: "sample-1", itemId: nil, name: "招牌餐", unitPrice: Money(dollars: 120), quantity: 2, addedAt: at, addedBy: "sample"),
                    TicketLine(id: "sample-2", itemId: nil, name: "今日飲品", unitPrice: Money(dollars: 60), addedAt: at, addedBy: "sample")]
        }
        return picks.enumerated().map { i, item in
            TicketLine(id: "sample-\(i)", itemId: item.id, name: item.name, unitPrice: item.price, quantity: i == 0 ? 2 : 1,
                       note: i == 1 ? "少辣" : "", station: item.station, addedAt: at, addedBy: "sample")
        }
    }
}
