import Foundation

/// 出單機的紙寬
public enum PaperWidth: String, Codable, Sendable, CaseIterable, Hashable {
    /// 58 mm（電子發票證明聯 5.7 公分；384 點）
    case mm58
    /// 80 mm（576 點）
    case mm80

    /// 一列幾個半形字（12×24 字型）
    public var columns: Int { self == .mm58 ? 32 : 48 }
    /// 可印的點數（203 dpi）
    public var dots: Int { self == .mm58 ? 384 : 576 }
    public var label: String { self == .mm58 ? "58 mm" : "80 mm" }
}

/// 半形／全形：出單機文字模式排版（對齊金額）要算格數，不能算字數。
///
/// 台灣的出單機用 Big5（或 UTF-8 但字型是 Big5／GB 的 24×24）：英數是 1 格（12 點），**其他每一個字**——中文、全形標點、
/// 還有 ×、…、· 這些符號——都是雙位元組、印 2 格（24 點）。照這個算，金額才不會被擠到下一行（虛擬出單機實際印過：tools/escpos-emulator）。
public enum TextWidth {
    public static func of(_ ch: Character) -> Int {
        guard let s = ch.unicodeScalars.first else { return 1 }
        let v = s.value
        if v < 0x80 { return 1 }
        // 半形片假名、半形符號（Big5 沒有，PrintText 會換掉；留著的話照半形算）
        if (0xFF61...0xFFDC).contains(v) || (0xFFE8...0xFFEE).contains(v) { return 1 }
        return 2
    }

    public static func of(_ s: String) -> Int { s.reduce(0) { $0 + of($1) } }

    /// 截到 width 格（超過的話最後放「…」，它在出單機上佔 2 格）
    public static func truncate(_ s: String, to width: Int) -> String {
        guard of(s) > width else { return s }
        var out = "", used = 0
        for ch in s {
            let w = of(ch)
            if used + w > width - of("…") { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    /// 斷行（不切斷英文字以外的東西；中文每個字都能斷）
    public static func wrap(_ s: String, width: Int) -> [String] {
        guard width > 0 else { return [s] }
        var lines: [String] = [], cur = "", used = 0
        for ch in s {
            if ch == "\n" { lines.append(cur); cur = ""; used = 0; continue }
            let w = of(ch)
            if used + w > width { lines.append(cur); cur = ""; used = 0 }
            cur.append(ch)
            used += w
        }
        if !cur.isEmpty || lines.isEmpty { lines.append(cur) }
        return lines
    }

    public static func pad(_ s: String, to width: Int, alignRight: Bool = false) -> String {
        let gap = max(width - of(s), 0)
        let spaces = String(repeating: " ", count: gap)
        return alignRight ? spaces + s : s + spaces
    }

    /// 左邊字、右邊金額，中間補空白（左邊太長就換行，金額在最後一行）
    public static func row(_ left: String, _ right: String, width: Int) -> [String] {
        let rw = of(right)
        let avail = width - rw - 1
        guard avail > 0 else { return [left, pad(right, to: width, alignRight: true)] }
        var lines = wrap(left, width: avail)
        let last = lines.removeLast()
        lines.append(pad(last, to: width - rw) + right)
        return lines
    }
}

/// 送到出單機的字：Big5（台灣出單機的中文）沒有的字換成看起來一樣、而且一定印得出來的字，表情符號拿掉。
/// 沒換的話 iPad 送出去會變成「?」（虛擬出單機與 Big5 對照表檢查過：U+2212 負號、U+30FB 中間點都不在 Big5 裡）
public enum PrintText {
    static let replacements: [Character: String] = [
        "−": "-", "‐": "-", "‑": "-", "‒": "-",          // 負號、各種連字號 → ASCII
        "・": "·", "･": "·", "∙": "·", "⋅": "·",          // 中間點 → Big5 的 ·（A150）
        "≈": "~", "〜": "～",
        "\u{00A0}": " ", "\u{2009}": " ", "\u{202F}": " ", "\u{3000}": "  ",
    ]

    public static func printable(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let r = replacements[ch] { out += r; continue }
            // 表情符號（🔥、☕️…）出單機印不出來
            if ch.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) { continue }
            if ch.unicodeScalars.first.map({ $0.properties.isEmoji && $0.value >= 0x2190 }) == true { continue }
            out.append(ch)
        }
        return out
    }
}
