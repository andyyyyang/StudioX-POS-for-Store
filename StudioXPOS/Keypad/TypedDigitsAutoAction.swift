import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側鍵盤待機時打的數字：打完停 0.8 秒沒有再打，就照它是什麼自動做（會員電話掛上會員、結帳中的統編、剛好對到的品號）。
/// 繼續打、按了「品號」或 C，等的那一下就取消。看不見（放在右欄的背景）
struct TypedDigitsAutoAction: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task(id: keypad.idle.digits) {
                let digits = keypad.idle.digits
                guard !digits.isEmpty, !keypad.isAsking, model.typedDigits(digits)?.actsOnPause == true else { return }
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, keypad.idle.digits == digits, !keypad.isAsking else { return }
                await model.actOnTyped(digits)
            }
    }
}
