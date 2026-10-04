import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 出單機要印什麼
enum PrinterRole: String, Codable, CaseIterable, Hashable {
    /// 交易明細、結帳單、交班單、退款單
    case receipt
    /// 電子發票證明聯（要 58 mm）
    case invoice
    /// 廚房、吧台的出單
    case kitchen
    /// 叫號的號碼牌（取代樹莓派出單：取號時這台直接印）
    case queue

    var label: String {
        switch self {
        case .receipt: "收據"
        case .invoice: "發票證明聯"
        case .kitchen: "廚房出單"
        case .queue: "號碼牌"
        }
    }
}

/// 出單機怎麼連
enum PrinterConnection: String, Codable, CaseIterable, Hashable {
    /// Wi-Fi／網路線（Epson、Star 這類，埠 9100）
    case network
    /// 藍牙 BLE（小型 58／80 mm 熱感機）
    case bluetooth

    var label: String {
        switch self {
        case .network: "網路"
        case .bluetooth: "藍牙"
        }
    }
}

/// 一台出單機：網路（Epson TM-m30、Star mC-Print、台灣常見的熱感機，埠 9100）或藍牙 BLE。
/// 紙寬每台自己選：58 mm（電子發票證明聯、小單）或 80 mm（收據、廚房單、交班單）
struct PrinterConfig: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var connection: PrinterConnection = .network
    var host: String = ""
    var port: Int = 9100
    /// 藍牙：CoreBluetooth 的裝置 id 與名稱
    var peripheralId: String?
    var peripheralName: String?
    var paper: PaperWidth = .mm80
    /// 列印方式：auto（新的出單機：照後台的單據樣式，預設畫成圖片）、raster（圖片）、big5／utf8（文字：出單機自己的字型）。
    /// 之前選好的 big5、utf8 照舊；自動遇到後台設成文字時用 Big5
    var encoding: String = "auto"
    var roles: Set<PrinterRole> = [.receipt]
    /// 廚房出單只印這幾站（空的＝全部）
    var stations: [String] = []
    /// 錢櫃接在這台
    var hasDrawer = false
}

/// 印出來的東西（沒有出單機時在設定頁「最近列印」看得到；示範模式也是）
struct PrintJob: Identifiable {
    let id = UUID()
    let at = Date()
    var title: String
    var receipt: Receipt?
    var image: UIImage?
    var printer: String?
    var error: String?
}

/// 所有出單機。設定存在這台 iPad（每台接的機器不一樣）
@Observable
final class PrinterHub {
    var printers: [PrinterConfig] = [] {
        didSet { save() }
    }
    var status: [String: PrinterHealth] = [:]
    var recent: [PrintJob] = []
    /// 單據樣式（開機資料的 printStyle；PrintComposer.swift）與它的圖
    var style = PrintStyle.standard
    let assets = PrintAssets()
    /// 每台出單機排隊：前一張送完才送下一張（圖片要先在背景打網點，後印的不能先送到）
    @ObservationIgnored private var tails: [String: Task<Void, Never>] = [:]

    private static let key = "printers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let list = try? JSONDecoder().decode([PrinterConfig].self, from: data) {
            printers = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(printers) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var health: [PrinterHealth] {
        printers.map { status[$0.id] ?? PrinterHealth(name: $0.name, ok: true, message: "還沒印過") }
    }

    func targets(_ role: PrinterRole, station: String? = nil) -> [PrinterConfig] {
        printers.filter { p in
            guard p.roles.contains(role) else { return false }
            if role == .kitchen, let station, !p.stations.isEmpty { return p.stations.contains(station) }
            return true
        }
    }

    /// 這台有沒有設定廚房出單機（沒有的話送單時請櫃台幫忙印）
    var hasKitchenPrinter: Bool { printers.contains { $0.roles.contains(.kitchen) } }

    // MARK: 印

    func print(_ r: Receipt, role: PrinterRole, station: String? = nil) {
        let title = Self.title(of: r)
        let list = targets(role, station: station)
        guard !list.isEmpty else {
            remember(PrintJob(title: title, receipt: r, printer: nil, error: nil))
            return
        }
        for p in list {
            // 圖片（預設）：照單據樣式畫成圖；文字：出單機自己的字型
            if mode(of: p) == .image {
                printImage(r, to: p, title: title)
            } else {
                send(ReceiptRenderer.escpos(r, width: p.paper, encode: Self.encoder(p)), to: p, title: title, receipt: r)
            }
        }
    }

    /// 證明聯：畫成點陣圖（兩個 QR Code 左右並排、5.7 公分寬；財政部的格式，只吃單據樣式的字型、不疊圖），
    /// 後面接交易明細（圖片模式照單據樣式畫，文字模式印文字）
    func printInvoice(_ proof: InvoiceProof, detail: SaleRecord?, store: StoreProfile) {
        let image = InvoiceProofRaster.render(proof, font: style.font)
        var list = targets(.invoice)
        if list.isEmpty { list = targets(.receipt) }
        guard !list.isEmpty, let image else {
            remember(PrintJob(title: "證明聯 \(proof.numberLabel)", receipt: detail.map { Templates.saleReceipt($0, store: store) },
                              image: InvoiceProofRaster.preview(proof), printer: nil, error: list.isEmpty ? nil : "證明聯畫不出來"))
            return
        }
        let title = "證明聯 \(proof.numberLabel)"
        let receipt = detail.map { Templates.saleReceipt($0, store: store) }
        for p in list {
            var e = ESCPOS()
            e.initialize()
            e.align(.center)
            e.raster(image)
            e.feed(1)
            e.cut()
            let head = e.bytes
            if let receipt, mode(of: p) == .image, let layers = PrintComposer.layers(receipt, style: style, paper: p.paper, assets: assets) {
                deliver(to: p, title: title, receipt: nil) {
                    let bitmap = await PrintComposer.dither(layers)
                    return PrintPayload(bytes: head + ReceiptRenderer.raster(receipt, image: bitmap), preview: PrintComposer.image(bitmap))
                }
            } else {
                let tail = receipt.map { ReceiptRenderer.escpos($0, width: p.paper, encode: Self.encoder(p)) } ?? []
                send(head + tail, to: p, title: title, receipt: nil)
            }
        }
    }

    /// 號碼牌：照後台的版面畫成點陣圖（和樹莓派印的一樣：GS v 0、走紙、切紙），每台號碼牌出單機印 copies 張；
    /// 出單機畫不出圖時印文字版。沒有號碼牌出單機就留在「最近列印」（畫面上看得到）
    func printQueueTicket(_ ticket: QueueTicket) {
        let title = "號碼牌 \(ticket.number) 號"
        let list = targets(.queue)
        let preview = ticket.preview()
        guard !list.isEmpty else {
            remember(PrintJob(title: title, receipt: ticket.fallback(paper: .mm58), image: preview, printer: nil, error: nil))
            return
        }
        let copies = min(max(ticket.layout.copies, 1), 5)
        for p in list {
            var e = ESCPOS(encode: Self.encoder(p))
            if let image = ticket.bitmap(paper: p.paper) {
                for _ in 0..<copies {
                    e.initialize()
                    // ESC 2：標準行距（樹莓派也先送這個）
                    e.raw([0x1B, 0x32])
                    e.raster(image)
                    e.feed(3)
                    e.cut(feed: 0)
                }
            } else {
                let text = ReceiptRenderer.escpos(ticket.fallback(paper: p.paper), width: p.paper, encode: Self.encoder(p))
                for _ in 0..<copies { e.raw(text) }
            }
            send(e.bytes, to: p, title: title, receipt: ticket.fallback(paper: p.paper), image: preview)
        }
    }

    func openDrawer() {
        let list = printers.filter(\.hasDrawer)
        for p in list {
            var e = ESCPOS()
            e.openDrawer()
            send(e.bytes, to: p, title: "開錢櫃", receipt: nil)
        }
    }

    func test(_ p: PrinterConfig, store: StoreProfile) {
        var r = Receipt()
        r.add(.text(store.name, .title))
        r.add(.text("出單機測試", ReceiptStyle(align: .center, bold: true)))
        r.add(.rule)
        r.add(.row("名稱", p.name, .body))
        r.add(.row("連線", p.connection == .network ? "\(p.host):\(p.port)" : "藍牙 \(p.peripheralName ?? "")", .body))
        r.add(.row("紙寬", p.paper.label, .body))
        r.add(.row("列印方式", PrintMethod.label(p.encoding, style: style), .body))
        r.add(.row("中文", "珍珠奶茶・雞排・鹹酥雞", .body))
        r.add(.row("金額", "1,280", .big))
        r.add(.cut)
        if mode(of: p) == .image {
            printImage(r, to: p, title: "測試")
        } else {
            send(ReceiptRenderer.escpos(r, width: p.paper, encode: Self.encoder(p)), to: p, title: "測試", receipt: r)
        }
    }

    private func send(_ bytes: [UInt8], to p: PrinterConfig, title: String, receipt: Receipt?, image: UIImage? = nil) {
        deliver(to: p, title: title, receipt: receipt, image: image) { PrintPayload(bytes: bytes) }
    }

    /// 送到一台出單機。同一台照順序：前一張送完才送下一張；make 輪到它才跑（圖片模式在這裡等背景的網點算好）
    func deliver(to p: PrinterConfig, title: String, receipt: Receipt?, image: UIImage? = nil,
                 make: @escaping @MainActor () async -> PrintPayload?) {
        let host = p.host, port = p.port, name = p.name, id = p.id
        let connection = p.connection, peripheral = p.peripheralId
        let previous = tails[id]
        tails[id] = Task {
            await previous?.value
            guard let payload = await make() else {
                remember(PrintJob(title: title, receipt: receipt, image: image, printer: name, error: "畫不出來"))
                return
            }
            let shown = payload.preview ?? image
            do {
                switch connection {
                case .network:
                    try await RawSocket.send(payload.bytes, host: host, port: port)
                case .bluetooth:
                    guard let peripheral else { throw BLEError.notFound }
                    try await BluetoothPrinters.shared.send(payload.bytes, to: peripheral)
                }
                status[id] = PrinterHealth(name: name, ok: true)
                remember(PrintJob(title: title, receipt: receipt, image: shown, printer: name, error: nil))
            } catch {
                status[id] = PrinterHealth(name: name, ok: false, message: error.localizedDescription)
                remember(PrintJob(title: title, receipt: receipt, image: shown, printer: name, error: "印不出來：\(error.localizedDescription)"))
            }
        }
    }

    private func remember(_ job: PrintJob) {
        recent.insert(job, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
    }

    static func title(of r: Receipt) -> String {
        for b in r.blocks {
            if case .text(let s, let st) = b, st.bold, st.scale == 1 { return s }
        }
        for b in r.blocks {
            if case .text(let s, _) = b { return s }
        }
        return "單據"
    }

    static func encoder(_ p: PrinterConfig) -> @Sendable (String) -> [UInt8] {
        if p.encoding == "utf8" {
            let f: @Sendable (String) -> [UInt8] = { s in PrinterHub.utf8(s) }
            return f
        }
        let f: @Sendable (String) -> [UInt8] = { s in PrinterHub.big5(s) }
        return f
    }

    nonisolated static func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Big5（台灣出單機的中文）；Big5 沒有的字變成「?」
    nonisolated static func big5(_ s: String) -> [UInt8] {
        let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))
        return Array(s.data(using: String.Encoding(rawValue: cf), allowLossyConversion: true) ?? Data(s.utf8))
    }
}

/// 送一串位元組到網路出單機（TCP 9100），送完就斷線；8 秒連不上算失敗
nonisolated enum RawSocket {
    static func send(_ bytes: [UInt8], host: String, port: Int) async throws {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw PrintError.badAddress }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(bytes), completion: .contentProcessed { error in
                        conn.cancel()
                        once.run {
                            if let error { c.resume(throwing: error) } else { c.resume() }
                        }
                    })
                case .failed(let e), .waiting(let e):
                    conn.cancel()
                    once.run { c.resume(throwing: e) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                conn.cancel()
                once.run { c.resume(throwing: PrintError.timeout) }
            }
        }
    }
}

nonisolated enum PrintError: LocalizedError {
    case badAddress, timeout

    var errorDescription: String? {
        switch self {
        case .badAddress: "出單機的位址不對"
        case .timeout: "連不到出單機（電源、網路線、IP 位址）"
        }
    }
}

/// 只執行一次（網路的回呼可能來好幾次）
nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    init() {}

    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}

// MARK: - 點陣圖

/// 把 SwiftUI 畫面轉成出單機的 1-bit 點陣圖（門檻二值化：字、條碼、QR Code 都要銳利）
enum Raster {
    /// threshold：比它暗的印黑。收據的字細，用 150 讓字粗一點；號碼牌有黑底白字，用 128（和樹莓派一樣）白字才不會被吃掉
    static func bitmap<V: View>(_ view: V, width: Int, threshold: UInt8 = 150) -> Bitmap? {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width)).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var gray = [UInt8](repeating: 255, count: w * h)
        let ok = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return Bitmap(gray: gray, width: w, height: h, threshold: threshold)
    }

    /// QR Code（容錯預設 L；號碼牌用 M，和樹莓派一樣）：每一格 scale 個點
    static func qr(_ text: String, maxSide: Int, correction: String = "L") -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = correction
        guard let out = f.outputImage else { return nil }
        let modules = Int(out.extent.width)
        let scale = max(1, maxSide / max(modules, 1))
        let scaled = out.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 電子發票證明聯（5.7 公分：58 mm 機器的 384 點）
enum InvoiceProofRaster {
    static let width = 384

    /// font：單據樣式的字型（證明聯只吃這個，不疊圖）
    static func render(_ proof: InvoiceProof, font: PrintFont = .sans) -> Bitmap? {
        Raster.bitmap(InvoiceProofTicket(proof: proof, design: font.design), width: width)
    }

    /// 畫面上的預覽（沒有出單機時）
    static func preview(_ proof: InvoiceProof) -> UIImage? {
        let r = ImageRenderer(content: InvoiceProofTicket(proof: proof).frame(width: CGFloat(width)).background(Color.white).environment(\.colorScheme, .light))
        r.scale = 2
        return r.uiImage
    }
}

/// 證明聯的版面（財政部的格式：店名、電子發票證明聯、期別、號碼、日期時間、隨機碼與總計、賣方買方、一維條碼、兩個 QR Code）
struct InvoiceProofTicket: View {
    let proof: InvoiceProof
    var design: Font.Design = .default

    var body: some View {
        VStack(spacing: 2) {
            Text(proof.storeName)
                .font(.system(size: 24, weight: .bold, design: design))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(proof.heading)
                .font(.system(size: 30, weight: .heavy, design: design))
            Text(proof.periodLabel)
                .font(.system(size: 32, weight: .heavy, design: design))
            Text(proof.numberLabel)
                .font(.system(size: 32, weight: .heavy, design: design))
                .monospacedDigit()
            Group {
                row(proof.dateTime, proof.formatCode ?? "")
                row(proof.randomCode, proof.total)
                row(proof.seller, proof.buyer ?? "")
            }
            .font(.system(size: 17, weight: .medium, design: design))
            .monospacedDigit()
            Canvas { ctx, size in
                let bars = Code39.row(proof.barcode, narrow: 1, ratio: 3)
                let x0 = (size.width - CGFloat(bars.count)) / 2
                for (i, black) in bars.enumerated() where black {
                    ctx.fill(Path(CGRect(x: x0 + CGFloat(i), y: 0, width: 1, height: size.height)), with: .color(.black))
                }
            }
            .frame(height: 44)
            .padding(.top, 4)
            HStack {
                qr(proof.qrLeft)
                Spacer(minLength: 8)
                qr(proof.qrRight)
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private func row(_ l: String, _ r: String) -> some View {
        HStack {
            Text(l)
            Spacer(minLength: 4)
            Text(r)
        }
    }

    @ViewBuilder
    private func qr(_ text: String?) -> some View {
        if let text, let img = Raster.qr(text, maxSide: 170) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .frame(width: 170, height: 170)
        } else {
            Color.clear.frame(width: 170, height: 170)
        }
    }
}

/// 一張單據的樣子（印的時候黑白、畫面上用品牌字）。圖片模式印的時候外面再包一層單據樣式（PrintComposer.swift 的 PrintedSlip）
struct ReceiptPaper: View {
    let receipt: Receipt
    var paper: PaperWidth = .mm80
    var forPrint = false
    /// 單據樣式的字型（printStyle.font）、大小（scale）；heavy：整張加粗（廚房單）
    var design: Font.Design = .default
    var scale: CGFloat = 1
    var heavy = false

    /// 印的時候：24 點的字（和出單機的文字模式一樣：58 mm 一行 16 個中文字、80 mm 24 個）× 單據樣式的大小
    private var base: CGFloat { (forPrint ? 24 : 13) * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: forPrint ? 3 : 4) {
            ForEach(Array(receipt.blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .foregroundStyle(forPrint ? Color.black : Theme.ink)
        // 印的時候不留左右邊（滿版：和文字模式一樣寬）；上下留白由 PrintedSlip 管
        .padding(forPrint ? 0 : 18)
    }

    @ViewBuilder
    private func block(_ b: ReceiptBlock) -> some View {
        switch b {
        case .text(let s, let st):
            Text(s)
                .font(font(base * factor(st.scale, screen: 1.45), bold: st.bold))
                .frame(maxWidth: .infinity, alignment: st.align == .center ? .center : st.align == .right ? .trailing : .leading)
                .padding(.vertical, st.invert ? 2 : 0)
                .background(st.invert ? (forPrint ? Color.black : Theme.ink) : .clear)
                .foregroundStyle(st.invert ? (forPrint ? Color.white : Theme.page) : (forPrint ? Color.black : Theme.ink))
        case .row(let l, let r, let st):
            HStack(alignment: .firstTextBaseline) {
                Text(l)
                Spacer(minLength: 8)
                Text(r).monospacedDigit()
            }
            .font(font(base * factor(st.scale, screen: 1.35), bold: st.bold))
        case .detail(let s):
            Text(s)
                .font(font(base * (forPrint ? 1 : 0.88), bold: false))
                .foregroundStyle(forPrint ? Color.black : Theme.muted)
                .padding(.leading, base)
        case .rule:
            Rectangle().fill(forPrint ? Color.black : Theme.line).frame(height: 1).padding(.vertical, 2)
        case .doubleRule:
            VStack(spacing: 2) {
                Rectangle().frame(height: 1)
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(forPrint ? Color.black : Theme.line)
        case .feed(let n):
            Color.clear.frame(height: CGFloat(n) * base)
        case .barcode39(let s):
            Text("‖ \(s) ‖").font(.system(size: base * 0.8).monospaced()).frame(maxWidth: .infinity)
        case .qr(let s):
            if let img = Raster.qr(s, maxSide: 160) {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 120, height: 120).frame(maxWidth: .infinity)
            }
        case .image:
            EmptyView()
        case .drawer, .beep, .cut:
            EmptyView()
        }
    }

    private func font(_ size: CGFloat, bold: Bool) -> Font {
        let weight: Font.Weight = bold ? (heavy ? .heavy : .bold) : (heavy ? .semibold : .regular)
        return .system(size: size, weight: weight, design: design)
    }

    /// 文字模式的放大（ReceiptStyle.scale）→ 畫多大：印的時候和出單機一樣（2 倍字＝2×、取餐號碼 3×）；畫面上的預覽小一點
    private func factor(_ s: Int, screen: CGFloat) -> CGFloat {
        forPrint ? CGFloat(max(s, 1)) : (s > 1 ? screen : 1)
    }
}
