import Foundation

// 門市人員：在 iPad 上用 4–6 位數 PIN 登入（右側鍵盤）。PIN 的雜湊由後台算好傳過來，斷網也能登入。
// 個人的裝置（用 StudioX 帳號登入的手機）拿不到雜湊：主管授權改問後台（POSAPI.verifyPin；docs/API.md「用 StudioX 帳號登入」）。
// 和後台帳號分開：工讀生不需要能登入網站後台；需要的人可以在後台把兩個綁在一起（userId）。

public enum StaffRole: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    /// 收銀、點餐
    case cashier
    /// 領班：可以作廢品項、打折、開錢櫃
    case supervisor
    /// 店長：退款、作廢發票、交班、改桌位圖
    case manager
    /// 負責人：全部
    case owner

    public var label: String {
        switch self {
        case .cashier: "收銀"
        case .supervisor: "領班"
        case .manager: "店長"
        case .owner: "負責人"
        }
    }

    private var rank: Int {
        switch self {
        case .cashier: 0
        case .supervisor: 1
        case .manager: 2
        case .owner: 3
        }
    }

    public static func < (a: StaffRole, b: StaffRole) -> Bool { a.rank < b.rank }
}

/// 要授權的動作。每個動作「最低」要什麼職能；不夠的人做的時候，跳出右側鍵盤請主管輸入 PIN
public enum Permission: String, Codable, Sendable, CaseIterable, Hashable {
    case sell
    case discount
    case largeDiscount
    case priceOverride
    case voidSentItem
    case voidTicket
    case refund
    case voidInvoice
    case openDrawer
    case cashInOut
    case closeShift
    case viewReports
    case editFloor
    case manageReservations
    case reprintInvoice
    /// 裝置設定：換崗位、換營業模式、解除配對
    case manageDevice
    /// 叫號全部歸零（號碼從 1 重新開始）
    case resetQueue

    public var minimumRole: StaffRole {
        switch self {
        case .sell, .manageReservations: .cashier
        case .discount, .voidSentItem, .openDrawer, .priceOverride, .reprintInvoice: .supervisor
        case .largeDiscount, .voidTicket, .refund, .voidInvoice, .cashInOut, .closeShift, .viewReports, .editFloor, .manageDevice, .resetQueue: .manager
        }
    }

    public var label: String {
        switch self {
        case .sell: "點餐與收款"
        case .discount: "折扣"
        case .largeDiscount: "大額折扣"
        case .priceOverride: "改價"
        case .voidSentItem: "作廢已出單的品項"
        case .voidTicket: "作廢整張單"
        case .refund: "退款"
        case .voidInvoice: "作廢發票"
        case .openDrawer: "開錢櫃"
        case .cashInOut: "零用金存入／取出"
        case .closeShift: "交班結帳"
        case .viewReports: "看報表"
        case .editFloor: "改桌位圖"
        case .manageReservations: "訂位與候位"
        case .reprintInvoice: "補印證明聯"
        case .manageDevice: "裝置設定（崗位、解除配對）"
        case .resetQueue: "叫號歸零"
        }
    }
}

public struct StaffMember: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var role: StaffRole
    /// PBKDF2-HMAC-SHA256(pin, salt, iterations) 的十六進位。
    /// 個人的裝置的開機資料沒有這三個（4–6 位數的 PIN 在自己的手機上很容易離線試出來）：nil，這位在本機驗不了 PIN
    public var pinHash: String?
    public var pinSalt: String?
    /// 沒給＝Staff.defaultIterations
    public var pinIterations: Int?
    /// 頭像的色（Swatch）
    public var swatch: Swatch
    public var isActive: Bool
    /// 職稱（「總監」「設計師」「助理」「教練」；沒有就不顯示）
    public var title: String?
    /// 排進預約表（設計師、教練）
    public var bookable: Bool?
    /// 預設抽成（萬分比；品項自己有設就用品項的）
    public var commissionBps: Int?

    /// pinIterations 沒給：有雜湊的用 Staff.defaultIterations（和以前一樣寫進 JSON），沒有雜湊的不寫
    public init(id: String, name: String, role: StaffRole, pinHash: String? = nil, pinSalt: String? = nil, pinIterations: Int? = nil,
                swatch: Swatch = .sand, isActive: Bool = true, title: String? = nil, bookable: Bool? = nil, commissionBps: Int? = nil) {
        self.id = id; self.name = name; self.role = role; self.pinHash = pinHash; self.pinSalt = pinSalt
        self.pinIterations = pinIterations ?? (pinHash == nil ? nil : Staff.defaultIterations); self.swatch = swatch; self.isActive = isActive
        self.title = title; self.bookable = bookable; self.commissionBps = commissionBps
    }

    public var isBookable: Bool { bookable ?? false }

    public func can(_ p: Permission) -> Bool { role >= p.minimumRole }

    /// 名字的第一個字（頭像）
    public var initial: String { String(name.prefix(1)) }

    /// 這台有這位的 PIN 雜湊（店裡共用的裝置才有；個人的裝置要問後台）
    public var hasPin: Bool { pinHash?.isEmpty == false && pinSalt != nil }

    /// 在本機驗 PIN。沒有雜湊（個人的裝置）一律 false
    public func verify(pin: String) -> Bool {
        guard isActive, let pinHash, let pinSalt, let expected = Crypto.bytes(hex: pinHash), !expected.isEmpty else { return false }
        let iterations = pinIterations ?? Staff.defaultIterations
        guard iterations > 0 else { return false }
        let got = Crypto.pbkdf2SHA256(password: Array(pin.utf8), salt: Array(pinSalt.utf8), iterations: iterations, keyLength: expected.count)
        return Crypto.constantTimeEquals(got, expected)
    }
}

public enum Staff {
    /// PIN 只有 4–6 位數，雜湊再慢也擋不住窮舉；這裡的目的是不在裝置上存明碼。
    /// 真正的保護是：裝置要配對過、錯 5 次鎖 1 分鐘（App 做）、資料在 iPad 的資料保護裡。
    public static let defaultIterations = 4096

    public static func hash(pin: String, salt: String, iterations: Int = defaultIterations) -> String {
        Crypto.hex(Crypto.pbkdf2SHA256(password: Array(pin.utf8), salt: Array(salt.utf8), iterations: iterations))
    }

    /// 同一個 PIN 對到哪一位（PIN 登入不先選人時用；兩個人 PIN 一樣就回 nil，請他們先點自己）。
    /// 沒有雜湊的人（個人的裝置拿到的人員名單）跳過
    public static func match(pin: String, in staff: [StaffMember]) -> StaffMember? {
        let hits = staff.filter { $0.hasPin && $0.verify(pin: pin) }
        return hits.count == 1 ? hits[0] : nil
    }
}
