import Foundation

// 單據樣式（開機資料的 `printStyle`，docs/API.md「單據樣式」）：所有單據預設整張畫成圖片再送出單機（GS v 0），
// 每台機器印出來一模一樣，也可以疊上店家自己的圖（店標、頁尾、底圖、貼圖）。
//
// 讀的時候很寬鬆：不認得的值、型別不對、少給的欄位都用預設值（新版後台多了 App 不認得的東西，也不會讓整份開機資料讀不進來）。

/// 出單機怎麼印
public enum PrintMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// 整張畫成圖片（預設）：樣式一致、不缺字、可以疊圖
    case image
    /// 出單機自己的字型（Big5／UTF-8）：快，舊機器、藍牙很慢時用
    case text

    /// 一台出單機的設定（PrinterConfig.encoding）→ 實際怎麼印：
    /// `auto`（新的出單機）照後台的 `printStyle.mode`；`raster`＝圖片；`big5`、`utf8`＝文字（之前選好的照舊）
    public static func resolve(encoding: String, style: PrintStyle) -> PrintMode {
        switch encoding {
        case "raster", "image": .image
        case "big5", "utf8", "text": .text
        default: style.mode
        }
    }
}

/// 單據的字
public enum PrintFont: String, Codable, Sendable, CaseIterable, Hashable {
    case sans, serif, rounded
}

/// 哪一種單據（`printStyle.docs` 的 key）。交班單、退款單、測試頁不在這裡：照樣畫成圖、吃 `font` 與 `scale`，不疊圖
public enum PrintDoc: String, Codable, Sendable, CaseIterable, Hashable {
    /// 交易明細
    case receipt
    /// 廚房、吧台的出單
    case kitchen
    /// 結帳單（內用，買單前給客人看）
    case bill
    /// 櫃台、咖啡、外帶的取餐單（交易明細＋最上面很大的取餐號碼）
    case pickup

    public var label: String {
        switch self {
        case .receipt: "交易明細"
        case .kitchen: "廚房單"
        case .bill: "結帳單"
        case .pickup: "取餐單"
        }
    }
}

public enum PrintAlign: String, Codable, Sendable, CaseIterable, Hashable {
    case left, center, right
}

/// 底圖怎麼鋪
public enum PrintFit: String, Codable, Sendable, CaseIterable, Hashable {
    /// 照紙寬放大、貼在最上面（比單子短就只有上面有）
    case top
    /// 原尺寸（1 px＝1 點）整張重複
    case tile
    /// 拉滿整張單子
    case stretch
}

/// 貼圖的 y 從哪裡算
public enum PrintAnchor: String, Codable, Sendable, CaseIterable, Hashable {
    case top, bottom
}

/// 店標（header）、頁尾（footer）：寬度是紙寬的比例
public struct PrintImage: Codable, Sendable, Hashable {
    public var url: String
    /// 紙寬的比例（0.05–1）
    public var width: Double
    public var align: PrintAlign

    public init(url: String, width: Double = 0.5, align: PrintAlign = .center) {
        self.url = url
        self.width = PrintStyle.clamp(width, 0.05, 1)
        self.align = align
    }

    enum CodingKeys: String, CodingKey { case url, width, align }

    /// 沒有網址的圖不算（丟掉，不讓整份樣式讀不進來）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try PrintStyle.url(c, .url),
                  width: c.lenientDouble(.width) ?? 0.5,
                  align: c.lenientString(.align).flatMap(PrintAlign.init(rawValue:)) ?? .center)
    }
}

/// 底圖：先變淡（lighten）再打網點，疊在字下面也看得清楚
public struct PrintBackground: Codable, Sendable, Hashable {
    public var url: String
    public var fit: PrintFit
    /// 0＝原樣、1＝全白（預設 0.75）
    public var lighten: Double

    public init(url: String, fit: PrintFit = .top, lighten: Double = 0.75) {
        self.url = url
        self.fit = fit
        self.lighten = PrintStyle.clamp(lighten, 0, 1)
    }

    enum CodingKeys: String, CodingKey { case url, fit, lighten }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try PrintStyle.url(c, .url),
                  fit: c.lenientString(.fit).flatMap(PrintFit.init(rawValue:)) ?? .top,
                  lighten: c.lenientDouble(.lighten) ?? 0.75)
    }
}

/// 貼圖（印章、角落的插畫）：x、y、width 都是紙寬的比例；y 從 anchor（上緣／下緣）算
public struct PrintOverlay: Codable, Sendable, Hashable {
    public var url: String
    /// 左緣
    public var x: Double
    /// anchor 是 top：圖的上緣離紙的上緣；bottom：圖的下緣離紙的下緣
    public var y: Double
    public var width: Double
    public var anchor: PrintAnchor

    public init(url: String, x: Double, y: Double, width: Double = 0.25, anchor: PrintAnchor = .top) {
        self.url = url
        self.x = PrintStyle.clamp(x, 0, 1)
        self.y = PrintStyle.clamp(y, 0, 1)
        self.width = PrintStyle.clamp(width, 0.02, 1)
        self.anchor = anchor
    }

    enum CodingKeys: String, CodingKey { case url, x, y, width, anchor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try PrintStyle.url(c, .url),
                  x: c.lenientDouble(.x) ?? 0,
                  y: c.lenientDouble(.y) ?? 0,
                  width: c.lenientDouble(.width) ?? 0.25,
                  anchor: c.lenientString(.anchor).flatMap(PrintAnchor.init(rawValue:)) ?? .top)
    }
}

/// 一種單據的樣式。沒給（或 `{}`）＝不疊圖、沒有自己的字，只照全店的 `font`、`scale`
public struct DocStyle: Codable, Sendable, Hashable {
    public var header: PrintImage?
    public var footer: PrintImage?
    public var background: PrintBackground?
    public var overlays: [PrintOverlay]
    /// 店名下面、明細上面的字（店名、地址、電話、統編照樣自動印）
    public var headerLines: [String]
    /// 最後面的字
    public var footerLines: [String]
    /// 這種單據自己的字大小（0.8–1.6）；沒給＝全店的 scale
    public var scale: Double?

    public init(header: PrintImage? = nil, footer: PrintImage? = nil, background: PrintBackground? = nil, overlays: [PrintOverlay] = [],
                headerLines: [String] = [], footerLines: [String] = [], scale: Double? = nil) {
        self.header = header
        self.footer = footer
        self.background = background
        self.overlays = overlays
        self.headerLines = headerLines
        self.footerLines = footerLines
        self.scale = scale.map { PrintStyle.clamp($0, PrintStyle.scaleRange.lowerBound, PrintStyle.scaleRange.upperBound) }
    }

    /// 有沒有圖（沒有圖的單據只畫字：最快）
    public var hasArt: Bool { header != nil || footer != nil || background != nil || !overlays.isEmpty }

    /// 用到的圖（下載、清掉沒用到的）
    public var imageURLs: [String] {
        [header?.url, footer?.url, background?.url].compactMap { $0 } + overlays.map(\.url)
    }

    enum CodingKeys: String, CodingKey { case header, footer, background, overlays, headerLines, footerLines, scale }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let overlays = try? c.decodeIfPresent([Lenient<PrintOverlay>].self, forKey: .overlays)
        self.init(header: try? c.decodeIfPresent(PrintImage.self, forKey: .header),
                  footer: try? c.decodeIfPresent(PrintImage.self, forKey: .footer),
                  background: try? c.decodeIfPresent(PrintBackground.self, forKey: .background),
                  overlays: overlays?.compactMap(\.value) ?? [],
                  headerLines: c.lenientLines(.headerLines),
                  footerLines: c.lenientLines(.footerLines),
                  scale: c.lenientDouble(.scale))
    }

    /// 沒有的欄位不寫（和 API 的規則一樣：選填欄位沒有值時不出現）
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encodeIfPresent(footer, forKey: .footer)
        try c.encodeIfPresent(background, forKey: .background)
        if !overlays.isEmpty { try c.encode(overlays, forKey: .overlays) }
        if !headerLines.isEmpty { try c.encode(headerLines, forKey: .headerLines) }
        if !footerLines.isEmpty { try c.encode(footerLines, forKey: .footerLines) }
        try c.encodeIfPresent(scale, forKey: .scale)
    }
}

/// 四種單據各自的樣式
public struct PrintDocs: Codable, Sendable, Hashable {
    public var receipt: DocStyle
    public var kitchen: DocStyle
    public var bill: DocStyle
    public var pickup: DocStyle

    public init(receipt: DocStyle = DocStyle(), kitchen: DocStyle = DocStyle(), bill: DocStyle = DocStyle(), pickup: DocStyle = DocStyle()) {
        self.receipt = receipt
        self.kitchen = kitchen
        self.bill = bill
        self.pickup = pickup
    }

    public subscript(doc: PrintDoc) -> DocStyle {
        get {
            switch doc {
            case .receipt: receipt
            case .kitchen: kitchen
            case .bill: bill
            case .pickup: pickup
            }
        }
        set {
            switch doc {
            case .receipt: receipt = newValue
            case .kitchen: kitchen = newValue
            case .bill: bill = newValue
            case .pickup: pickup = newValue
            }
        }
    }

    enum CodingKeys: String, CodingKey { case receipt, kitchen, bill, pickup }

    /// 不認得的單據（新版後台多的）不管
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        func doc(_ k: CodingKeys) -> DocStyle { (try? c.decodeIfPresent(DocStyle.self, forKey: k)) ?? DocStyle() }
        self.init(receipt: doc(.receipt), kitchen: doc(.kitchen), bill: doc(.bill), pickup: doc(.pickup))
    }
}

/// 開機資料的 `printStyle`
public struct PrintStyle: Codable, Sendable, Hashable {
    /// 出單機設成「自動」的照這個（預設圖片）
    public var mode: PrintMode
    public var font: PrintFont
    /// 字的大小（0.8–1.6）
    public var scale: Double
    public var docs: PrintDocs

    public static let scaleRange: ClosedRange<Double> = 0.8...1.6

    public init(mode: PrintMode = .image, font: PrintFont = .sans, scale: Double = 1, docs: PrintDocs = PrintDocs()) {
        self.mode = mode
        self.font = font
        self.scale = Self.clamp(scale, Self.scaleRange.lowerBound, Self.scaleRange.upperBound)
        self.docs = docs
    }

    /// 後台沒給 printStyle：圖片、黑體、原大小、不疊圖
    public static let standard = PrintStyle()

    /// 這種單據的樣式（nil＝交班單、退款單、測試頁：不疊圖）
    public func style(for doc: PrintDoc?) -> DocStyle {
        doc.map { docs[$0] } ?? DocStyle()
    }

    /// 這種單據的字大小：單據自己的，沒有就全店的
    public func scale(for doc: PrintDoc?) -> Double {
        style(for: doc).scale ?? scale
    }

    /// 所有用到的圖（開機時下載、清掉沒用到的）
    public var imageURLs: Set<String> {
        Set(PrintDoc.allCases.flatMap { docs[$0].imageURLs })
    }

    enum CodingKeys: String, CodingKey { case mode, font, scale, docs }

    /// 寬鬆：printStyle 不是物件、mode／font 不認得、scale 不是數字……都用預設值
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(mode: c.lenientString(.mode).flatMap(PrintMode.init(rawValue:)) ?? .image,
                  font: c.lenientString(.font).flatMap(PrintFont.init(rawValue:)) ?? .sans,
                  scale: c.lenientDouble(.scale) ?? 1,
                  docs: (try? c.decodeIfPresent(PrintDocs.self, forKey: .docs)) ?? PrintDocs())
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return min(max(v, lo), hi)
    }

    /// 圖一定要有網址（空的就當沒給：丟掉這張圖）
    static func url<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        let url = c.lenientString(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: c.codingPath, debugDescription: "圖沒有網址"))
        }
        return url
    }
}

/// 陣列裡讀不進來的一筆丟掉就好（不要整個陣列都不要）
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        try? decodeIfPresent(String.self, forKey: key)
    }

    /// 數字（整數也可以）；不是數字就當沒給
    func lenientDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return d }
        return nil
    }

    /// 字串陣列；不是字串的那一行丟掉
    func lenientLines(_ key: Key) -> [String] {
        let rows = try? decodeIfPresent([Lenient<String>].self, forKey: key)
        return rows?.compactMap(\.value) ?? []
    }
}
