import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 門市掃碼付：掃客人手機上的付款碼，經後台交給 StudioX Pay（POSSync/WalletPayAPI.swift）。
// 這裡是「正在進行的那一筆」（結帳畫面上那張卡：Payment/WalletPaySheet.swift）與「送出去還不知道結果的」（存在這台）；
// 流程在 POSModel+WalletPay.swift。

/// 送出去、還不知道結果的掃碼付：存在這台（App 當掉、斷線、店員先關掉卡都查得回來）。
/// 不存付款碼：之後一律「只查」（同一個付款 id、不帶付款碼），不會再扣一次款
nonisolated struct WalletPending: Codable, Hashable, Identifiable, Sendable {
    /// POS 的付款 id：後台的冪等鍵，收到了就是記帳時的 Payment.id（不會記兩次）
    var paymentId: String
    var ticketId: String
    var ticketNumber: String
    var tender: Tender
    /// line_pay、jko_pay…
    var method: String
    var amount: Money
    /// StudioX Pay 的付款 id（後台回了才有）
    var intentId: String?
    var staffId: String
    var shiftId: String?
    var startedAt: Date
    /// 錢包最多查到什麼時候（後台給的）
    var pollUntil: Date?

    var id: String { paymentId }

    /// 掃碼的請求（code nil＝只查）
    func request(code: String?) -> WalletScanRequest {
        WalletScanRequest(paymentId: paymentId, ticketId: ticketId, amount: amount, method: method, code: code, staffId: staffId)
    }
}

/// 掃碼付：正在進行的那一筆、還不知道結果的
@Observable
final class WalletPayHub {
    /// 正在進行的那一筆（結帳畫面上那張卡）
    var session: WalletPaySession?
    /// 送出去、還不知道結果的（這台）
    private(set) var pending: [WalletPending] = []
    /// 背景正在查（不重複查）
    @ObservationIgnored var checking = false
    /// 退款沒送到（不知道退了沒有）時留著同一個退款 id：再按一次退款用同一筆，不會退兩次
    @ObservationIgnored var refundIds: [String: String] = [:]
    /// 示範店不存（換一家示範、回到真的店都不會帶過去）
    @ObservationIgnored private var persists = false

    private static let key = "walletPending"

    /// 開一家店（真的店讀這台存的；示範店從空的開始）
    func begin(demo: Bool) {
        persists = !demo
        session = nil
        refundIds = [:]
        pending = demo ? [] : Self.load()
    }

    func pendingPayment(for ticketId: String) -> WalletPending? { pending.first { $0.ticketId == ticketId } }

    func upsert(_ p: WalletPending) {
        if let i = pending.firstIndex(where: { $0.paymentId == p.paymentId }) { pending[i] = p } else { pending.append(p) }
        save()
    }

    func remove(_ paymentId: String) {
        pending.removeAll { $0.paymentId == paymentId }
        save()
    }

    /// 關掉那張卡（同一筆才關，不會關到下一筆）
    func end(_ s: WalletPaySession) {
        if session === s { session = nil }
    }

    /// 這台不用了（解除配對、被移除）：別家店的不留
    func forget() {
        session?.abort()
        session = nil
        pending = []
        refundIds = [:]
        if persists { UserDefaults.standard.removeObject(forKey: Self.key) }
    }

    private func save() {
        guard persists, let data = try? EventCoding.encoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private static func load() -> [WalletPending] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? EventCoding.decoder().decode([WalletPending].self, from: data)) ?? []
    }
}

/// 卡上的按鈕：再掃一次、再查一次、先關掉之後再查、取消、關掉
enum WalletChoice: Hashable {
    case retry, recheck, later, cancel, close
}

struct WalletButton: Identifiable, Hashable {
    let choice: WalletChoice
    let title: String
    var prominent = false
    var id: WalletChoice { choice }
}

/// 正在進行的那一筆：掃碼 → 送出 → 等錢包 → 結果（WalletPaySheet 看它）
@Observable
final class WalletPaySession: Identifiable {
    enum Phase: Equatable {
        /// 等掃客人的付款碼（相機或條碼機）
        case scanning
        /// 送出去了，等錢包回覆
        case charging
        /// 錢包在處理（客人在手機上確認…）：每 3 秒查一次
        case waiting(String)
        /// 查這一筆的結果（App 重開、先關掉之後）
        case checking
        /// 按了取消：等回覆
        case cancelling
        case approved(String)
        /// 沒有扣款（標題、說明）
        case failed(String, String)
        /// 還不知道有沒有扣款（標題、說明）
        case unknown(String, String)

        var isWorking: Bool {
            switch self {
            case .charging, .waiting, .checking, .cancelling: true
            default: false
            }
        }
    }

    let id = UUID()
    let ticketId: String
    let ticketNumber: String
    let tender: Tender
    let amount: Money
    var phase: Phase = .scanning
    var buttons: [WalletButton] = []
    /// 卡上的小字（「錢包正在處理，現在不能取消」「連線不穩，繼續確認」）
    var note: String?
    /// 掃到的不是付款碼
    var scanHint: String?
    /// 現在這一筆的付款 id（背景查的時候跳過它）
    var paymentId: String?
    /// 錢包正在處理、取消不了：卡上換成「先關掉，之後再查」
    var cancelRefused = false

    @ObservationIgnored private var codeWaiter: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var choiceWaiter: CheckedContinuation<WalletChoice, Never>?
    /// 等的時候按的（流程下一次醒來時處理）
    @ObservationIgnored private var pressed: WalletChoice?
    /// 卡被關掉了（鎖定、離開結帳畫面）：流程停下來（還不知道結果的留著，背景查）
    @ObservationIgnored private(set) var aborted = false

    init(ticketId: String, ticketNumber: String, tender: Tender, amount: Money) {
        self.ticketId = ticketId
        self.ticketNumber = ticketNumber
        self.tender = tender
        self.amount = amount
    }

    /// 等掃到付款碼；nil＝店員關掉了
    func waitForCode() async -> String? {
        if aborted { return nil }
        phase = .scanning
        buttons = []
        note = nil
        cancelRefused = false
        pressed = nil
        return await withCheckedContinuation { c in codeWaiter = c }
    }

    /// 掃到了（相機、條碼機、手打）
    func submit(_ code: String) {
        guard let w = codeWaiter else { return }
        codeWaiter = nil
        w.resume(returning: code)
    }

    /// 停下來問店員
    func ask(_ phase: Phase, buttons: [WalletButton]) async -> WalletChoice {
        if aborted { return .close }
        self.phase = phase
        self.buttons = buttons
        return await withCheckedContinuation { c in choiceWaiter = c }
    }

    /// 不停下來：換狀態、按鈕（按了記著，流程醒來時處理）
    func show(_ phase: Phase, buttons: [WalletButton] = []) {
        self.phase = phase
        self.buttons = buttons
    }

    /// 按鈕：有在問就回答；沒有就記著
    func press(_ choice: WalletChoice) {
        if let w = choiceWaiter {
            choiceWaiter = nil
            buttons = []
            w.resume(returning: choice)
            return
        }
        pressed = choice
    }

    func takePressed() -> WalletChoice? {
        defer { pressed = nil }
        return pressed
    }

    /// 等幾秒再查（按了按鈕、卡被關掉就提早回來）
    func pause(_ seconds: Double) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, pressed == nil, !aborted {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 卡被關掉：卡著的地方都放開
    func abort() {
        aborted = true
        if let w = codeWaiter {
            codeWaiter = nil
            w.resume(returning: nil)
        }
        if let w = choiceWaiter {
            choiceWaiter = nil
            w.resume(returning: .close)
        }
    }
}
