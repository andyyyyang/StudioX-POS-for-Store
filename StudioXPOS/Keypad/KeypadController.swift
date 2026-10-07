import Foundation
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
/// - 選了單子的一行：鍵盤直接問那一行的數量（`keepsSelection`：那一行的卡片與動作鍵照樣留在上面）
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
        /// 選起來的那一筆照樣留在上面（卡片＋動作鍵）：點了單子的一行，鍵盤就問那一行的數量。
        /// 這種題目會讓位給別的題目（改價、PIN…）：別人問完，那一行再接著問
        var keepsSelection: Bool
        /// 大鍵的字跟著打的數字變（「數量 2」「改成 3」）；nil＝題目的 confirmLabel
        var confirmTitle: ((KeypadEntry) -> String)?
        /// validate 過了之後還要等的檢查（問後台 PIN 對不對）：等的時候鍵盤留著、按鍵不動、大鍵是「確認中…」；
        /// 回字串＝不行，和 validate 一樣寫在鍵盤上
        var check: (@MainActor (KeypadEntry) async -> String?)?
        var isChecking = false
        var continuation: CheckedContinuation<KeypadEntry?, Never>

        /// 最下面那顆大鍵的字
        var confirmLabel: String { isChecking ? "確認中…" : (confirmTitle?(entry) ?? spec.confirmLabel) }
    }

    private(set) var request: Request?

    /// 待機時打的數字
    private(set) var idle = KeypadEntry(KeypadSpec(kind: .code(minLength: 1, maxLength: 13), title: "數量"))

    /// 觸覺回饋的觸發器
    private(set) var keyTick = 0
    private(set) var errorTick = 0
    private(set) var successTick = 0

    var isAsking: Bool { request != nil }

    /// 正在問的是「選起來那一行的數量」（卡片與動作鍵留在上面）
    var keepsSelection: Bool { request?.keepsSelection == true }

    /// 正在問別的（改價、PIN、人數…）：選起來那一行的數量要先讓開
    var isAskingOther: Bool { request.map { !$0.keepsSelection } ?? false }

    /// 問一個數字。cancel、或被下一個問題取代時回 nil。
    /// keepsSelection：選起來的那一筆（卡片、動作鍵）照樣留在鍵盤上面，見 Request.keepsSelection。
    /// confirmTitle、check 放在 validate 後面：`ask(spec) { e in … }` 的尾隨閉包照舊是 validate
    func ask(_ spec: KeypadSpec, error: String? = nil, clearsOnError: Bool = false, keepsSelection: Bool = false,
             validate: @escaping (KeypadEntry) -> String? = { _ in nil },
             confirmTitle: ((KeypadEntry) -> String)? = nil,
             check: (@MainActor (KeypadEntry) async -> String?)? = nil) async -> KeypadEntry? {
        cancel()
        return await withCheckedContinuation { c in
            request = Request(spec: spec, entry: KeypadEntry(spec), error: error, validate: validate, clearsOnError: clearsOnError,
                              keepsSelection: keepsSelection, confirmTitle: confirmTitle, check: check, continuation: c)
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
        if request?.isChecking == true { return }
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
        guard var r = request, !r.isChecking else { return }
        keyTick += 1
        r.entry.apply(quick)
        r.error = nil
        request = r
        if quick.commits { commit() }
    }

    /// 正在問會員的電話（找會員、會員頁、報到）：掃會員卡的相機、條碼機掃到的網址可以直接填
    var isAskingMemberPhone: Bool {
        guard let r = request, !r.keepsSelection else { return false }
        return r.spec.kind == .phone || r.spec.title == "會員"
    }

    /// 換成這串數字並確認（掃到的會員卡）：和打完按「查詢」一樣
    func fill(_ digits: String) {
        guard var r = request, !r.isChecking else { return }
        r.entry.press(.clear)
        for ch in digits {
            if let n = ch.wholeNumberValue { r.entry.press(.digit(n)) }
        }
        r.error = nil
        request = r
        commit()
    }

    /// 打字機（外接鍵盤、條碼掃描器）
    func type(_ text: String) {
        for ch in text {
            if let n = ch.wholeNumberValue { press(.digit(n)) }
        }
    }

    func commit() {
        guard var r = request, !r.isChecking else { return }
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
        if let check = r.check {
            // 等檢查（問後台）：鍵盤留著；取消了、換了別的題目就不管結果
            r.isChecking = true
            r.error = nil
            request = r
            let id = r.id
            let entry = r.entry
            Task {
                let problem = await check(entry)
                guard var now = self.request, now.id == id else { return }
                now.isChecking = false
                self.request = now
                if let problem {
                    self.fail(problem, clear: now.clearsOnError)
                } else {
                    self.finish(now)
                }
            }
            return
        }
        finish(r)
    }

    private func finish(_ r: Request) {
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

    /// 待機打的數字可不可以當數量（現金模式打的是金額：POSModel 設）
    @ObservationIgnored var digitsAreQuantity: () -> Bool = { true }

    /// 待機打的數量（沒打是 nil）。四碼以上是品號，不當數量
    var multiplier: Int? {
        guard digitsAreQuantity(), idle.digits.count <= 3, let v = idle.value, v > 0 else { return nil }
        return v
    }

    /// 點品項時拿走數量（沒打就是 1），鍵盤歸零；打的不是數量（現金模式的金額）就是 1、打的留著
    func takeQuantity() -> Int {
        guard digitsAreQuantity() else { return 1 }
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
