import Foundation

// 事件：POS 上發生的每一件事都是一筆不會再改的事件。單子、桌況、錢櫃、報表都是「把事件照順序重播」算出來的。
//
//   - 每台 iPad 有自己的流水號（seq）與雜湊鏈（prevHash → hash）：少一筆、被改過，後台都看得出來（防止刪單）
//   - 順序用 Lamport 時鐘（lamport）：收到別台的事件就把自己的時鐘調到比它大，所以「先看到才做的事」一定排在後面
//   - 同一串事件在每台 iPad、後台重播出來的結果一樣（StoreState.apply 只看事件內容，不看現在幾點、不看網路）
//   - 斷網時照樣記，連上後（雲端或同一個 Wi-Fi 的其他 iPad）互相補齊；用事件 id 去重，送幾次都一樣

// MARK: - 事件內容

public struct TicketOpened: Codable, Sendable, Hashable {
    public var ticketId: String
    public var number: String
    public var orderType: OrderType
    public var tableIds: [String]
    public var guests: Int
    public var serviceChargeBps: Int
    public var businessDate: String
    public var customerName: String?
    public var splitFrom: String?
    /// 開單時的營業模式
    public var serviceMode: ServiceMode?
    /// 一開單就知道是誰（美業從預約開單、健身房報到後開單）
    public var member: MemberRef?
    public var salespersonId: String?
    /// 換貨單
    public var exchange: ExchangeCredit?
    public var appointmentId: String?
    /// 外送平台的單（後台收下平台的單時寫的；docs/DELIVERY.md）
    public var delivery: DeliveryOrder?

    public init(ticketId: String, number: String, orderType: OrderType, tableIds: [String] = [], guests: Int = 0,
                serviceChargeBps: Int = 0, businessDate: String, customerName: String? = nil, splitFrom: String? = nil,
                serviceMode: ServiceMode? = nil, member: MemberRef? = nil, salespersonId: String? = nil, exchange: ExchangeCredit? = nil,
                appointmentId: String? = nil, delivery: DeliveryOrder? = nil) {
        self.ticketId = ticketId; self.number = number; self.orderType = orderType; self.tableIds = tableIds; self.guests = guests
        self.serviceChargeBps = serviceChargeBps; self.businessDate = businessDate; self.customerName = customerName; self.splitFrom = splitFrom
        self.serviceMode = serviceMode; self.member = member; self.salespersonId = salespersonId; self.exchange = exchange
        self.appointmentId = appointmentId; self.delivery = delivery
    }
}

public struct LinesAdded: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lines: [TicketLine]
    public init(ticketId: String, lines: [TicketLine]) { self.ticketId = ticketId; self.lines = lines }
}

public struct LineUpdated: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lineId: String
    public var quantity: Int?
    public var unitPrice: Money?
    public var note: String?
    public var seat: Int?
    public var course: Int?
    public var modifiers: [AppliedModifier]?
    public var discount: Discount?
    public var clearDiscount: Bool?
    /// 改價、折扣的授權主管
    public var authorizedBy: String?
    /// 業績算給誰（"" = 拿掉，回到整單的銷售人員）
    public var staffId: String?
    /// 助理（"" = 拿掉）
    public var assistantId: String?
    public var commissionBps: Int?
    /// 用課程卡抵
    public var redeem: PassRedemption?
    public var clearRedeem: Bool?
    /// 會籍續約：接在舊的到期日後面
    public var passStartsAt: Date?
    /// 換規格（還沒結帳前換尺寸）
    public var skuId: String?
    public var variantName: String?
    public var variantId: String?

    public init(ticketId: String, lineId: String, quantity: Int? = nil, unitPrice: Money? = nil, note: String? = nil, seat: Int? = nil,
                course: Int? = nil, modifiers: [AppliedModifier]? = nil, discount: Discount? = nil, clearDiscount: Bool? = nil, authorizedBy: String? = nil,
                staffId: String? = nil, assistantId: String? = nil, commissionBps: Int? = nil, redeem: PassRedemption? = nil, clearRedeem: Bool? = nil,
                passStartsAt: Date? = nil, skuId: String? = nil, variantName: String? = nil, variantId: String? = nil) {
        self.ticketId = ticketId; self.lineId = lineId; self.quantity = quantity; self.unitPrice = unitPrice; self.note = note
        self.seat = seat; self.course = course; self.modifiers = modifiers; self.discount = discount
        self.clearDiscount = clearDiscount; self.authorizedBy = authorizedBy
        self.staffId = staffId; self.assistantId = assistantId; self.commissionBps = commissionBps; self.redeem = redeem
        self.clearRedeem = clearRedeem; self.passStartsAt = passStartsAt; self.skuId = skuId; self.variantName = variantName; self.variantId = variantId
    }
}

public struct LinesVoided: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lineIds: [String]
    public var reason: String
    public var authorizedBy: String?
    public init(ticketId: String, lineIds: [String], reason: String, authorizedBy: String? = nil) {
        self.ticketId = ticketId; self.lineIds = lineIds; self.reason = reason; self.authorizedBy = authorizedBy
    }
}

/// 刪掉還沒送出的品項：直接從單子拿掉、不留紀錄（已經送出的要用 lines.voided：廚房要知道、要印作廢單）
public struct LinesRemoved: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lineIds: [String]
    public init(ticketId: String, lineIds: [String]) { self.ticketId = ticketId; self.lineIds = lineIds }
}

public struct LinesSent: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lineIds: [String]
    /// 送單的這台沒有廚房出單機（前場的手機）：請櫃台幫忙印。`new` 第一次送、`add` 加點、`fire` 催菜；沒有＝已經印了或不用印
    public var relayPrint: String?
    public init(ticketId: String, lineIds: [String], relayPrint: String? = nil) {
        self.ticketId = ticketId; self.lineIds = lineIds; self.relayPrint = relayPrint
    }
}

public struct KitchenUpdated: Codable, Sendable, Hashable {
    public var ticketId: String
    public var lineIds: [String]
    public var status: KitchenStatus
    public init(ticketId: String, lineIds: [String], status: KitchenStatus) {
        self.ticketId = ticketId; self.lineIds = lineIds; self.status = status
    }
}

public struct TicketUpdated: Codable, Sendable, Hashable {
    public var ticketId: String
    public var guests: Int?
    public var note: String?
    public var orderType: OrderType?
    public var serviceChargeBps: Int?
    public var discount: Discount?
    public var clearDiscount: Bool?
    public var tip: Money?
    public var invoiceBuyer: InvoiceBuyer?
    public var member: MemberRef?
    public var clearMember: Bool?
    public var customerName: String?
    /// 整張單的銷售人員（"" = 拿掉）
    public var salespersonId: String?
    /// 叫號的號碼（外帶結帳時自動取的、排隊入座時叫到的；0＝拿掉）
    public var queueNumber: Int?

    public init(ticketId: String, guests: Int? = nil, note: String? = nil, orderType: OrderType? = nil, serviceChargeBps: Int? = nil,
                discount: Discount? = nil, clearDiscount: Bool? = nil, tip: Money? = nil, invoiceBuyer: InvoiceBuyer? = nil,
                member: MemberRef? = nil, clearMember: Bool? = nil, customerName: String? = nil, salespersonId: String? = nil,
                queueNumber: Int? = nil) {
        self.ticketId = ticketId; self.guests = guests; self.note = note; self.orderType = orderType
        self.serviceChargeBps = serviceChargeBps; self.discount = discount; self.clearDiscount = clearDiscount; self.tip = tip
        self.invoiceBuyer = invoiceBuyer; self.member = member; self.clearMember = clearMember; self.customerName = customerName
        self.salespersonId = salespersonId; self.queueNumber = queueNumber
    }
}

public struct TicketMoved: Codable, Sendable, Hashable {
    public var ticketId: String
    public var tableIds: [String]
    public init(ticketId: String, tableIds: [String]) { self.ticketId = ticketId; self.tableIds = tableIds }
}

public struct TicketsMerged: Codable, Sendable, Hashable {
    /// 併到這一張
    public var targetId: String
    /// 這一張的品項、付款全部搬過去，然後關掉
    public var sourceId: String
    public init(targetId: String, sourceId: String) { self.targetId = targetId; self.sourceId = sourceId }
}

public struct SplitMove: Codable, Sendable, Hashable {
    public var lineId: String
    public var quantity: Int
    /// 搬到新單上的那一行的 id（只搬一部分數量時，原來那行留著、數量減少）
    public var newLineId: String
    public init(lineId: String, quantity: Int, newLineId: String) { self.lineId = lineId; self.quantity = quantity; self.newLineId = newLineId }
}

public struct TicketSplit: Codable, Sendable, Hashable {
    public var sourceId: String
    public var opened: TicketOpened
    public var moves: [SplitMove]
    public init(sourceId: String, opened: TicketOpened, moves: [SplitMove]) { self.sourceId = sourceId; self.opened = opened; self.moves = moves }
}

public struct TicketRef: Codable, Sendable, Hashable {
    public var ticketId: String
    /// 只有 `bill.printed` 用：不是在這裡印結帳單，而是不收錢的裝置（前場的手機、報到接待）把單「送到結帳櫃台」——
    /// 寫從哪裡送來的（「手機」「報到接待」），櫃台跳出「A2 從手機送來結帳」。nil＝真的印了結帳單。
    /// 舊版 App 不認得這個欄位：照樣當成「待結帳」
    public var sentFrom: String?

    public init(ticketId: String, sentFrom: String? = nil) {
        self.ticketId = ticketId
        self.sentFrom = sentFrom
    }
}

public struct PaymentAdded: Codable, Sendable, Hashable {
    public var ticketId: String
    public var payment: Payment
    public init(ticketId: String, payment: Payment) { self.ticketId = ticketId; self.payment = payment }
}

public struct PaymentVoided: Codable, Sendable, Hashable {
    public var ticketId: String
    public var paymentId: String
    public var reason: String
    public var authorizedBy: String?
    public init(ticketId: String, paymentId: String, reason: String, authorizedBy: String? = nil) {
        self.ticketId = ticketId; self.paymentId = paymentId; self.reason = reason; self.authorizedBy = authorizedBy
    }
}

public struct InvoiceIssued: Codable, Sendable, Hashable {
    public var ticketId: String
    public var invoice: EInvoice
    public init(ticketId: String, invoice: EInvoice) { self.ticketId = ticketId; self.invoice = invoice }
}

public struct InvoiceVoided: Codable, Sendable, Hashable {
    public var ticketId: String
    public var number: String
    public var reason: String
    public var authorizedBy: String?
    public init(ticketId: String, number: String, reason: String, authorizedBy: String? = nil) {
        self.ticketId = ticketId; self.number = number; self.reason = reason; self.authorizedBy = authorizedBy
    }
}

public struct TicketClosed: Codable, Sendable, Hashable {
    public var ticketId: String
    public var sale: SaleRecord
    public init(ticketId: String, sale: SaleRecord) { self.ticketId = ticketId; self.sale = sale }
}

public struct TicketVoided: Codable, Sendable, Hashable {
    public var ticketId: String
    public var reason: String
    public var authorizedBy: String?
    public init(ticketId: String, reason: String, authorizedBy: String? = nil) {
        self.ticketId = ticketId; self.reason = reason; self.authorizedBy = authorizedBy
    }
}

public struct SaleRefunded: Codable, Sendable, Hashable {
    public var ticketId: String
    public var refund: Refund
    public var allowance: EInvoiceAllowance?
    public init(ticketId: String, refund: Refund, allowance: EInvoiceAllowance? = nil) {
        self.ticketId = ticketId; self.refund = refund; self.allowance = allowance
    }
}

public struct TableRef: Codable, Sendable, Hashable {
    public var tableId: String
    public init(tableId: String) { self.tableId = tableId }
}

public struct ShiftOpened: Codable, Sendable, Hashable {
    public var shiftId: String
    public var openingCash: Money
    public var businessDate: String
    public init(shiftId: String, openingCash: Money, businessDate: String) {
        self.shiftId = shiftId; self.openingCash = openingCash; self.businessDate = businessDate
    }
}

public struct CashMoved: Codable, Sendable, Hashable {
    public var shiftId: String
    public var move: CashMove
    public init(shiftId: String, move: CashMove) { self.shiftId = shiftId; self.move = move }
}

public struct ShiftClosed: Codable, Sendable, Hashable {
    public var shiftId: String
    public var counted: CashCount
    public var expected: Money
    public var note: String
    /// 交班單（後台存起來、推播給負責人）
    public var report: ShiftReport?
    public init(shiftId: String, counted: CashCount, expected: Money, note: String = "", report: ShiftReport? = nil) {
        self.shiftId = shiftId; self.counted = counted; self.expected = expected; self.note = note; self.report = report
    }
}

public struct StaffRef: Codable, Sendable, Hashable {
    public var staffId: String
    public init(staffId: String) { self.staffId = staffId }
}

public struct ItemAvailability: Codable, Sendable, Hashable {
    public var itemId: String
    public var available: Bool
    public init(itemId: String, available: Bool) { self.itemId = itemId; self.available = available }
}

/// 結帳後同款換規格（換尺寸、換顏色）：不動錢、不動發票，後台照這個調庫存
public struct SaleExchanged: Codable, Sendable, Hashable {
    public var ticketId: String
    public var swaps: [VariantSwap]
    public var reason: String
    public init(ticketId: String, swaps: [VariantSwap], reason: String = "") { self.ticketId = ticketId; self.swaps = swaps; self.reason = reason }
}

/// 入場報到（at、by 由事件本身決定，內容裡的會被蓋掉）
public struct CheckedIn: Codable, Sendable, Hashable {
    public var checkIn: CheckIn
    public init(checkIn: CheckIn) { self.checkIn = checkIn }
}

public struct CheckInVoided: Codable, Sendable, Hashable {
    public var checkInId: String
    public var reason: String
    public init(checkInId: String, reason: String) { self.checkInId = checkInId; self.reason = reason }
}

// MARK: - 事件種類

public enum EventBody: Sendable, Hashable {
    case ticketOpened(TicketOpened)
    case linesAdded(LinesAdded)
    case lineUpdated(LineUpdated)
    case linesVoided(LinesVoided)
    case linesSent(LinesSent)
    case linesRemoved(LinesRemoved)
    case kitchenUpdated(KitchenUpdated)
    case ticketUpdated(TicketUpdated)
    case ticketMoved(TicketMoved)
    case ticketsMerged(TicketsMerged)
    case ticketSplit(TicketSplit)
    case billPrinted(TicketRef)
    case paymentAdded(PaymentAdded)
    case paymentVoided(PaymentVoided)
    case invoiceIssued(InvoiceIssued)
    case invoiceVoided(InvoiceVoided)
    case ticketClosed(TicketClosed)
    case ticketVoided(TicketVoided)
    case saleRefunded(SaleRefunded)
    case tableCleaned(TableRef)
    case shiftOpened(ShiftOpened)
    case cashMoved(CashMoved)
    case shiftClosed(ShiftClosed)
    case clockedIn(StaffRef)
    case clockedOut(StaffRef)
    case itemAvailability(ItemAvailability)
    case saleExchanged(SaleExchanged)
    case checkedIn(CheckedIn)
    case checkInVoided(CheckInVoided)
    /// 外送平台那邊的狀態變了（後台寫的）
    case deliveryUpdated(DeliveryUpdated)
    /// 這個版本不認得的事件（新版 App 送來的）：原樣保留、轉送，不做投影
    case unknown(type: String, data: String)

    /// 事件的種類名稱（API 的 type 欄位；後台用它分流）
    public var type: String {
        switch self {
        case .ticketOpened: "ticket.opened"
        case .linesAdded: "lines.added"
        case .lineUpdated: "line.updated"
        case .linesVoided: "lines.voided"
        case .linesSent: "lines.sent"
        case .linesRemoved: "lines.removed"
        case .kitchenUpdated: "kitchen.updated"
        case .ticketUpdated: "ticket.updated"
        case .ticketMoved: "ticket.moved"
        case .ticketsMerged: "tickets.merged"
        case .ticketSplit: "ticket.split"
        case .billPrinted: "bill.printed"
        case .paymentAdded: "payment.added"
        case .paymentVoided: "payment.voided"
        case .invoiceIssued: "invoice.issued"
        case .invoiceVoided: "invoice.voided"
        case .ticketClosed: "ticket.closed"
        case .ticketVoided: "ticket.voided"
        case .saleRefunded: "sale.refunded"
        case .tableCleaned: "table.cleaned"
        case .shiftOpened: "shift.opened"
        case .cashMoved: "cash.moved"
        case .shiftClosed: "shift.closed"
        case .clockedIn: "staff.clockedIn"
        case .clockedOut: "staff.clockedOut"
        case .itemAvailability: "item.availability"
        case .saleExchanged: "sale.exchanged"
        case .checkedIn: "member.checkedIn"
        case .checkInVoided: "member.checkInVoided"
        case .deliveryUpdated: "delivery.updated"
        case .unknown(let type, _): type
        }
    }

    /// 跟哪一張單有關（後台建索引、App 篩選）
    public var ticketId: String? {
        switch self {
        case .ticketOpened(let e): e.ticketId
        case .linesAdded(let e): e.ticketId
        case .lineUpdated(let e): e.ticketId
        case .linesVoided(let e): e.ticketId
        case .linesSent(let e): e.ticketId
        case .linesRemoved(let e): e.ticketId
        case .kitchenUpdated(let e): e.ticketId
        case .ticketUpdated(let e): e.ticketId
        case .ticketMoved(let e): e.ticketId
        case .ticketsMerged(let e): e.targetId
        case .ticketSplit(let e): e.sourceId
        case .billPrinted(let e): e.ticketId
        case .paymentAdded(let e): e.ticketId
        case .paymentVoided(let e): e.ticketId
        case .invoiceIssued(let e): e.ticketId
        case .invoiceVoided(let e): e.ticketId
        case .ticketClosed(let e): e.ticketId
        case .ticketVoided(let e): e.ticketId
        case .saleRefunded(let e): e.ticketId
        case .saleExchanged(let e): e.ticketId
        case .deliveryUpdated(let e): e.ticketId
        case .tableCleaned, .shiftOpened, .cashMoved, .shiftClosed, .clockedIn, .clockedOut, .itemAvailability, .checkedIn, .checkInVoided, .unknown: nil
        }
    }

    /// 事件內容的 JSON（雜湊、傳輸都用這一串，接收端不重新排版）
    public func encodedData() throws -> String {
        let encoder = EventCoding.encoder()
        let data: Data = switch self {
        case .ticketOpened(let e): try encoder.encode(e)
        case .linesAdded(let e): try encoder.encode(e)
        case .lineUpdated(let e): try encoder.encode(e)
        case .linesVoided(let e): try encoder.encode(e)
        case .linesSent(let e): try encoder.encode(e)
        case .linesRemoved(let e): try encoder.encode(e)
        case .kitchenUpdated(let e): try encoder.encode(e)
        case .ticketUpdated(let e): try encoder.encode(e)
        case .ticketMoved(let e): try encoder.encode(e)
        case .ticketsMerged(let e): try encoder.encode(e)
        case .ticketSplit(let e): try encoder.encode(e)
        case .billPrinted(let e): try encoder.encode(e)
        case .paymentAdded(let e): try encoder.encode(e)
        case .paymentVoided(let e): try encoder.encode(e)
        case .invoiceIssued(let e): try encoder.encode(e)
        case .invoiceVoided(let e): try encoder.encode(e)
        case .ticketClosed(let e): try encoder.encode(e)
        case .ticketVoided(let e): try encoder.encode(e)
        case .saleRefunded(let e): try encoder.encode(e)
        case .tableCleaned(let e): try encoder.encode(e)
        case .shiftOpened(let e): try encoder.encode(e)
        case .cashMoved(let e): try encoder.encode(e)
        case .shiftClosed(let e): try encoder.encode(e)
        case .clockedIn(let e): try encoder.encode(e)
        case .clockedOut(let e): try encoder.encode(e)
        case .itemAvailability(let e): try encoder.encode(e)
        case .saleExchanged(let e): try encoder.encode(e)
        case .checkedIn(let e): try encoder.encode(e)
        case .checkInVoided(let e): try encoder.encode(e)
        case .deliveryUpdated(let e): try encoder.encode(e)
        case .unknown(_, let raw): Data(raw.utf8)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(type: String, data: String) throws -> EventBody {
        let d = EventCoding.decoder()
        let bytes = Data(data.utf8)
        switch type {
        case "ticket.opened": return .ticketOpened(try d.decode(TicketOpened.self, from: bytes))
        case "lines.added": return .linesAdded(try d.decode(LinesAdded.self, from: bytes))
        case "line.updated": return .lineUpdated(try d.decode(LineUpdated.self, from: bytes))
        case "lines.voided": return .linesVoided(try d.decode(LinesVoided.self, from: bytes))
        case "lines.sent": return .linesSent(try d.decode(LinesSent.self, from: bytes))
        case "lines.removed": return .linesRemoved(try d.decode(LinesRemoved.self, from: bytes))
        case "kitchen.updated": return .kitchenUpdated(try d.decode(KitchenUpdated.self, from: bytes))
        case "ticket.updated": return .ticketUpdated(try d.decode(TicketUpdated.self, from: bytes))
        case "ticket.moved": return .ticketMoved(try d.decode(TicketMoved.self, from: bytes))
        case "tickets.merged": return .ticketsMerged(try d.decode(TicketsMerged.self, from: bytes))
        case "ticket.split": return .ticketSplit(try d.decode(TicketSplit.self, from: bytes))
        case "bill.printed": return .billPrinted(try d.decode(TicketRef.self, from: bytes))
        case "payment.added": return .paymentAdded(try d.decode(PaymentAdded.self, from: bytes))
        case "payment.voided": return .paymentVoided(try d.decode(PaymentVoided.self, from: bytes))
        case "invoice.issued": return .invoiceIssued(try d.decode(InvoiceIssued.self, from: bytes))
        case "invoice.voided": return .invoiceVoided(try d.decode(InvoiceVoided.self, from: bytes))
        case "ticket.closed": return .ticketClosed(try d.decode(TicketClosed.self, from: bytes))
        case "ticket.voided": return .ticketVoided(try d.decode(TicketVoided.self, from: bytes))
        case "sale.refunded": return .saleRefunded(try d.decode(SaleRefunded.self, from: bytes))
        case "table.cleaned": return .tableCleaned(try d.decode(TableRef.self, from: bytes))
        case "shift.opened": return .shiftOpened(try d.decode(ShiftOpened.self, from: bytes))
        case "cash.moved": return .cashMoved(try d.decode(CashMoved.self, from: bytes))
        case "shift.closed": return .shiftClosed(try d.decode(ShiftClosed.self, from: bytes))
        case "staff.clockedIn": return .clockedIn(try d.decode(StaffRef.self, from: bytes))
        case "staff.clockedOut": return .clockedOut(try d.decode(StaffRef.self, from: bytes))
        case "item.availability": return .itemAvailability(try d.decode(ItemAvailability.self, from: bytes))
        case "sale.exchanged": return .saleExchanged(try d.decode(SaleExchanged.self, from: bytes))
        case "member.checkedIn": return .checkedIn(try d.decode(CheckedIn.self, from: bytes))
        case "member.checkInVoided": return .checkInVoided(try d.decode(CheckInVoided.self, from: bytes))
        case "delivery.updated": return .deliveryUpdated(try d.decode(DeliveryUpdated.self, from: bytes))
        default: return .unknown(type: type, data: data)
        }
    }
}

public enum EventError: Error, Equatable, Sendable {
    case unknownType(String)
    case badHash(id: String)
    case brokenChain(deviceId: String, seq: Int)
}

// MARK: - 信封

/// 一筆事件（傳輸與存檔的格式）。欄位與 docs/API.md 的「事件」一節一致
public struct POSEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let deviceId: String
    /// 這台裝置的流水號（從 1 開始、不跳號）
    public let seq: Int
    public let lamport: Int
    /// ISO 8601（UTC、毫秒）：原樣存、原樣雜湊
    public let at: String
    public let staffId: String?
    public let type: String
    /// 事件內容的 JSON 字串
    public let data: String
    public let prevHash: String
    public let hash: String
    /// 後台收到的順序（後台給的；拉別台的事件時用來接續）
    public var serverSeq: Int?
    /// 解開的內容（不進 JSON）
    public let body: EventBody

    public static let genesis = String(repeating: "0", count: 64)

    enum CodingKeys: String, CodingKey {
        case id, deviceId, seq, lamport, at, staffId, type, data, prevHash, hash, serverSeq
    }

    public init(id: String, deviceId: String, seq: Int, lamport: Int, at: Date, staffId: String?, body: EventBody, prevHash: String) throws {
        self.id = id
        self.deviceId = deviceId
        self.seq = seq
        self.lamport = lamport
        self.at = EventCoding.timestamp(at)
        self.staffId = staffId
        self.type = body.type
        self.data = try body.encodedData()
        self.prevHash = prevHash
        self.body = body
        self.serverSeq = nil
        self.hash = POSEvent.computeHash(id: id, deviceId: deviceId, seq: seq, lamport: lamport, at: self.at, staffId: staffId,
                                         type: type, data: data, prevHash: prevHash)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        seq = try c.decode(Int.self, forKey: .seq)
        lamport = try c.decode(Int.self, forKey: .lamport)
        at = try c.decode(String.self, forKey: .at)
        staffId = try c.decodeIfPresent(String.self, forKey: .staffId)
        type = try c.decode(String.self, forKey: .type)
        data = try c.decode(String.self, forKey: .data)
        prevHash = try c.decode(String.self, forKey: .prevHash)
        hash = try c.decode(String.self, forKey: .hash)
        serverSeq = try c.decodeIfPresent(Int.self, forKey: .serverSeq)
        body = try EventBody.decode(type: type, data: data)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(seq, forKey: .seq)
        try c.encode(lamport, forKey: .lamport)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(staffId, forKey: .staffId)
        try c.encode(type, forKey: .type)
        try c.encode(data, forKey: .data)
        try c.encode(prevHash, forKey: .prevHash)
        try c.encode(hash, forKey: .hash)
        try c.encodeIfPresent(serverSeq, forKey: .serverSeq)
    }

    public var date: Date { EventCoding.parseTimestamp(at) ?? .distantPast }

    /// 雜湊：SHA-256(id|deviceId|seq|lamport|at|staffId|type|prevHash|data) 的小寫十六進位。
    /// 用「|」接起來的字串而不是重新排版的 JSON：後台（Node）照同樣的規則接字串就能驗，不必和 Swift 的 JSON 排版一模一樣
    public static func computeHash(id: String, deviceId: String, seq: Int, lamport: Int, at: String, staffId: String?,
                                   type: String, data: String, prevHash: String) -> String {
        Crypto.SHA256.hex([id, deviceId, String(seq), String(lamport), at, staffId ?? "", type, prevHash, data].joined(separator: "|"))
    }

    public var isHashValid: Bool {
        hash == POSEvent.computeHash(id: id, deviceId: deviceId, seq: seq, lamport: lamport, at: at, staffId: staffId,
                                     type: type, data: data, prevHash: prevHash)
    }

    /// 重播的順序：Lamport → 裝置 → 流水號（每台都排得一樣）
    public static func replayOrder(_ a: POSEvent, _ b: POSEvent) -> Bool {
        if a.lamport != b.lamport { return a.lamport < b.lamport }
        if a.deviceId != b.deviceId { return a.deviceId < b.deviceId }
        return a.seq < b.seq
    }
}

public enum EventCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(timestamp(date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseTimestamp(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "日期格式不對：\(s)")
            }
            return date
        }
        return d
    }

    /// 2026-10-03T06:05:22.123Z（UTC、毫秒；自己組字串，iPad 與 Linux 一模一樣）
    public static func timestamp(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded())
        let whole = Date(timeIntervalSince1970: TimeInterval(ms / 1000))
        let p = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", p.year ?? 0, p.month ?? 0, p.day ?? 0,
                      p.hour ?? 0, p.minute ?? 0, p.second ?? 0, ((ms % 1000) + 1000) % 1000)
    }

    public static func parseTimestamp(_ s: String) -> Date? {
        // 2026-10-03T06:05:22.123Z 或沒有毫秒
        let chars = Array(s.utf8)
        guard chars.count >= 20, chars.last == UInt8(ascii: "Z") else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= chars.count else { return nil }
            var v = 0
            for i in from..<from + len {
                let ch = chars[i]
                guard ch >= 48, ch <= 57 else { return nil }
                v = v * 10 + Int(ch - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
        var ms = 0
        if chars.count > 20, chars[19] == UInt8(ascii: ".") {
            let digits = chars.count - 21
            guard digits >= 1, let frac = num(20, digits) else { return nil }
            ms = digits >= 3 ? frac / Int(pow(10, Double(digits - 3))) : frac * Int(pow(10, Double(3 - digits)))
        }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        guard let base = c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)) else { return nil }
        return base.addingTimeInterval(TimeInterval(ms) / 1000)
    }
}
