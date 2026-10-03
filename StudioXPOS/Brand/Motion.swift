import SwiftUI

/// 動態（global.css：「所有動態共用同一組曲線與時長」）。
/// 進場、按壓是快出慢停（--ease），轉場是 --ease-in-out；「減少動態效果」時一律關掉。
enum Motion {
    /// --ease：cubic-bezier(0.22, 1, 0.36, 1)，0.6 秒
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
    /// --dur-fast 0.3 秒
    static let fast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    /// --dur-slow 1.1 秒：捲進畫面的內容
    static let slow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1.1)
    /// 標題一行一行升起：1.2 秒
    static let mask = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1.2)
    /// --ease-in-out：轉場
    static let inOut = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.6)
    /// 標誌兩塊卡上去的回彈（Loader：cubic-bezier(0.34, 1.4, 0.5, 1)）
    static let snap = Animation.timingCurve(0.34, 1.4, 0.5, 1, duration: 1.1)
    /// 數字跑上去（Stats 的 count-up：1.6 秒、ease-out-cubic）
    static let count = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 1.6)
    /// 一般的彈性（面板、提示）
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// --stagger：同一批進場的內容一個接一個（最多算到第 6 個）
    static let stagger = 0.08

    static func staggered(_ index: Int, base: Animation = slow) -> Animation {
        base.delay(Double(min(max(index, 0), 6)) * stagger)
    }
}

// MARK: - 進場（global.css 的 reveal）

/// 進場：從下方 28pt 淡入（1.1 秒，同一批照順序晚 80ms）。只演一次
struct Reveal: ViewModifier {
    enum Style {
        /// 往上（預設）
        case rise
        /// 只有淡入
        case fade
        /// 從左邊滑進來（手機的 data-m="left"）
        case left
        /// 從 0.94 放大（data-m="scale"）
        case scale
        /// 從模糊變清楚（data-m="blur"）
        case blur
    }

    var index = 0
    var style: Style = .rise

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = shown || reduceMotion
        content
            .opacity(on ? 1 : 0)
            .offset(x: !on && style == .left ? -44 : 0, y: !on && (style == .rise || style == .blur) ? (style == .blur ? 10 : 28) : 0)
            .scaleEffect(!on && style == .scale ? 0.94 : 1)
            .blur(radius: !on && style == .blur ? 10 : 0)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.staggered(index)) { shown = true }
            }
    }
}

extension View {
    /// 進場動畫（index：同一批裡的第幾個）
    func reveal(_ index: Int = 0, _ style: Reveal.Style = .rise) -> some View {
        modifier(Reveal(index: index, style: style))
    }

    /// 捲動時：進出畫面邊緣的那幾行淡一點、往下沉一點（網站捲到才出現的感覺，原生的版本）
    func scrollReveal() -> some View {
        scrollTransition(.interactive(timingCurve: .easeOut)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.35)
                .offset(y: phase.value > 0 ? 14 * phase.value : 0)
        }
    }
}

// MARK: - 按壓

/// 按下微縮（Console 登入頁的 .98）
struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}

/// 清單的一列：按下時淡底（不縮放，列要對齊）
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .background(configuration.isPressed ? Theme.press : .clear)
            .hoverEffect(.highlight)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressScale {
    static var press: PressScale { PressScale() }
}

extension ButtonStyle where Self == RowPressStyle {
    static var row: RowPressStyle { RowPressStyle() }
}
