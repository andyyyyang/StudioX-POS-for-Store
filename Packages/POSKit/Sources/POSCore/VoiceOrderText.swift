import Foundation

/// 語音點餐：說的話 → 菜單上的品項。
///
/// 聽寫常把菜名寫成同音的別字（「鴨胸」→「壓胸」「鴨兄」）。先用讀音把別字改回菜單上的名字（`VoiceMenu.corrected`），
/// 再交給 Apple 的模型整理成一行一行（模型只能從菜單的名字裡選）。純函式，不碰畫面、不連網路
public enum VoiceOrderText {
    /// 對到菜單的一樣
    public struct Line: Sendable, Hashable {
        public var item: MenuItem
        /// 有規格的品項：說了哪一個（沒說、對不到是 nil）
        public var variant: ItemVariant?
        public var quantity: Int
        public var note: String

        public init(item: MenuItem, variant: ItemVariant?, quantity: Int, note: String = "") {
            self.item = item; self.variant = variant; self.quantity = quantity; self.note = note
        }

        /// 有規格卻沒說哪一個（「鴨胸」沒說 140 還是 150）
        public var needsVariant: Bool { item.hasVariants && variant == nil }
    }

    // MARK: 數字

    private static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                                  "六": 6, "七": 7, "八": 8, "九": 9]

    /// 「3」「３」「三」「兩」「十二」「二十」「二十五」→ 數字（1–999）；不是數字回 nil
    public static func number(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let ascii = String(t.map { c -> Character in
            // 全形數字
            if let v = c.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v), let u = UnicodeScalar(v - 0xFF10 + 0x30) { return Character(u) }
            return c
        })
        if ascii.allSatisfy(\.isASCII), let n = Int(ascii) { return n }
        // 口語「一百四」＝140、「兩百五」＝250（百後面只有一個數字）
        let cs = Array(t)
        if cs.count == 3, cs[1] == "百", let h = digits[cs[0]], let tens = digits[cs[2]], tens > 0 {
            return h * 100 + tens * 10
        }
        // 中文：十、十二、二十、二十五、一百二十
        var total = 0
        var current = 0
        var sawAny = false
        for c in t {
            if let d = digits[c] {
                current = d
                sawAny = true
            } else if c == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
                sawAny = true
            } else if c == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
                sawAny = true
            } else {
                return nil
            }
        }
        guard sawAny else { return nil }
        let n = total + current
        return n > 0 ? n : nil
    }

    /// 數字與量詞（「兩」「份」「個」）：改別字時不動它們（「兩份」不會變成菜單上的「涼粉」）
    static let countWords = Set("零〇一二兩两三四五六七八九十百半幾份個串盒包碗杯支塊片條隻顆粒袋碟盤")

    // MARK: 規格

    /// 規格：「140」對到價錢 140 的、「大」對到選項有「大」的；只有一個規格就是它
    public static func variant(_ raw: String, of item: MenuItem) -> ItemVariant? {
        let options = item.activeVariants
        guard !options.isEmpty else { return nil }
        let text = normalized(raw)
        if !text.isEmpty {
            if let n = number(text) ?? Int(text.filter(\.isNumber)),
               let byPrice = options.first(where: { item.price(of: $0).cents == n * 100 }) { return byPrice }
            if let byLabel = options.first(where: { v in v.options.contains { o in normalized(o) == text || text.contains(normalized(o)) } }) {
                return byLabel
            }
        }
        return options.count == 1 ? options[0] : nil
    }

    /// 去掉空白、標點，全形轉半形、轉小寫
    static func normalized(_ s: String) -> String {
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where !skip.contains(u) {
            // 全形英數（Ａ、１）→ 半形
            if (0xFF01...0xFF5E).contains(u.value), let half = UnicodeScalar(u.value - 0xFEE0) {
                out.append(half)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }
}

/// 一份菜單的讀音索引：菜單變了才重建；每一段話拿來改別字、檢查模型選的品名是不是真的有說到。
///
/// 改別字的規則（同樣長度的一段字對菜單上的名字，一個字一個字比）：
/// - 同一個字 3 分；同音同調 2 分（「壓」對「鴨」）；同音不同調 1 分（聲母 zh/z、ch/c、sh/s、l/n，韻母 -ng 不分）
/// - 平均要有 2 分（「鴨兄」5 分 ≥ 4）；每個字都要有分，四個字以上的名字可以錯一個字
/// - 一個字的名字只認一模一樣的；數字、量詞（兩、份、個）不改
/// - 分數高的先、長的先，不重疊
public struct VoiceMenu: Sendable {
    /// 一個字的讀音：拼音加聲調（「鴨」→「ya1」，輕聲 5）；不是中文字回 nil
    public typealias Pronounce = @Sendable (Character) -> String?

    public struct Entry: Sendable {
        /// 給模型選的名字（同名的品項加分類：「紅茶（飲料）」）
        public let label: String
        public let item: MenuItem
    }

    struct Sound: Sendable, Equatable {
        /// 拼音（聲母韻母相近的併在一起）
        let base: String
        let tone: Character

        init?(_ raw: String?) {
            guard var s = raw?.lowercased(), !s.isEmpty else { return nil }
            var tone: Character = "5"
            if let last = s.last, "12345".contains(last) {
                tone = last
                s.removeLast()
            }
            guard !s.isEmpty else { return nil }
            self.base = Sound.fuzzy(s)
            self.tone = tone
        }

        /// 台灣口音、聽寫常混的：zh/z、ch/c、sh/s、l/n，-ang/-an、-eng/-en、-ing/-in
        static func fuzzy(_ s: String) -> String {
            var t = s
            if t.hasPrefix("zh") || t.hasPrefix("ch") || t.hasPrefix("sh") { t.remove(at: t.index(after: t.startIndex)) }
            if t.hasPrefix("l") { t = "n" + t.dropFirst() }
            if t.hasSuffix("ng") { t.removeLast() }
            return t
        }
    }

    /// 菜單上的一種寫法（名字、簡稱）
    struct Spelling: Sendable {
        let chars: [Character]
        let sounds: [Sound?]
        let entry: Int
    }

    public let entries: [Entry]
    private let byLabel: [String: Int]
    private let spellings: [Spelling]
    private let pronounce: Pronounce

    public init(catalog: Catalog, pronounce: @escaping Pronounce) {
        self.pronounce = pronounce
        var nameCount: [String: Int] = [:]
        for item in catalog.items { nameCount[item.name, default: 0] += 1 }
        var seen = Set<String>()
        var entries: [Entry] = []
        for item in catalog.items where !item.name.isEmpty {
            var label = item.name
            if nameCount[item.name, default: 0] > 1, let category = catalog.category(item.categoryId)?.name {
                label = "\(item.name)（\(category)）"
            }
            var unique = label
            var n = 2
            while seen.contains(unique) {
                unique = "\(label)\(n)"
                n += 1
            }
            seen.insert(unique)
            entries.append(Entry(label: unique, item: item))
        }
        self.entries = entries
        var byLabel: [String: Int] = [:]
        var spellings: [Spelling] = []
        for (i, e) in entries.enumerated() {
            byLabel[e.label] = i
            // 簡稱一個字的不用（「大」會把「大概」改掉）
            let names = [e.item.name] + [e.item.shortName].compactMap { $0 }.filter { $0.count >= 2 && $0 != e.item.name }
            for name in names {
                let chars = Array(name)
                spellings.append(Spelling(chars: chars, sounds: chars.map { Sound(pronounce($0)) }, entry: i))
            }
        }
        self.byLabel = byLabel
        self.spellings = spellings
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 模型選的名字 → 品項
    public func item(label: String) -> MenuItem? {
        byLabel[label].map { entries[$0].item }
    }

    /// 給聽寫參考的詞（品名、簡稱；最多 100 個）
    public var vocabulary: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries {
            for name in [e.item.name] + [e.item.shortName].compactMap({ $0 }) where name.count >= 2 && seen.insert(name).inserted {
                out.append(name)
            }
        }
        return Array(out.prefix(100))
    }

    /// 給模型看的菜單（一行，越短越快）：「鴨胸(140/150)、鴨心、鴨腸」——有幾種價錢或規格的寫在括號裡
    public var menuLine: String {
        entries.map { e in
            let vs = e.item.activeVariants
            guard vs.count > 1 else { return e.label }
            let distinctPrices = Set(vs.map { e.item.price(of: $0).cents }).count == vs.count
            let specs = distinctPrices ? vs.map { e.item.price(of: $0).plain } : vs.map(\.label)
            return "\(e.label)(\(specs.joined(separator: "/")))"
        }.joined(separator: "、")
    }

    // MARK: 改別字

    /// 把聽寫的別字改回菜單上的名字（「壓胸兩份」→「鴨胸兩份」）；其他的字照舊
    public func corrected(_ text: String) -> String {
        let chars = Array(text)
        guard !chars.isEmpty, !spellings.isEmpty else { return text }
        let sounds = chars.map { Sound(pronounce($0)) }
        var found: [(start: Int, length: Int, score: Int, entry: Int)] = []
        for s in spellings where s.chars.count <= chars.count {
            for start in 0...(chars.count - s.chars.count) {
                if let score = score(s, at: start, chars: chars, sounds: sounds) {
                    found.append((start, s.chars.count, score, s.entry))
                }
            }
        }
        guard !found.isEmpty else { return text }
        // 平均分數高的先（不用除法：a/la > b/lb ⇔ a·lb > b·la）、長的先、前面的先
        found.sort { a, b in
            let l = a.score * b.length, r = b.score * a.length
            if l != r { return l > r }
            if a.length != b.length { return a.length > b.length }
            return a.start < b.start
        }
        var taken = [Bool](repeating: false, count: chars.count)
        var replace: [Int: (length: Int, entry: Int)] = [:]
        for f in found where !taken[f.start..<(f.start + f.length)].contains(true) {
            for k in f.start..<(f.start + f.length) { taken[k] = true }
            replace[f.start] = (f.length, f.entry)
        }
        var out = ""
        var i = 0
        while i < chars.count {
            if let r = replace[i] {
                out += entries[r.entry].item.name
                i += r.length
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// 一段字像不像這個名字：像就回分數，不像回 nil
    private func score(_ s: Spelling, at start: Int, chars: [Character], sounds: [Sound?]) -> Int? {
        let length = s.chars.count
        var total = 0
        var misses = 0
        for k in 0..<length {
            let c = chars[start + k]
            if c == s.chars[k] {
                total += 3
                continue
            }
            // 一個字的名字只認一模一樣的；數字、量詞不改
            if length == 1 || VoiceOrderText.countWords.contains(c) { return nil }
            if let a = sounds[start + k], let b = s.sounds[k], a.base == b.base {
                total += a.tone == b.tone ? 2 : 1
            } else {
                misses += 1
                if misses > (length >= 4 ? 1 : 0) { return nil }
            }
        }
        return total >= 2 * length ? total : nil
    }

    // MARK: 模型選的有沒有說到

    /// 模型選的品項真的有說到：名字在話裡，或至少一個字（同音也算）有說到；都沒有就是模型硬湊的（「可樂」被湊成「鴨胸」）
    public func mentions(_ item: MenuItem, in text: String) -> Bool {
        let names = [item.name] + [item.shortName].compactMap { $0 }.filter { $0.count >= 2 }
        if names.contains(where: { text.contains($0) }) { return true }
        let words = text.filter { !VoiceOrderText.countWords.contains($0) }
        let chars = Set(words)
        let bases = Set(words.compactMap { Sound(pronounce($0))?.base })
        return item.name.contains { c in
            chars.contains(c) || (Sound(pronounce(c)).map { bases.contains($0.base) } ?? false)
        }
    }
}
