import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// iPhone：店員手上的點餐機。點好的單和 iPad 是同一份事件（同一個 Wi-Fi 直接同步，不然經過後台），
/// 客人到結帳櫃台（iPad）一起結：統一結帳（POSModel+Handoff）。
///
///   - 崗位：手機一律是「前場點餐」（後台設成後廚、出餐口的照舊：廚房的人也可以拿手機看單）
///   - 收錢：預設不收，單子「送到結帳櫃台」；「更多 → 這支手機」打開「也能收款」才有結帳（刷卡、電子支付；沒有錢櫃、不收現金）
///   - 畫面：PhoneShell（上面選、下面做），iPad 的 MainShell 不變
extension POSModel {
    /// 這台是 iPhone
    var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// 手機的崗位：前場點餐；後台（或店長在這台）設成後廚、出餐口的照舊
    func phoneRole(_ r: DeviceRole) -> DeviceRole {
        guard isPhone, !r.isKitchen else { return r }
        return .handheld
    }

    /// 這台現在能不能收錢（結帳、退款）：崗位會收錢；手機另外要打開「這支手機也能收款」
    var takesPayment: Bool {
        role.takesPayment && (!isPhone || PhoneSettings.shared.takesPayment)
    }

    /// 現金模式現在有沒有效：設定打開、而且這台會收錢——有錢櫃的收銀台 iPad，或打開「這支手機也能收款」的手機
    /// （手機沒有電子錢櫃：錢收在自己的錢箱；點餐頁下面常駐鍵盤 PhoneCashPad）。點餐 iPad、接待照平常
    var cashModeActive: Bool {
        settings.cashMode && takesPayment && (isPhone || role.hasDrawer)
    }

    /// 手機要和櫃台的 iPad（母裝置）在同一個 Wi-Fi 才能進結帳：區網連得到一台 iPad。
    /// 店家沒開區網同步（後台的 mesh）就不限；示範模式不限
    var phoneOnStoreWiFi: Bool {
        guard isPhone, !isDemo, meshConfig?.enabled == true else { return true }
        return mesh.hasPadPeer
    }

    /// 要不要發票號碼段：會收錢的才要（不收款的手機不佔號碼）
    var issuesInvoices: Bool { takesPayment }

    /// 有「印結帳單」：iPad 照舊（沒設定出單機時印到「最近列印」）；手機要有收據出單機才有（不然「送到結帳櫃台」就好）
    var canPrintBill: Bool { !isPhone || !printers.targets(.receipt).isEmpty }

    /// 「這支手機也能收款」：打開要店長授權（收了錢要開發票、對帳）；關掉不用
    func setPhoneTakesPayment(_ on: Bool) async {
        guard on != PhoneSettings.shared.takesPayment else { return }
        if on {
            guard role.takesPayment else {
                show("這支手機是「\(role.label)」，不能收款", tone: .warning)
                return
            }
            guard await authorize(.manageDevice, detail: "讓這支手機也能收款") != nil else { return }
        }
        PhoneSettings.shared.takesPayment = on
        if on {
            show("這支手機也能收款了：刷卡、電子支付（現金請到結帳櫃台）", tone: .info)
            await topUpInvoiceRolls()
        } else {
            show("這支手機不收款：點好的單送到結帳櫃台結", tone: .info)
        }
    }

    // MARK: 手機下面那一排

    /// 手機的分頁（照這台看得到的頁）：點餐、桌位、訂單、叫號；後廚、出餐口的手機是廚房、訂單。最後一格固定是「更多」。
    /// 叫號照 visibleSections：前場點餐（.handheld）的崗位要看得到 .queue，手機才有這一格
    var phoneTabs: [AppSection] {
        [.order, .floor, .kitchen, .orders, .queue].filter { visibleSections.contains($0) }
    }

    /// 收在「更多」裡的頁（會員、這支手機的設定）
    var phoneMoreSections: [AppSection] {
        [.members, .settings].filter { visibleSections.contains($0) }
    }

    /// 手機登入後先看哪一頁：照崗位與營業模式（和 iPad 一樣），手機沒有的頁（預約、報到…）就看點餐
    var phoneHome: AppSection {
        if phoneTabs.contains(home) { return home }
        return phoneTabs.first ?? .settings
    }
}

/// 存在這支手機的偏好（和 LocalSettings 分開：只有手機用）
@Observable
final class PhoneSettings {
    static let shared = PhoneSettings()

    private let d = UserDefaults.standard

    /// 這支手機也能收款（刷卡、電子支付）；預設關：單子送到結帳櫃台
    var takesPayment: Bool { didSet { d.set(takesPayment, forKey: "phoneTakesPayment") } }

    private init() {
        // bool(forKey:)：啟動參數（-phoneTakesPayment YES，截圖用）是字串也認得
        takesPayment = d.object(forKey: "phoneTakesPayment") != nil && d.bool(forKey: "phoneTakesPayment")
    }
}
