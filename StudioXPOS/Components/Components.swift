import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

// StudioX 的元件：按鈕、圖示、狀態、卡片、細線和 StudioX Console App 的 Components.swift 同一份（照抄，改的話兩邊一起改）；
// 後面是 POS 才有的：頭像、金額、空狀態、提示條。

// MARK: - 按鈕（.btn）

/// 按鈕：墨色實心、方角 5、字重 500、後面一個 →。按下時品牌橘從下往上填滿、箭頭轉 −45°（global.css 的 .btn）
struct BrandButtonStyle: ButtonStyle {
    enum Variant {
        /// 墨色實心（主要動作）
        case primary
        /// 品牌橘實心（一個畫面最多一個：登入、確認執行）
        case accent
        /// 透明＋細框（.btn--ghost）
        case ghost
        /// 只有字
        case quiet
        /// 危險（退款、刪除、取消訂單）
        case danger
    }

    enum Size {
        /// 34（.btn--sm）
        case sm
        /// 44
        case md
        /// 52：頁面底部的主要動作
        case lg

        var height: CGFloat {
            switch self {
            case .sm: 34
            case .md: 44
            case .lg: 52
            }
        }

        var font: CGFloat {
            switch self {
            case .sm: 13.5
            case .md: 15
            case .lg: 16
            }
        }

        var padding: CGFloat {
            switch self {
            case .sm: 12
            case .md: 18
            case .lg: 22
            }
        }
    }

    var variant: Variant = .primary
    var size: Size = .md
    var fullWidth = false
    /// 後面的 →
    var arrow = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: Metric.radiusSm, style: .continuous)
        HStack(spacing: 8) {
            configuration.label
                .labelStyle(BrandLabelStyle())
            if arrow {
                Text("→")
                    .rotationEffect(.degrees(pressed ? -45 : 0))
                    .offset(x: pressed ? 3 : 0)
            }
        }
        .font(.brand(size.font, .medium, relativeTo: .callout))
        .lineLimit(1)
        .padding(.horizontal, size.padding)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: size.height)
        .foregroundStyle(foreground(pressed: pressed))
        .background {
            ZStack {
                background
                // 按下時從下往上填滿（.btn::before）
                if let fill {
                    let up = pressed
                    fill.visualEffect { content, proxy in
                        content.offset(y: up ? 0 : proxy.size.height * 1.01)
                    }
                }
            }
            .clipShape(shape)
        }
        .overlay {
            if let border { shape.strokeBorder(border, lineWidth: 1) }
        }
        .contentShape(.hoverEffect, shape)
        .contentShape(shape)
        .hoverEffect(.highlight)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(pressed ? Motion.fast : Motion.ease, value: pressed)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .primary: Theme.ink
        case .accent: Theme.accent
        case .ghost, .quiet: Color.clear
        case .danger: Theme.dangerFG.opacity(0.08)
        }
    }

    /// 按下時填滿的顏色
    private var fill: Color? {
        switch variant {
        case .primary: Theme.accent
        case .accent: Theme.ink
        case .ghost: Theme.ink
        case .quiet: Theme.press
        case .danger: Theme.dangerFG
        }
    }

    private var border: Color? {
        switch variant {
        case .ghost: Theme.line
        case .danger: Theme.dangerFG.opacity(0.3)
        default: nil
        }
    }

    private func foreground(pressed: Bool) -> Color {
        switch variant {
        case .primary: Theme.page
        case .accent: Theme.onAccent
        case .ghost: pressed ? Theme.page : Theme.ink
        case .quiet: Theme.ink
        case .danger: pressed ? Theme.onAccent : Theme.dangerFG
        }
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static func brand(_ variant: BrandButtonStyle.Variant = .primary, size: BrandButtonStyle.Size = .md, fullWidth: Bool = false, arrow: Bool = false) -> BrandButtonStyle {
        BrandButtonStyle(variant: variant, size: size, fullWidth: fullWidth, arrow: arrow)
    }
}

/// 按鈕裡的圖示＋字
struct BrandLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
            configuration.title
        }
    }
}

/// 方形的圖示鈕（頁首的 44×44 方框、圓角 5）
struct SquareIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Theme.press : .clear, in: .rect(cornerRadius: Metric.radiusSm))
            .overlay { RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(Theme.line, lineWidth: 1) }
            .contentShape(.rect)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - 標籤、篩選、箭頭

// MARK: - 圖示（Heroicons 24 outline，和後台側欄同一套）

/// `HeroIcon("globe-alt")`＝Assets 裡的 hi-globe-alt
struct HeroIcon: View {
    let name: String
    var size: CGFloat = 20

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("hi-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - 狀態（只表示狀態；後台的 StatusBadge 色）

enum Tone: String, Hashable, Sendable {
    /// 品牌橘（強調、待處理的重點）
    case gold
    /// 成功、已完成
    case active
    case danger
    /// 警告、等待中
    case warning
    case info
    case neutral

    var foreground: Color {
        switch self {
        case .gold: Theme.accentText
        case .active: Theme.successFG
        case .danger: Theme.dangerFG
        case .warning: Theme.warningFG
        case .info: Theme.infoFG
        case .neutral: Theme.muted
        }
    }

    var dot: Color {
        switch self {
        case .gold: Theme.accent
        case .active: Theme.live
        default: foreground
        }
    }

    var background: Color {
        switch self {
        case .gold: Theme.accentSoft
        case .active: Theme.successFG.opacity(0.11)
        case .danger: Theme.dangerFG.opacity(0.11)
        case .warning: Theme.warningFG.opacity(0.13)
        case .info: Theme.infoFG.opacity(0.11)
        case .neutral: Theme.press
        }
    }

    /// Xena 卡片的 tone（ok / warn / bad / info / muted）
    init(card: String) {
        switch card {
        case "ok": self = .active
        case "warn": self = .warning
        case "bad": self = .danger
        case "info": self = .info
        default: self = .neutral
        }
    }
}

/// 狀態標籤：小圓點＋字、淡底、方角
struct StatusBadge: View {
    let text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.dot).frame(width: 5, height: 5)
            Text(text)
        }
        .font(.brand(12, .medium, relativeTo: .caption))
        .foregroundStyle(tone.foreground)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.background, in: .rect(cornerRadius: Metric.chip))
    }
}

/// 在線的綠點（會呼吸）
struct LiveDot: View {
    var color: Color = Theme.live
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background {
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(on ? 2.6 : 1)
                    .opacity(on ? 0 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 卡片（.panel）與細線

/// 卡片：細框、圓角 8、上緣淡漸層與一條亮線（global.css 的 .panel）
struct Panel: ViewModifier {
    var padding: CGFloat = 20
    var radius: CGFloat = Metric.radius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(LinearGradient(stops: [.init(color: Theme.panelTop, location: 0), .init(color: Theme.surface, location: 0.6)], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                shape.strokeBorder(Theme.line, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // 上緣的亮線（inset 1px）
                Rectangle()
                    .fill(Theme.panelHighlight)
                    .frame(height: 1)
                    .padding(.horizontal, radius)
                    .padding(.top, 1)
            }
    }
}

extension View {
    /// 一張卡片（列自己有內距的清單用 padding: 0）
    func panel(padding: CGFloat = 20, radius: CGFloat = Metric.radius) -> some View {
        modifier(Panel(padding: padding, radius: radius))
    }

    /// 頁面的底（--bg）
    func brandPage() -> some View {
        background(Theme.page.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            // 導覽容器（NavigationStack、iPad 分欄的每一欄）本身的底也是暖紙色：推頁、分欄之間不會露出系統的黑／白
            .containerBackground(Theme.page, for: .navigation)
    }
}

/// 一條細線（--line）
struct Rule: View {
    var color: Color = Theme.line
    var vertical = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: vertical ? 1 / displayScale : nil, height: vertical ? nil : 1 / displayScale)
            .accessibilityHidden(true)
    }
}


// MARK: - POS

/// 小標（區塊上面那行：「■ 已點」「■ 付款」）：品牌橘的小方塊＋淡色字（Console 的 Eyebrow）
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted

    init(_ text: String, color: Color = Theme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 7) {
            Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(text)
                .font(.brand(12.5, .medium, relativeTo: .caption))
                .tracking(0.25)
                .foregroundStyle(color)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 員工的頭像：名字第一個字、色塊底
struct StaffAvatar: View {
    let name: String
    var swatch: Swatch = .sand
    var size: CGFloat = 28
    var active = false

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.brand(size * 0.44, .semibold))
            .foregroundStyle(Theme.tileInk)
            .frame(width: size, height: size)
            .background(Theme.swatch(swatch), in: .circle)
            .overlay {
                if active { Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3) }
            }
            .accessibilityLabel(name)
    }
}

/// 金額：NT$ 小一號、數字等寬
struct MoneyText: View {
    let money: Money
    var role: TextRole = .number
    var color: Color = Theme.ink
    var showsCurrency = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if money.isNegative { Text("−") }
            if showsCurrency {
                Text("NT$")
                    .font(.brand(TextRole.small.size(regular: true), .medium))
                    .foregroundStyle(color.opacity(0.6))
            }
            Text(Money(cents: abs(money.cents)).plain)
                .textRole(role)
                .contentTransition(.numericText(value: Double(money.cents)))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(money.formatted)
    }
}

/// 沒有東西時（「還沒點餐」「沒有訂位」）
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            HeroIcon(icon, size: 28)
                .foregroundStyle(Theme.faint)
            Text(title)
                .textRole(.h4)
                .foregroundStyle(Theme.ink2)
            if let message {
                Text(message)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 頁面上方的一條提示（離線、衝突、號碼快用完）
struct Banner: View {
    let text: String
    var tone: Tone = .warning
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tone.dot).frame(width: 7, height: 7)
            Text(text)
                .textRole(.small)
                .foregroundStyle(tone.foreground)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tone.background, in: .rect(cornerRadius: Metric.radius))
    }
}

/// 頁面的大標：英文大字＋襯線強調（「Floor *plan*」）＋中文小字
struct PageTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Headline(title, role: .h2)
            if let subtitle {
                Text(subtitle)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// 一列：左邊說明、右邊值（明細、報表）
struct ValueRow: View {
    let label: String
    let value: String
    var strong = false
    var tone: Color = Theme.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(strong ? Theme.ink : Theme.ink2)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tone)
        }
        .font(.brand(strong ? 17 : 15, strong ? .semibold : .regular, relativeTo: .body))
    }
}

/// 選項鈕（付款方式、用餐方式、發票類型）：選到的墨色實心
struct ChoiceButtonStyle: ButtonStyle {
    var selected: Bool
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(14.5, .medium, relativeTo: .callout))
            .foregroundStyle(selected ? Theme.page : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(selected ? Theme.ink : (configuration.isPressed ? Theme.press : Theme.surface), in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.fast, value: configuration.isPressed)
            .animation(Motion.fast, value: selected)
    }
}

extension ButtonStyle where Self == ChoiceButtonStyle {
    static func choice(_ selected: Bool, height: CGFloat = 56) -> ChoiceButtonStyle { ChoiceButtonStyle(selected: selected, height: height) }
}

/// 會換行的一排（加料、甜度的選項、標籤）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// 選項的小方塊（甜度、冰塊、加料、原因）
struct OptionChip: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let detail {
                    Text(detail)
                        .foregroundStyle(selected ? Theme.page.opacity(0.7) : Theme.muted)
                }
            }
            .font(.brand(15, .medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .foregroundStyle(selected ? Theme.page : Theme.ink)
            .background(selected ? Theme.ink : Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(selected ? Color.clear : Theme.line) }
            .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .disabled(disabled)
        .animation(Motion.fast, value: selected)
    }
}
