import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 操作的層級（全 App 共用，見 docs/DESIGN.md「按鈕」）：
//
//   一個地方只有一個最明顯的動作（主要：實心）；常用的最多再露兩個（次要：細框）；其他收進「⋯」。
//   清單、卡片上不要每一列都擺一排按鈕：點一下選起來，動作出現在同一個固定的地方（動作列、卡片旁邊的面板）。

/// 一個動作：按鈕的字、圖示（Heroicons 的名字）、做什麼
struct POSAction: Identifiable {
    var id: String { title }
    var title: String
    var icon: String?
    var isDestructive: Bool
    var isEnabled: Bool
    var perform: () -> Void

    init(_ title: String, icon: String? = nil, destructive: Bool = false, enabled: Bool = true, perform: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = destructive
        self.isEnabled = enabled
        self.perform = perform
    }
}

/// 動作列：「⋯」｜次要（最多兩個）｜主要。次要多給的自動收進「⋯」
struct ActionBar: View {
    var primary: POSAction?
    var secondary: [POSAction] = []
    var more: [POSAction] = []
    var size: BrandButtonStyle.Size = .md
    /// 主要動作用品牌橘（一個畫面最多一個：結帳、確認）
    var accent = false
    /// 主要動作撐滿剩下的寬度
    var fillPrimary = true

    var body: some View {
        HStack(spacing: 10) {
            if !overflow.isEmpty {
                MoreMenu(actions: overflow, size: size)
            }
            ForEach(Array(secondary.prefix(2))) { a in
                Button(action: a.perform) { ActionLabel(action: a) }
                    .buttonStyle(.brand(a.isDestructive ? .danger : .ghost, size: size))
                    .disabled(!a.isEnabled)
            }
            if let primary {
                Button(action: primary.perform) { ActionLabel(action: primary) }
                    .buttonStyle(.brand(primary.isDestructive ? .danger : (accent ? .accent : .primary), size: size, fullWidth: fillPrimary))
                    .disabled(!primary.isEnabled)
            }
        }
    }

    private var overflow: [POSAction] { Array(secondary.dropFirst(2)) + more }
}

/// 「⋯」：不常用的動作收在這裡
struct MoreMenu: View {
    var actions: [POSAction]
    var size: BrandButtonStyle.Size = .md
    var label = "更多"

    var body: some View {
        Menu {
            ForEach(actions) { a in
                Button(role: a.isDestructive ? .destructive : nil, action: a.perform) {
                    if let icon = a.icon {
                        Label { Text(a.title) } icon: { Image("hi-\(icon)").renderingMode(.template) }
                    } else {
                        Text(a.title)
                    }
                }
                .disabled(!a.isEnabled)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size == .sm ? 13 : 15, weight: .semibold))
                .frame(width: size.height, height: size.height)
                .foregroundStyle(Theme.ink)
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(Theme.line)
                }
                .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(label)
    }
}

/// 按鈕上的字（有圖示就放在前面）
private struct ActionLabel: View {
    let action: POSAction

    var body: some View {
        HStack(spacing: 8) {
            if let icon = action.icon { HeroIcon(icon, size: 16) }
            Text(action.title)
                .lineLimit(1)
        }
    }
}
