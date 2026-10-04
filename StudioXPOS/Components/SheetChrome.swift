import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 所有 sheet 長一樣：手機從下面拉上來（把手、大圓角、和頁面同一個底色、標題列）；iPad 是置中的表單大小。
///
///   ━━━━                    把手（系統的）
///   列印預覽              ×   標題（19 點）＋ 說明 ＋ 關掉
///   交易明細・A023
///   ─────────────────────
///   內容（自己捲）
struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var closeLabel = "關掉"
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brand(19, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let close {
                Button(action: close) {
                    HeroIcon("x-mark", size: 15)
                }
                .buttonStyle(SquareIconButtonStyle(size: 34))
                .accessibilityLabel(closeLabel)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        // 系統的把手在最上面約 5 點、高 5 點：標題離它一段，不擠在一起
        .padding(.top, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// sheet 的外觀（放在 sheet 內容的最外層）：把手、圓角、底色；iPad 用表單大小（不會撐滿整個螢幕）
    func posSheet(_ detents: Set<PresentationDetent> = [.large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(Theme.sheet)
            .presentationSizing(.form)
    }
}
