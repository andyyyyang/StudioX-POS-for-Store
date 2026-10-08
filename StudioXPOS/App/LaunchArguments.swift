import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 截圖與自動測試用的啟動參數（只在 Debug 有用）：
///
///   -demo <cafe|apparel|salon|fitness|yellowgirl>   示範店（示範模式自己處理）
///   -autologin <PIN>                     跳過鎖定畫面，用這個 PIN 的人登入
///   -section <頁>                        登入後打開這一頁（AppSection 的 rawValue：order、floor、appointments、checkIn、queue…）
///   -landscape                           請系統轉成橫的（iPad 收銀台的樣子）
///   -serviceMode <模式>、-workstation <崗位>   UserDefaults 的參數網域會直接蓋過這台的設定
///   -preselect                           打開的那一頁先選起第一筆（截右欄「選起來之後」的樣子）
///   -printerLab <主機>                   出單機換成虛擬出單機（tools/escpos-emulator），印一輪實測
///   -personal                            示範店當成 -autologin 那位的個人手機（用 StudioX 帳號登入的樣子：不用 PIN、鎖定是 Face ID）
///   -lockNow                             登入、開頁之後馬上鎖定（截鎖定畫面；配 -personal 是 Face ID 的那一種）
///   -scanDemo <碼>                       登入、開頁之後掃一次這個碼（POSModel.handleScan：WELCOME100、0912345678、/ABC+123…）；
///                                        點餐頁還沒有單時先選一張有點東西的單，手機再把單子打開（截「掃到之後」的樣子）
///   -typeDigits <數字>                   登入、開頁之後在鍵盤上打這串數字（截「打了金額」的樣子：現金模式的「收現金 NT$120」）
///   -cashMode YES、-phoneTakesPayment YES   現金模式、手機也能收款（UserDefaults 的參數網域）
///   -phoneCashPadCollapsed YES          手機現金模式的數字鍵收起來（往下滑之後的樣子）
///   -checkInTab classes                  報到頁直接看課表（健身）
///   -checkout                            登入、開頁之後選一張有點東西的單、打開結帳畫面（截付款的樣子）
enum LaunchArguments {
    static func value(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.hasPrefix("-") ? nil : v
    }

    static func has(_ key: String) -> Bool { ProcessInfo.processInfo.arguments.contains(key) }

    /// -scanDemo 只掃一次（鎖定後再登入不會再掃）
    static var scanDemoDone = false
    /// -typeDigits 只打一次
    static var typeDemoDone = false
    /// -checkout 只開一次
    static var checkoutDemoDone = false

    /// 截圖用：頁面出現時先選起第一筆（只在 Debug）。各頁在 .onAppear／.task 裡看這個
    static var preselect: Bool {
        #if DEBUG
        has("-preselect")
        #else
        false
        #endif
    }
}

extension POSModel {
    /// 鎖定畫面出現後呼叫：照參數自動登入、打開某一頁
    func applyLaunchArguments() {
        #if DEBUG
        // 個人的裝置鎖起來之後不自動登入（要 Face ID）
        if phase == .locked, !isPersonalDevice, let pin = LaunchArguments.value("-autologin"), let s = Staff.match(pin: pin, in: staff) {
            if LaunchArguments.has("-personal") { bindDemoPersonal(to: s) }
            login(s)
        }
        if phase == .ready, let raw = LaunchArguments.value("-section"), let s = AppSection(rawValue: raw) {
            go(s)
        }
        // 列印實測：接到虛擬出單機印一輪（App/PrinterLab.swift）
        if phase == .ready { runPrinterLabIfAsked() }
        // 掃碼的截圖：掃一次（Model/POSModel+Scan.swift）
        if phase == .ready, !LaunchArguments.scanDemoDone, let code = LaunchArguments.value("-scanDemo") {
            LaunchArguments.scanDemoDone = true
            Task { await runScanDemo(code) }
        }
        // 鍵盤打一串數字的截圖（現金模式的「收現金 NT$120」）
        if phase == .ready, !LaunchArguments.typeDemoDone, let digits = LaunchArguments.value("-typeDigits") {
            LaunchArguments.typeDemoDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                keypad.type(digits)
            }
        }
        // 結帳畫面的截圖：小計最大、還沒送去結帳的那張單
        if phase == .ready, !LaunchArguments.checkoutDemoDone, LaunchArguments.has("-checkout") {
            LaunchArguments.checkoutDemoDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                let open = state.openTickets.filter { !$0.activeLines.isEmpty }
                guard let t = open.max(by: { $0.totals.subtotal < $1.totals.subtotal }) else { return }
                selectedTicketId = t.id
                beginCheckout(t)
            }
        }
        if phase == .ready, LaunchArguments.has("-lockNow") { lock() }
        #endif
    }

    #if DEBUG
    /// -scanDemo：等畫面好了掃一次。點餐頁還沒有單：先選一張有點東西、還沒送去結帳的單（小計最大的，折價券的最低消費才夠），
    /// 掃到的會員、載具、折價券看得到掛在單子上；手機再把單子的 sheet 打開
    private func runScanDemo(_ code: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        if section == .order, selectedTicket == nil {
            let open = state.openTickets.filter { !$0.activeLines.isEmpty && $0.billPrintedAt == nil }
            if let t = open.max(by: { $0.totals.subtotal < $1.totals.subtotal }) { selectedTicketId = t.id }
        }
        await handleScan(code)
        try? await Task.sleep(for: .milliseconds(400))
        revealTicketRequest += 1
    }
    #endif

    /// 截圖時轉成橫的
    func requestLandscapeIfAsked() {
        #if DEBUG
        guard LaunchArguments.has("-landscape") else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        #endif
    }
}
