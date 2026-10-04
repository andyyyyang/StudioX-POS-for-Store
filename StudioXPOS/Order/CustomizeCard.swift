import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// iPad 點餐：要選甜度、加料、規格的品項，在菜單上浮一張卡——從下面上來、高度跟著內容（最多到這一區的三分之二），
/// 上面的菜單還看得到。點卡外面或右上的 ×＝不加了；「加入」、數量照樣在右欄（左邊選、右邊做）
struct CustomizeCard<Content: View>: View {
    let maxHeight: CGFloat
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: 820)
            .frame(maxHeight: maxHeight)
            .background(Theme.sheet)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    HeroIcon("x-mark", size: 15)
                }
                .buttonStyle(SquareIconButtonStyle(size: 34))
                .accessibilityLabel("不加了")
                .padding(16)
            }
            .shadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
    }
}
