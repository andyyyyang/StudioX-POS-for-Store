import CoreText
import SwiftUI

// StudioX 的字（studiox.tw 的 global.css）：
//   - 標題、數字、介面：Inter Tight（拉丁字與數字），中文跟著系統的蘋方（網站是 Noto Sans TC）
//   - 強調詞：Instrument Serif，品牌橘、正體不斜（global.css 的 em）；中文強調詞沒有襯線字，就只是橘色
//   - 標題一律字重 500、字距收緊；數字等寬
// 字型檔在 Brand/Fonts（OFL），打開 App 時註冊。
// 和 StudioX Console App（StudioX-Console-App 的 Brand/Typography.swift）同一份；POS 多了收銀台用的大數字（till）。

enum BrandFonts {
    static let faces = [
        "InterTight-Regular", "InterTight-Medium", "InterTight-SemiBold", "InterTight-Bold",
        "InstrumentSerif-Regular", "InstrumentSerif-Italic",
    ]

    /// 打開 App 時呼叫一次
    static func register() {
        for name in faces {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// Inter Tight 的字重
enum Face {
    case regular, medium, semibold, bold

    var postScriptName: String {
        switch self {
        case .regular: "InterTight-Regular"
        case .medium: "InterTight-Medium"
        case .semibold: "InterTight-SemiBold"
        case .bold: "InterTight-Bold"
        }
    }
}

extension Font {
    /// Inter Tight（跟著動態字級縮放）
    static func brand(_ size: CGFloat, _ face: Face = .medium, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(face.postScriptName, size: size, relativeTo: style)
    }

    /// Instrument Serif：強調詞
    static func serif(_ size: CGFloat, italic: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size, relativeTo: style)
    }
}

/// 字的角色（global.css 的 --fs-*；手機用 767px 以下那組、iPad 用桌機那組的中間值）
enum TextRole {
    /// 首頁大標（Hero：−0.04em、行高 1.06）
    case hero
    /// 內頁主標（--fs-h1）
    case h1
    /// 區塊標題（--fs-h2：英文大字＋襯線強調詞）
    case h2
    /// 卡片、模組標題（--fs-h3）
    case h3
    /// 清單項目、問題（--fs-h4）
    case h4
    /// 宣言段落（--fs-statement：500、行高 1.35、−0.02em）
    case statement
    /// 導言（--fs-lead：ink-2、行高 1.7）
    case lead
    case body
    case small
    /// 說明、時間（--fs-xs）
    case xs
    /// 欄位、分類的小字
    case label
    /// 大數字（Stats：500、−0.05em、等寬）
    case stat
    /// 卡片裡的數字
    case number
    /// 收銀台的大數字（應收、找零、右側鍵盤上的數字）
    case till

    func size(regular: Bool) -> CGFloat {
        switch self {
        case .hero: regular ? 64 : 36
        case .h1: regular ? 52 : 33
        case .h2: regular ? 44 : 29
        case .h3: regular ? 26 : 20
        case .h4: regular ? 19 : 16.5
        case .statement: regular ? 30 : 19
        case .lead: regular ? 18 : 15.5
        case .body: regular ? 16.5 : 15
        case .small: regular ? 14.5 : 13.5
        case .xs: regular ? 13 : 12
        case .label: regular ? 12.5 : 12
        case .stat: regular ? 60 : 38
        case .number: regular ? 30 : 24
        case .till: regular ? 56 : 44
        }
    }

    var face: Face {
        switch self {
        case .hero, .h1, .h2, .h3, .h4, .statement, .stat, .number, .till: .medium
        case .label: .medium
        case .lead, .body, .small, .xs: .regular
        }
    }

    /// 字距（em）
    var tracking: CGFloat {
        switch self {
        case .hero, .h1: -0.04
        case .h2: -0.035
        case .stat, .till: -0.05
        case .number: -0.03
        case .h3, .statement: -0.02
        case .h4: -0.01
        case .label: 0.02
        case .lead, .body, .small, .xs: 0.01
        }
    }

    /// 行高（倍數）
    var lineHeight: CGFloat {
        switch self {
        case .hero: 1.08
        case .h1: 1.1
        case .h2: 1.05
        case .stat, .number, .till: 1
        case .h3: 1.2
        case .h4: 1.3
        case .statement: 1.35
        case .lead: 1.65
        case .body: 1.55
        case .small, .xs, .label: 1.45
        }
    }

    var style: Font.TextStyle {
        switch self {
        case .hero, .h1, .stat, .till: .largeTitle
        case .h2: .title
        case .h3, .number: .title3
        case .h4: .headline
        case .statement: .title3
        case .lead, .body: .body
        case .small: .subheadline
        case .xs: .footnote
        case .label: .caption
        }
    }

    var isNumeric: Bool { self == .stat || self == .number || self == .till }
}

/// 套用字的角色：字型、字距、行高（iPad 用大一號）
struct TextRoleModifier: ViewModifier {
    let role: TextRole
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        let size = role.size(regular: sizeClass == .regular)
        let text = content
            .font(.brand(size, role.face, relativeTo: role.style))
            .tracking(size * role.tracking)
            .lineSpacing(max(size * (role.lineHeight - 1.2), 0))
        if role.isNumeric {
            text.monospacedDigit()
        } else {
            text
        }
    }
}

extension View {
    func textRole(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }
}

// MARK: - 強調詞

/// 標題裡用 *星號* 包起來的字是強調詞：Instrument Serif、品牌橘（global.css 的 em）。
/// 例：`Headline("Good *morning*")`、`Headline("今天有三件事*等你決定*。", role: .hero)`
struct Headline: View {
    let text: String
    var role: TextRole = .h2
    var color: Color = Theme.ink
    var accent: Color = Theme.accent
    /// 強調詞用 Xena 的彩虹漸層（介紹頁 .xh__title em：粉 → 淡紫 → 青），不是品牌橘
    var iridescent = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(_ text: String, role: TextRole = .h2, color: Color = Theme.ink, accent: Color = Theme.accent, iridescent: Bool = false) {
        self.text = text
        self.role = role
        self.color = color
        self.accent = accent
        self.iridescent = iridescent
    }

    var body: some View {
        let size = role.size(regular: sizeClass == .regular)
        Group {
            if iridescent {
                Self.iridescentText(text, size: size, role: role)
            } else {
                Text(Self.attributed(text, size: size, role: role, accent: accent))
            }
        }
        .foregroundStyle(color)
        .textRole(role)
        .accessibilityLabel(text.replacingOccurrences(of: "*", with: ""))
    }

    /// 強調詞是 Xena 的漸層（一段一段接起來的 Text，漸層才畫得上去）
    static func iridescentText(_ text: String, size: CGFloat, role: TextRole) -> Text {
        var out = Text(verbatim: "")
        for (i, part) in text.split(separator: "*", omittingEmptySubsequences: false).enumerated() {
            let piece = Text(String(part))
            if i % 2 == 1 {
                let em = piece
                    .font(.serif(size * 1.08, relativeTo: role.style))
                    .tracking(0)
                    .foregroundStyle(Theme.xenaGradient)
                out = Text("\(out)\(em)")
            } else {
                out = Text("\(out)\(piece)")
            }
        }
        return out
    }

    /// 拆成一般字與強調詞；強調詞用 Instrument Serif（襯線字比 Inter Tight 小一點，放大 8% 對齊視覺大小）
    static func attributed(_ text: String, size: CGFloat, role: TextRole, accent: Color) -> AttributedString {
        var out = AttributedString()
        for (i, part) in text.split(separator: "*", omittingEmptySubsequences: false).enumerated() {
            var run = AttributedString(String(part))
            if i % 2 == 1 {
                run.font = .serif(size * 1.08, relativeTo: role.style)
                run.foregroundColor = accent
                // 襯線字不需要收緊字距
                run.tracking = 0
            }
            out.append(run)
        }
        return out
    }
}

// MARK: - 一行一行升起的標題（SplitLines.astro 的 mask）

/// 每一行從遮罩下方升起（1.2 秒、每行晚 110ms）；「減少動態效果」時直接顯示
struct RisingHeadline: View {
    let lines: [String]
    var role: TextRole = .hero
    var color: Color = Theme.ink
    /// 換了內容要重新升起時改這個
    var replayKey: AnyHashable = 0
    var alignment: HorizontalAlignment = .leading
    var iridescent = false
    /// 晚一點才升起（上面那行先）
    var delay: Double = 0

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let up = shown || reduceMotion
                Headline(line, role: role, color: color, iridescent: iridescent)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .visualEffect { content, proxy in
                        content.offset(y: up ? 0 : proxy.size.height * 1.15)
                    }
                    .opacity(up ? 1 : 0)
                    .animation(Motion.mask.delay(delay + Double(index) * 0.11), value: up)
                    // 遮罩比行高多一點，中文的上下緣不會被切到
                    .mask { Rectangle().padding(.vertical, -6) }
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: replayKey) {
            shown = false
            try? await Task.sleep(for: .milliseconds(60))
            shown = true
        }
    }
}
