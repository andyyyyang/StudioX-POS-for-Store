import POSCore
import SwiftUI
import UIKit

/// StudioX 的顏色（和 StudioX Console App 同一份，POS 多了分類色塊與桌況，在檔案最後）。
/// 版面與字照 studiox.tw（studio_website 的 src/styles/global.css :root）：
/// 暖紙色的底、墨色的字、一條條細線、品牌橘只點在重點上；亮色、暗色各自選色，跟著裝置切換。
/// 狀態色、圖表色、系統控制項的主色照後台（atelier-cms 的 src/app/admin/_ui/theme.ts）。
/// 頁面裡一律用這裡的名字，不寫色碼。
enum Theme {
    // MARK: 底（global.css）

    /// --bg：暖紙色
    static let page = Color(light: 0xF2F0EB, dark: 0x0D0D0C)
    /// --bg-2：交錯的區塊
    static let pageAlt = Color(light: 0xE9E6DF, dark: 0x141413)
    /// --surface：卡片、表單
    static let surface = Color(light: 0xF8F7F3, dark: 0x1A1A18)
    /// --panel-top：卡片漸層的上緣（.panel）
    static let panelTop = Color(light: 0xFBFAF8, dark: 0x1F1F1D)
    /// --panel-hl：卡片上緣的亮線
    static let panelHighlight = Color(light: .rgba(255, 255, 255, 0.8), dark: .rgba(255, 255, 255, 0.06))
    /// 底部面板（AuthScreen 的 sheet：#faf9f6 / #151513）
    static let sheet = Color(light: 0xFAF9F6, dark: 0x151513)
    /// 視窗本身的底（UIKit）：狀態列後面、iPad 分欄之間露出來的地方也是暖紙色，不會一塊純黑、一塊品牌色
    static let pageUIColor = UIColor(light: .rgb(0xF2F0EB), dark: .rgb(0x0D0D0C))

    // MARK: 字

    /// --ink：主要的字
    static let ink = Color(light: 0x0F0F0E, dark: 0xEEEBE5)
    /// --ink-2：次要的字、導言
    static let ink2 = Color(light: 0x3B3A37, dark: 0xBDB9B1)
    /// --muted：說明、標籤、時間
    static let muted = Color(light: 0x77746D, dark: 0x85827B)
    /// 最淡的提示（不放重要資訊）
    static let faint = Color(light: .rgba(15, 15, 14, 0.32), dark: .rgba(238, 235, 229, 0.3))

    // MARK: 線

    /// --line：細線、框
    static let line = Color(light: .rgba(15, 15, 14, 0.14), dark: .rgba(238, 235, 229, 0.13))
    /// 清單裡比較密的分隔線
    static let hair = Color(light: .rgba(15, 15, 14, 0.08), dark: .rgba(238, 235, 229, 0.08))
    /// 按下、選取中的淡底
    static let press = Color(light: .rgba(15, 15, 14, 0.05), dark: .rgba(238, 235, 229, 0.06))
    /// Xena 對話裡的淡底（copilot 的 --cp-soft）
    static let soft = Color(light: .rgba(0, 0, 0, 0.045), dark: .rgba(255, 255, 255, 0.06))

    // MARK: 品牌橘

    /// --accent：品牌橘（強調的字、點、按下時填滿）
    static let accent = Color(light: 0xFF5A1F, dark: 0xFF6A33)
    /// 橘色上的字
    static let onAccent = Color.white
    /// 小字用的橘（在紙色上夠清楚；後台的 --adm-accent）
    static let accentText = Color(light: 0xB83700, dark: 0xFF8250)
    /// 橘色的淡底
    static let accentSoft = Color(light: .rgba(255, 90, 31, 0.1), dark: .rgba(255, 106, 51, 0.14))
    /// 系統控制項（開關、游標、選取）用的主色（後台的 --adm-primary，亮色比品牌橘深一點才夠清楚）
    static let primary = Color(light: 0xCB3E01, dark: 0xFF6A33)
    /// 主色上的字（後台的 --adm-on-primary；Xena 對話裡自己的泡泡）
    static let onPrimary = Color(light: 0xFFFFFF, dark: 0x18181B)
    /// 焦點框
    static let focus = Color(light: .rgba(255, 90, 31, 0.4), dark: .rgba(255, 130, 80, 0.45))
    /// 標誌的摺角（亮暗都一樣的品牌橘）
    static let brandOrange = Color(hex: 0xFF5A1F)

    // MARK: 對話泡泡（照 iMessage：客人的是灰的；我們的實心、白字——Xena 紫、專人品牌橘）

    /// 客人的泡泡（暖灰，配紙色的底）
    static let bubbleIn = Color(light: 0xE7E4DE, dark: 0x262624)
    /// 專人的泡泡（白字，對比 4:1 以上）
    static let bubbleStaff = Color(light: 0xCB3E01, dark: 0xD4521C)
    /// Xena 的泡泡（白字；Xena 的紫）
    static let bubbleXena = Color(light: 0x6A4CE0, dark: 0x5D45D2)

    // MARK: 反白的帶（.inverse：跑馬燈、行動區塊、頁尾）

    static let inverse = Color(light: 0x0F0F0E, dark: 0x181816)
    static let onInverse = Color(light: 0xF2F0EB, dark: 0xEEEBE5)
    static let inverseMuted = Color(light: .rgba(242, 240, 235, 0.58), dark: .rgba(238, 235, 229, 0.55))
    static let inverseLine = Color(light: .rgba(242, 240, 235, 0.14), dark: .rgba(238, 235, 229, 0.13))

    // MARK: 狀態（只表示狀態，一定配文字或圖示；theme.ts）

    static let successFG = Color(light: 0x166534, dark: 0x4ADE80)
    static let warningFG = Color(light: 0x854D0E, dark: 0xFACC15)
    static let dangerFG = Color(light: 0xBE123C, dark: 0xFB7185)
    static let infoFG = Color(light: 0x1D4ED8, dark: 0x60A5FA)
    /// --success（網站上的「在線」綠點）
    static let live = Color(light: 0x1FA35A, dark: 0x34C46F)

    // MARK: Xena（AI 專用的三個顏色，只出現在 Xena 身上；Orb.astro）

    static let xenaPink = Color(hex: 0xFF6BD1)
    static let xenaViolet = Color(hex: 0x845CFF)
    static let xenaCyan = Color(hex: 0x40CCFF)
    /// Xena 說話時強調詞的彩虹（介紹頁 .xh__title em：粉 → 淡紫 → 青）：深色底用網頁的顏色；淺色底用深一點的同色系才讀得到
    static let xenaIrisPink = Color(light: 0xD23A98, dark: 0xFF8AD8)
    static let xenaIrisLavender = Color(light: 0x7652F5, dark: 0xB49BFF)
    static let xenaIrisCyan = Color(light: 0x1391C4, dark: 0x6FD6FF)
    static let xenaGradient = LinearGradient(
        colors: [xenaIrisPink, xenaIrisLavender, xenaIrisCyan, xenaIrisLavender, xenaIrisPink],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: 圖表（資料標記，順序固定、跟著「東西」走；theme.ts）

    static let chart: [Color] = [
        Color(light: 0xE64700, dark: 0xFF6A33),
        Color(light: 0x2A78D6, dark: 0x3987E5),
        Color(light: 0x1BAF7A, dark: 0x199E70),
        Color(light: 0x4A3AA7, dark: 0x9085E9),
        Color(light: 0xEDA100, dark: 0xC98500),
    ]
}

// MARK: - POS：分類色塊、桌況

extension Theme {
    /// 點餐畫面的分類大方塊：粉彩、亮暗都一樣，上面的字一律是墨色（tileInk）
    static func swatch(_ s: Swatch) -> Color {
        switch s {
        case .peach: Color(hex: 0xF6C9B4)
        case .lavender: Color(hex: 0xCBC6F5)
        case .mint: Color(hex: 0xB7E6D2)
        case .sky: Color(hex: 0xB9D9F3)
        case .butter: Color(hex: 0xF3E3A8)
        case .rose: Color(hex: 0xF4C3D3)
        case .sage: Color(hex: 0xCADBB9)
        case .sand: Color(hex: 0xE7DDCC)
        case .clay: Color(hex: 0xEDB7A0)
        case .slate: Color(hex: 0xC4CCD8)
        }
    }

    /// 色塊上的字
    static let tileInk = Color(hex: 0x141412)
    static let tileInkMuted = Color(hex: 0x141412, opacity: 0.58)

    /// 桌況的顏色（一定配字：空桌、用餐中…）
    static func table(_ s: TableStatus) -> Color {
        switch s {
        case .available: muted
        case .reserved: Color(light: 0x6A4CE0, dark: 0x9C88FF)
        case .seated: infoFG
        case .ordering: accent
        case .billing: warningFG
        case .needsCleaning: Color(light: 0x8A6A4A, dark: 0xB89A78)
        }
    }

    /// 收銀台的面（右側鍵盤、單子欄）：比頁面亮一階
    static let dock = Color(light: 0xFBFAF8, dark: 0x161615)
    /// 鍵盤的鍵
    static let key = Color(light: 0xEFECE6, dark: 0x242422)
    static let keyPressed = Color(light: 0xE2DED6, dark: 0x302F2C)
}

/// 尺寸（global.css）：圓角、留白
enum Metric {
    /// --radius-sm：按鈕、標籤、方形圖示鈕
    static let radiusSm: CGFloat = 5
    /// --radius：卡片、圖片
    static let radius: CGFloat = 8
    /// --radius-lg：表單、文章封面
    static let radiusLg: CGFloat = 10
    /// .chip
    static let chip: CGFloat = 4
    /// Xena 的卡片（copilot 的 .cp-card）
    static let xenaCard: CGFloat = 16
    /// 手機左右留白（--gutter 在手機是 16）
    static let gutter: CGFloat = 16
    /// iPad 左右留白（--gutter：clamp(16px, 4vw, 56px)）
    static let gutterWide: CGFloat = 40
    /// 文章、表單最寬（news/[slug] 的 760px）
    static let readable: CGFloat = 760
    /// 一般頁面最寬（.container 1520，平板上收一點）
    static let page: CGFloat = 1180

    // POS 的四欄：側欄｜工作區｜單子｜右側鍵盤
    static let rail: CGFloat = 88
    static let ticketColumn: CGFloat = 352
    static let ticketColumnNarrow: CGFloat = 320
    static let dock: CGFloat = 328
    static let dockNarrow: CGFloat = 296
    /// 鍵盤的鍵（手指好按：至少 64 點）
    static let keyHeight: CGFloat = 68
}

// MARK: - 顏色的寫法

/// 亮色或暗色的一個值：#rrggbb 或 rgba()
nonisolated struct RGBA: Sendable {
    var r: Double, g: Double, b: Double, a: Double

    nonisolated static func rgb(_ hex: UInt32) -> RGBA {
        RGBA(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: 1)
    }

    nonisolated static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> RGBA {
        RGBA(r: r / 255, g: g / 255, b: b / 255, a: a)
    }

    nonisolated var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
}

extension UIColor {
    /// 亮色、暗色各一個值（跟著裝置或 App 設定的外觀切換）
    nonisolated convenience init(light: RGBA, dark: RGBA) {
        let l = light.uiColor, d = dark.uiColor
        self.init { traits in traits.userInterfaceStyle == .dark ? d : l }
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        let c = RGBA.rgb(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }

    /// 亮色、暗色各一個色碼
    nonisolated init(light: UInt32, dark: UInt32) {
        self.init(light: .rgb(light), dark: .rgb(dark))
    }

    nonisolated init(light: RGBA, dark: RGBA) {
        let l = light.uiColor, d = dark.uiColor
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? d : l })
    }

    /// 網站橫幅的底色（#rrggbb 字串）
    nonisolated init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

// MARK: - 日期

extension Date {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = format
        return f
    }

    private static let clock = formatter("HH:mm")
    private static let monthDay = formatter("M/d HH:mm")
    private static let dayOnly = formatter("yyyy/M/d")
    private static let dayTitleFormat = formatter("M月d日 EEEE")
    private static let weekday = formatter("EEEE")
    private static let english = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    /// 15:40
    var clockText: String { Self.clock.string(from: self) }
    /// 今天的只寫時間，其他寫日期＋時間
    var shortText: String { Calendar.taipei.isDateInToday(self) ? Self.clock.string(from: self) : Self.monthDay.string(from: self) }
    /// 2026/10/2
    var dayText: String { Self.dayOnly.string(from: self) }
    /// 10月2日 星期五
    var dayTitle: String { Self.dayTitleFormat.string(from: self) }
    /// 星期五
    var weekdayText: String { Self.weekday.string(from: self) }
    /// Fri, Oct 2
    var englishDay: String { Self.english.string(from: self) }

    /// 3 分鐘前、2 小時前、昨天、9/28
    var relativeText: String {
        let s = Date.now.timeIntervalSince(self)
        if s < 60 { return "剛剛" }
        if s < 3600 { return "\(Int(s / 60)) 分鐘前" }
        if Calendar.taipei.isDateInToday(self) { return "\(Int(s / 3600)) 小時前" }
        if Calendar.taipei.isDateInYesterday(self) { return "昨天 \(clockText)" }
        return Self.monthDay.string(from: self)
    }
}

extension Calendar {
    /// 網站的「今天、昨天」都是台北時間
    static let taipei: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        c.locale = Locale(identifier: "zh_Hant_TW")
        return c
    }()
}
