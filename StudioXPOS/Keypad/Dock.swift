import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 左邊選、右邊做（docs/DESIGN.md）：
//
//   工作區只負責看與選；選起來的那一筆，所有動作都在右邊那一欄——和數字鍵在一起。
//
//   ┌ 右欄 ───────────────┐
//   │ 桌位            ×   │  選起來的那一筆（.dockSelection）
//   │ A2・4 位            │
//   │ [換桌]  [併桌]      │  它的動作：和數字鍵同一種鍵
//   │ [印結帳單][作廢]    │
//   │ 人數          ×     │  題目與大字：要打數字時才出現，緊貼在鍵的上面（選起來的那一筆照樣留在上面）
//   │ 1  2  3             │
//   │ …                   │  鍵位永遠一樣
//   │ [      入座      ]  │  最下面那顆大鍵＝下一步：問數字時是確認，選了東西時是它的主要動作
//   └─────────────────────┘
//
//   不用打數字的選擇（選桌子、選設計師、退款的選項）：.dockPanel 蓋住整欄；要打數字時讓開（上面留一條面板的標題），打完再回來。

/// 選起來的那一筆：右欄最上面的卡片＋動作鍵；主要動作是鍵盤最下面那顆大鍵
nonisolated struct DockSelection {
    var id: String
    /// 小字：桌位、訂位、會員、這一行
    var kind: String
    var title: String
    var detail: String?
    var badge: DockBadge?
    var primary: POSAction?
    /// 主要動作用品牌橘（結帳、入座、好了）；平常的用墨色
    var accent: Bool
    /// 其他動作：兩欄的動作鍵；危險的（destructive）自動排到最後
    var actions: [POSAction]
    /// 卡片下面的一小塊資訊（單子的幾行、會員的餘額…），少用
    var extra: AnyView?
    /// 手機上用小的卡片（單子 sheet 裡選了一行：下面的卡片不能把單子擠掉）。iPad 的右欄不管這個
    var compact: Bool
    /// 取消選取（右上的 ×）。nil＝這一頁沒選東西時的動作（例如「新增訂位」），沒有卡片、只有動作鍵
    var clear: (@MainActor () -> Void)?

    init(id: String, kind: String, title: String, detail: String? = nil, badge: DockBadge? = nil,
         primary: POSAction? = nil, accent: Bool = true, actions: [POSAction] = [], extra: AnyView? = nil,
         compact: Bool = false, clear: (@MainActor () -> Void)?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.badge = badge
        self.primary = primary
        self.accent = accent
        self.actions = actions
        self.extra = extra
        self.compact = compact
        self.clear = clear
    }

    /// 這一頁沒選東西時的動作（「新增訂位」「新增會員」）：沒有卡片，只有動作鍵與最下面的大鍵
    static func page(_ id: String, primary: POSAction? = nil, accent: Bool = false, actions: [POSAction] = []) -> DockSelection {
        DockSelection(id: "page-\(id)", kind: "", title: "", primary: primary, accent: accent, actions: actions, clear: nil)
    }

    /// 選起來的一筆比這一頁的動作優先
    var isItem: Bool { clear != nil }
}

nonisolated struct DockBadge {
    var text: String
    var tone: Tone

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

/// 蓋住整個右欄的面板（不用打數字的選擇）
nonisolated struct DockPanelItem {
    let id: String
    let title: String
    let subtitle: String?
    let content: AnyView
    let close: @MainActor () -> Void
}

/// 右欄要放的東西（畫面一層一層往上交給 MainShell）
nonisolated struct DockContent {
    var selection: DockSelection?
    var panel: DockPanelItem?

    init(selection: DockSelection? = nil, panel: DockPanelItem? = nil) {
        self.selection = selection
        self.panel = panel
    }

    /// 兩個都有時選哪一個：選起來的一筆勝過這一頁的動作；一樣的話用 b（裡面的、後面的）
    static func pick(_ a: DockSelection?, _ b: DockSelection?) -> DockSelection? {
        guard let a else { return b }
        guard let b else { return a }
        return a.isItem && !b.isItem ? a : b
    }
}

nonisolated struct DockKey: PreferenceKey {
    static var defaultValue: DockContent { DockContent() }

    /// 並排的：後面的優先（單子欄在工作區後面：選了單子裡的一行，勝過工作區選的單）
    static func reduce(value: inout DockContent, nextValue: () -> DockContent) {
        let next = nextValue()
        value.selection = DockContent.pick(value.selection, next.selection)
        if let p = next.panel { value.panel = p }
    }
}

extension View {
    /// 選起來的那一筆（或這一頁沒選東西時的動作）交給右欄；nil＝沒有
    func dockSelection(_ selection: DockSelection?) -> some View {
        transformPreference(DockKey.self) { value in
            // 裡面的（比較具體的）優先
            value.selection = DockContent.pick(selection, value.selection)
        }
    }

    /// 不用打數字的視窗蓋住右欄（選桌子、選設計師…）；要打數字時自動讓開，打完再回來
    func dockPanel<Content: View>(isPresented: Binding<Bool>, title: String, subtitle: String? = nil,
                                  @ViewBuilder content: () -> Content) -> some View {
        let item: DockPanelItem? = isPresented.wrappedValue
            ? DockPanelItem(id: title, title: title, subtitle: subtitle, content: AnyView(content()),
                            close: { isPresented.wrappedValue = false })
            : nil
        return transformPreference(DockKey.self) { value in
            if let item, value.panel == nil { value.panel = item }
        }
    }

    /// 選了某一筆才打開；關掉＝把 item 設成 nil
    func dockPanel<Item: Identifiable, Content: View>(item: Binding<Item?>, title: (Item) -> String, subtitle: ((Item) -> String?)? = nil,
                                                      @ViewBuilder content: (Item) -> Content) -> some View {
        let panel: DockPanelItem? = item.wrappedValue.map { it in
            DockPanelItem(id: "\(title(it))-\(it.id)", title: title(it), subtitle: subtitle?(it), content: AnyView(content(it)),
                          close: { item.wrappedValue = nil })
        }
        return transformPreference(DockKey.self) { value in
            if let panel, value.panel == nil { value.panel = panel }
        }
    }
}

// MARK: - 右欄上面：選起來的那一筆

struct DockSelectionView: View {
    let selection: DockSelection
    /// 右欄有面板蓋著時不要搶 Esc
    var takesEscape = true
    /// 小的卡片（手機的鍵盤 sheet：上面的空間只夠兩行）
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            if selection.isItem {
                if compact {
                    DockSelectionHeader(selection: selection, showsClear: true)
                } else {
                    card
                }
            }
            DockActionKeys(actions: selection.actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Eyebrow(selection.kind, color: Theme.muted)
                if let b = selection.badge { StatusBadge(b.text, tone: b.tone) }
                Spacer(minLength: 8)
                if let clear = selection.clear {
                    Button(action: clear) {
                        HeroIcon("x-mark", size: 15)
                    }
                    .buttonStyle(SquareIconButtonStyle(size: 32))
                    .accessibilityLabel("取消選取")
                    .modifier(EscapeShortcut(enabled: takesEscape))
                }
            }
            Text(selection.title)
                .font(.brand(24, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            if let d = selection.detail {
                Text(d)
                    .textRole(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let extra = selection.extra {
                extra.padding(.top, 6)
            }
        }
        .id(selection.id)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

/// 問數字時，上面留著選起來的那一筆（小小的一張）：一看就知道這個數字是給誰的（「這一行・拿鐵・×2・NT$240」）
struct DockSelectionHeader: View {
    let selection: DockSelection
    /// 右上的 ×（手機的鍵盤 sheet 裡，選起來那一行的數量：× 取消選取）
    var showsClear = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Eyebrow(selection.kind, color: Theme.muted)
                    if let b = selection.badge { StatusBadge(b.text, tone: b.tone) }
                }
                Text(selection.title)
                    .font(.brand(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = selection.detail {
                    Text(d)
                        .font(.brand(12.5, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if showsClear, let clear = selection.clear {
                Button(action: clear) {
                    HeroIcon("x-mark", size: 14)
                }
                .buttonStyle(SquareIconButtonStyle(size: 30))
                .accessibilityLabel("取消選取")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.line) }
        .accessibilityElement(children: .contain)
    }
}

/// 面板裡的選擇要打數字（退款金額、自訂折扣）：面板讓開給鍵盤，上面留一條面板的標題，打完面板再回來
struct DockPanelStrip: View {
    let item: DockPanelItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(item.title, color: Theme.ink2)
            if let s = item.subtitle {
                Text(s)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(Theme.line) }
        .accessibilityElement(children: .combine)
    }
}

private struct EscapeShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut(.cancelAction) } else { content }
    }
}

/// 動作鍵：兩欄、和數字鍵同一種鍵；危險的排最後、紅字
///
/// 用一般的 Grid、不用 LazyVGrid：動作頂多十來個，不需要懶載入；而且 iOS 26 在 ViewThatFits 量 LazyVGrid 的大小時
/// 會在主執行緒以外叫 ForEach 的內容，Swift 6 的隔離檢查會讓 App 直接結束（手機上選起一行時發生過）
struct DockActionKeys: View {
    let actions: [POSAction]

    var body: some View {
        let ordered = actions.filter { !$0.isDestructive } + actions.filter(\.isDestructive)
        if !ordered.isEmpty {
            let rows = stride(from: 0, to: ordered.count, by: 2).map { Array(ordered[$0 ..< min($0 + 2, ordered.count)]) }
            // 兩欄一樣寬；三顆以上時落單的那一顆照樣半欄寬，旁邊空著。整頁只有一顆就佔滿整排（直的 iPad 右欄窄，
            // 半欄放不下「現場客（直接開單）」會斷成兩行）
            // （以前用 Grid＋不佔大小的空格：整頁只有一顆動作鍵時那一欄縮成只剩圖示，例如設定的「重新抓設定」）
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 8) {
                        ForEach(rows[r].indices, id: \.self) { i in
                            key(rows[r][i])
                        }
                        if rows[r].count == 1 && ordered.count > 1 {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private func key(_ a: POSAction) -> some View {
        Button(action: a.perform) {
            HStack(spacing: 7) {
                if let icon = a.icon { HeroIcon(icon, size: 16) }
                Text(a.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
            }
            .font(.brand(14.5, .medium))
            .foregroundStyle(a.isDestructive ? Theme.dangerFG : Theme.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .buttonStyle(KeyStyle())
        .disabled(!a.isEnabled)
        .opacity(a.isEnabled ? 1 : 0.4)
    }
}

// MARK: - 蓋住右欄的面板

/// 面板的外框：和右側鍵盤同一個底色、同樣的邊距；左上標題、右上關掉。
/// 手機（inSheet）：在 sheet 裡，沒有左邊的分隔線；標題大一點、緊貼在拖曳的橫條下面，內容捲到底也避開下面的橫條
struct DockPanelChrome: View {
    let item: DockPanelItem
    var inSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inSheet { sheetTitle } else { dockTitle }
            ScrollView {
                item.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, inSheet ? 20 : 0, for: .scrollContent)
        }
        .padding(.horizontal, 20)
        .padding(.top, inSheet ? 22 : 20)
        .padding(.bottom, inSheet ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.dock.ignoresSafeArea())
        .overlay(alignment: .leading) {
            if !inSheet { Rule(vertical: true).ignoresSafeArea() }
        }
    }

    private var dockTitle: some View {
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
            closeButton(size: 34)
        }
        .padding(.bottom, 18)
    }

    /// 手機：「整張單的折扣」大字標題＋小字，右邊一顆圓的關掉
    private var sheetTitle: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.brand(19, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let s = item.subtitle {
                    Text(s)
                        .font(.brand(13.5, .regular))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: item.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 30, height: 30)
                    .background(Theme.key, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關掉")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.bottom, 16)
    }

    private func closeButton(size: CGFloat) -> some View {
        Button(action: item.close) {
            HeroIcon("x-mark", size: 16)
        }
        .buttonStyle(SquareIconButtonStyle(size: size))
        .accessibilityLabel("關掉")
        .keyboardShortcut(.cancelAction)
    }
}

/// 面板裡的一個選項（選桌子、選設計師）：整列可以點，和動作鍵同一種鍵
struct DockChoice: View {
    let title: String
    var detail: String?
    var trailing: String?
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(selected ? Theme.accentText : Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let detail {
                        Text(detail)
                            .font(.brand(12.5, .regular))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.brand(13.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(KeyStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
