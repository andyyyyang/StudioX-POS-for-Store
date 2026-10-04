import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側固定鍵盤現在在做什麼。
///
/// 整個 App 只有這一個數字鍵盤，永遠在畫面最右邊、一樣的大小、一樣的鍵位：
/// - 有人要數字（數量、收現金、PIN、統編…）：`await keypad.ask(spec)`，鍵盤換成那個題目，打完按確認才回傳
/// - 沒人要數字（待機）：打的數字當「數量」——打 3 再點珍奶＝3 杯；或打品號按「品號」直接加
///
/// 不用系統鍵盤：系統鍵盤會蓋住單子、位置會跳、還會被誤觸成中文輸入。
@Observable
final class KeypadController {
    struct Request: Identifiable {
        let id = UUID()
        var spec: KeypadSpec
        var entry: KeypadEntry
        var error: String?
        /// 按確認時再檢查一次（PIN 對不對、退款有沒有超過）；回字串＝不行，留在鍵盤上
        var validate: (KeypadEntry) -> String?
        /// PIN 這類打錯要清掉重打
        var clearsOnError: Bool
        var continuation: CheckedContinuation<KeypadEntry?, Never>
    }

    private(set) var request: Request?

    /// 待機時打的數字
    private(set) var idle = KeypadEntry(KeypadSpec(kind: .code(minLength: 1, maxLength: 13), title: "數量"))

    /// 觸覺回饋的觸發器
    private(set) var keyTick = 0
    private(set) var errorTick = 0
    private(set) var successTick = 0

    var isAsking: Bool { request != nil }

    /// 問一個數字。cancel、或被下一個問題取代時回 nil
    func ask(_ spec: KeypadSpec, error: String? = nil, clearsOnError: Bool = false,
             validate: @escaping (KeypadEntry) -> String? = { _ in nil }) async -> KeypadEntry? {
        cancel()
        return await withCheckedContinuation { c in
            request = Request(spec: spec, entry: KeypadEntry(spec), error: error, validate: validate, clearsOnError: clearsOnError, continuation: c)
            if error != nil { errorTick += 1 }
        }
    }

    /// 問一個整數（數量、人數、張數）
    func askNumber(_ spec: KeypadSpec, validate: @escaping (Int) -> String? = { _ in nil }) async -> Int? {
        let e = await ask(spec) { e in validate(e.value ?? 0) }
        return e?.value
    }

    /// 問一個金額
    func askMoney(_ spec: KeypadSpec) async -> Money? {
        await ask(spec)?.money
    }

    func press(_ key: KeypadKey) {
        keyTick += 1
        if var r = request {
            r.entry.press(key)
            r.error = nil
            request = r
        } else {
            idle.press(key)
        }
    }

    func apply(_ quick: KeypadSpec.QuickKey) {
        keyTick += 1
        guard var r = request else { return }
        r.entry.apply(quick)
        r.error = nil
        request = r
        if quick.commits { commit() }
    }

    /// 打字機（外接鍵盤、條碼掃描器）
    func type(_ text: String) {
        for ch in text {
            if let n = ch.wholeNumberValue { press(.digit(n)) }
        }
    }

    func commit() {
        guard var r = request else { return }
        if let problem = r.entry.problem {
            fail(problem, clear: false)
            return
        }
        if let problem = r.validate(r.entry) {
            if r.clearsOnError { r.entry.press(.clear) }
            r.error = problem
            request = r
            errorTick += 1
            return
        }
        request = nil
        successTick += 1
        r.continuation.resume(returning: r.entry)
    }

    func cancel() {
        guard let r = request else { return }
        request = nil
        r.continuation.resume(returning: nil)
    }

    /// 在鍵盤上顯示錯誤（例如查不到會員），不關掉
    func fail(_ message: String, clear: Bool) {
        guard var r = request else { return }
        if clear { r.entry.press(.clear) }
        r.error = message
        request = r
        errorTick += 1
    }

    // MARK: 待機

    /// 待機打的數量（沒打是 nil）
    var multiplier: Int? {
        guard let v = idle.value, v > 0 else { return nil }
        return min(v, 999)
    }

    /// 點品項時拿走數量（沒打就是 1），鍵盤歸零
    func takeQuantity() -> Int {
        let q = multiplier ?? 1
        idle.press(.clear)
        return q
    }

    /// 待機打的品號／條碼
    func takeCode() -> String? {
        let code = idle.digits
        idle.press(.clear)
        return code.isEmpty ? nil : code
    }

    func clearIdle() { idle.press(.clear) }
}
