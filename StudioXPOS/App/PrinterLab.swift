import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

#if DEBUG
/// 列印實測（只在 Debug、帶 -printerLab <主機>）：截圖的 CI 用。
///
/// 把這台的出單機換成虛擬出單機（tools/escpos-emulator，在同一台 Mac 上；模擬器和 Mac 共用網路，所以 127.0.0.1 連得到），
/// 走和店裡一模一樣的網路列印（TCP 9100），照順序印一輪；虛擬出單機把收到的指令畫成圖片：
///
///   9100：58 mm、Big5（收據、證明聯、號碼牌、錢櫃）
///   9101：80 mm、Big5（廚房）
///   9102：80 mm、點陣圖模式（收據：整張畫成圖再送）
enum PrinterLab {
    static var started = false
}

extension POSModel {
    func runPrinterLabIfAsked() {
        guard let host = LaunchArguments.value("-printerLab"), !PrinterLab.started else { return }
        PrinterLab.started = true

        var p58 = PrinterConfig(name: "虛擬 58（收據・證明聯・號碼牌）")
        p58.host = host; p58.port = 9100; p58.paper = .mm58; p58.encoding = "big5"
        p58.roles = [.receipt, .invoice, .queue]; p58.hasDrawer = true
        var p80 = PrinterConfig(name: "虛擬 80（廚房）")
        p80.host = host; p80.port = 9101; p80.paper = .mm80; p80.encoding = "big5"; p80.roles = [.kitchen]
        var r80 = PrinterConfig(name: "虛擬 80 點陣圖（收據）")
        r80.host = host; r80.port = 9102; r80.paper = .mm80; r80.encoding = "raster"; r80.roles = [.receipt]
        printers.printers = [p58, p80, r80]

        Task { @MainActor in
            func step(_ label: String, _ run: () -> Void) async {
                print("PrinterLab: \(label)")
                run()
                // 一張一張來：虛擬出單機照收到的順序編號
                try? await Task.sleep(for: .milliseconds(1500))
            }
            try? await Task.sleep(for: .seconds(2))
            for p in printers.printers {
                await step("測試頁 \(p.name)") { printers.test(p, store: store) }
            }
            let sales = state.closedSales()
            if let sale = sales.last {
                // 收據：58（Big5 文字）與 80（點陣圖）各一張
                await step("交易明細 \(sale.number)") { printReceipt(sale) }
            }
            if let t = state.openTickets.first(where: { !$0.activeLines.isEmpty }) {
                await step("廚房單 \(t.number)") { printKitchen(t, lines: t.activeLines, mode: .new) }
                await step("結帳單 \(t.number)") { printers.print(Templates.bill(t, store: store, floor: floor), role: .receipt) }
            }
            if let sale = sales.last(where: { $0.invoice != nil }), let number = sale.invoice?.number, let inv = state.invoices[number] {
                await step("證明聯 \(number)") {
                    printers.printInvoice(InvoiceProof(invoice: inv, storeName: store.name, qrKey: invoiceSettings.qrKey), detail: sale, store: store)
                }
            }
            let layout = queueConfig?.ticket ?? .standard
            let link = "https://cms.example.tw/q?no=128&waiting=7"
            await step("號碼牌（預設版面）") {
                printers.printQueueTicket(QueueTicket(layout: layout, number: 128, waiting: 7, link: link, storeName: store.name, at: Date(), background: nil))
            }
            // 黑框裡印白字（和黃毛丫頭的背景一樣的排法）：門檻要讓白字留下來
            await step("號碼牌（黑框背景）") {
                printers.printQueueTicket(QueueTicket(layout: layout, number: 129, waiting: 8, link: link, storeName: store.name, at: Date(),
                                                      background: Self.labTicketBackground()))
            }
            await step("開錢櫃") { printers.openDrawer() }
            print("PrinterLab: done")
        }
    }

    /// 測試用的號碼牌背景：上面一塊黑色圓角框（號碼的位置）、下面一個細框（QR 的位置），9:16
    static func labTicketBackground() -> UIImage {
        let size = CGSize(width: 720, height: 1280)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(x: 90, y: 240, width: 540, height: 320), cornerRadius: 60).fill()
            UIColor.black.setStroke()
            let frame = UIBezierPath(roundedRect: CGRect(x: 14, y: 380, width: 692, height: 770), cornerRadius: 48)
            frame.lineWidth = 6
            frame.stroke()
        }
    }
}
#endif
