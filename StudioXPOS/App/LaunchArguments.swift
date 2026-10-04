import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 截圖與自動測試用的啟動參數（只在 Debug 有用）：
///
///   -demo <cafe|apparel|salon|fitness>   示範店（示範模式自己處理）
///   -autologin <PIN>                     跳過鎖定畫面，用這個 PIN 的人登入
///   -section <頁>                        登入後打開這一頁（AppSection 的 rawValue：order、floor、appointments、checkIn…）
///   -landscape                           請系統轉成橫的（iPad 收銀台的樣子）
///   -serviceMode <模式>、-workstation <崗位>   UserDefaults 的參數網域會直接蓋過這台的設定
enum LaunchArguments {
    static func value(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.hasPrefix("-") ? nil : v
    }

    static func has(_ key: String) -> Bool { ProcessInfo.processInfo.arguments.contains(key) }
}

extension POSModel {
    /// 鎖定畫面出現後呼叫：照參數自動登入、打開某一頁
    func applyLaunchArguments() {
        #if DEBUG
        if phase == .locked, let pin = LaunchArguments.value("-autologin"), let s = Staff.match(pin: pin, in: staff) {
            login(s)
        }
        if phase == .ready, let raw = LaunchArguments.value("-section"), let s = AppSection(rawValue: raw) {
            go(s)
        }
        #endif
    }

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
