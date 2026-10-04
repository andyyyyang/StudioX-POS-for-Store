import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 右邊那一欄的面板：不用打數字的視窗（入座選桌、選服務、退款換貨的選項…）直接蓋在右側鍵盤上，
// 左邊的工作區保持完整。要打數字的時候（人數、電話、數量）面板自動讓開、鍵盤滑回來，打完再回到面板——面板裡的狀態都還在。
//
//   某一頁：.dockPanel(isPresented: $seating, title: "入座") { 選桌子… }
//   MainShell：把最裡面那一個面板疊在鍵盤那一欄上（見 MainShell 的 overlayPreferenceValue）

/// 一個要放進右邊那一欄的面板
nonisolated struct DockPanelItem {
    let id: String
    let title: String
    let subtitle: String?
    let content: AnyView
    let close: @MainActor () -> Void
}

nonisolated struct DockPanelKey: PreferenceKey {
    static var defaultValue: DockPanelItem? { nil }

    /// 並排的好幾個：後面那一個
    static func reduce(value: inout DockPanelItem?, nextValue: () -> DockPanelItem?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// 不用打數字的視窗放到右邊那一欄（蓋住鍵盤；要打數字時自動讓開）
    func dockPanel<Content: View>(isPresented: Binding<Bool>, title: String, subtitle: String? = nil,
                                  @ViewBuilder content: () -> Content) -> some View {
        let item: DockPanelItem? = isPresented.wrappedValue
            ? DockPanelItem(id: title, title: title, subtitle: subtitle, content: AnyView(content()),
                            close: { isPresented.wrappedValue = false })
            : nil
        // 沒打開的時候不要蓋掉裡面的面板；裡外都打開時裡面的（比較具體的）優先
        return transformPreference(DockPanelKey.self) { value in
            if let item, value == nil { value = item }
        }
    }

    /// 選了某一筆才打開（訂位、會員…）；關掉＝把 item 設成 nil
    func dockPanel<Item: Identifiable, Content: View>(item: Binding<Item?>, title: (Item) -> String, subtitle: ((Item) -> String?)? = nil,
                                                      @ViewBuilder content: (Item) -> Content) -> some View {
        let panel: DockPanelItem? = item.wrappedValue.map { it in
            DockPanelItem(id: "\(title(it))-\(it.id)", title: title(it), subtitle: subtitle?(it), content: AnyView(content(it)),
                          close: { item.wrappedValue = nil })
        }
        return transformPreference(DockPanelKey.self) { value in
            if let panel, value == nil { value = panel }
        }
    }
}

/// MainShell 放在右側鍵盤那一欄上：有面板而且鍵盤沒在問數字時才出現（從右邊滑進來）
struct DockPanelHost: View {
    let item: DockPanelItem?
    let asking: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if let item, !asking {
                DockPanelChrome(item: item)
                    .id(item.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.spring, value: item?.id)
        .animation(Motion.spring, value: asking)
    }
}

/// 面板的外框：和右側鍵盤同一個底色、同樣的邊距；左上標題、右上關掉
struct DockPanelChrome: View {
    let item: DockPanelItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(item.title, color: Theme.ink2)
                    if let s = item.subtitle {
                        Text(s)
                            .textRole(.small)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(action: item.close) {
                    HeroIcon("x-mark", size: 16)
                }
                .buttonStyle(SquareIconButtonStyle(size: 34))
                .accessibilityLabel("關掉")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 18)
            ScrollView {
                item.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.dock.ignoresSafeArea())
        .overlay(alignment: .leading) { Rule(vertical: true).ignoresSafeArea() }
        .shadow(color: .black.opacity(0.22), radius: 26, x: -8)
    }
}
