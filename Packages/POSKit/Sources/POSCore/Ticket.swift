import Foundation

// 單子（一桌、一組外帶客人）。單子本身不存：它是從事件一筆一筆算出來的（StoreState），
// 所以每台 iPad、伺服器看到的同一張單一定一樣。

/// 折扣：百分比（萬分比，1000 = 打九折）或固定金額
public struct Discount: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case percent, amount
    }

    public var kind: Kind
    /// percent：萬分比；amount：分
    public var value: Int
    public var reason: String
    /// 超過權限時，授權的主管
    public var authorizedBy: String?

    public init(kind: Kind, value: Int, reason: String = "", authorizedBy: String? = nil) {
        self.kind = kind; self.value = value; self.reason = reason; self.authorizedBy = authorizedBy
    }

    public static func percent(_ bps: Int, reason: String = "", authorizedBy: String? = nil) -> Discount {
        Discount(kind: .percent, value: bps, reason: reason, authorizedBy: authorizedBy)
    }

    public static func amount(_ m: Money, reason: String = "", authorizedBy: String? = nil) -> Discount {
        Discount(kind: .amount, value: m.cents, reason: reason, authorizedBy: authorizedBy)
    }

    /// 這個折扣用在 base 上折掉多少（不會超過 base）
    public func amount(on base: Money) -> Money {
        guard base.cents > 0 else { return .zero }
        switch kind {
        case .percent: return min(base.applying(bps: min(max(value, 0), 10_000)), base)
        case .amount: return min(Money(cents: max(value, 0)).roundedToDollar(), base)
        }
    }

    /// 「9 折」「−$50」
    public var label: String {
        switch kind {
        case .percent:
            let rest = 10_000 - value
            if rest <= 0 { return "招待" }
            if rest % 1000 == 0 { return "\(rest / 1000) 折" }
            if rest % 100 == 0 { return "\(rest / 100) 折" }
            return "−\(percentText(bps: value))"
        case .amount: return "−" + Money(cents: value).short
        }
    }

    /// 折扣占 base 多少萬分比（判斷要不要主管授權）
    public func bps(on base: Money) -> Int {
        switch kind {
        case .percent: return value
        case .amount: return base.cents > 0 ? Int((Double(value) / Double(base.cents) * 10_000).rounded()) : 0
        }
    }
}

public struct AppliedModifier: Codable, Sendable, Hashable {
    public var groupId: String
    public var groupName: String
    public var optionId: String
    public var name: String
    public var priceDelta: Money

    public init(groupId: String, groupName: String, optionId: String, name: String, priceDelta: Money = .zero) {
        self.groupId = groupId; self.groupName = groupName; self.optionId = optionId; self.name = name; self.priceDelta = priceDelta
    }
}

/// 出餐進度（廚房螢幕）
public enum KitchenStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// 還沒送出（可以改、刪不用主管）
    case new
    /// 送到廚房了
    case sent
    case preparing
    /// 做好了、等上菜
    case ready
    /// 上桌了
    case served

    public var label: String {
        switch self {
        case .new: "未送出"
        case .sent: "已送單"
        case .preparing: "製作中"
        case .ready: "可出餐"
        case .served: "已上菜"
        }
    }
}

public struct VoidInfo: Codable, Sendable, Hashable {
    public var reason: String
    public var by: String
    public var authorizedBy: String?
    public var at: Date
    /// 作廢時已經送到廚房了（報表上的「損耗」）
    public var wasSent: Bool

    public init(reason: String, by: String, authorizedBy: String? = nil, at: Date, wasSent: Bool) {
        self.reason = reason; self.by = by; self.authorizedBy = authorizedBy; self.at = at; self.wasSent = wasSent
    }
}

/// 這一行用客人的課程卡抵（不收錢；業績照每次的價值算）
public struct PassRedemption: Codable, Sendable, Hashable {
    public var passId: String
    /// 「剪髮 10 次卡」
    public var name: String
    /// 每次的價值（卡價 ÷ 次數；業績、報表用，不是收的錢）
    public var value: Money

    public init(passId: String, name: String, value: Money) {
        self.passId = passId; self.name = name; self.value = value
    }
}

public struct TicketLine: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// 菜單上的品項（自訂品項是 nil）
    public var itemId: String?
    public var name: String
    public var categoryId: String?
    public var categoryName: String?
    /// 單價（不含加料），加進單子時的價格
    public var unitPrice: Money
    public var modifiers: [AppliedModifier]
    public var quantity: Int
    public var note: String
    public var discount: Discount?
    /// 第幾位客人（分開結帳用）
    public var seat: Int?
    /// 第幾道（0 = 馬上做；1、2、3 = 等「催菜」再做）
    public var course: Int
    public var station: String?
    public var taxKind: TaxKind
    public var addedAt: Date
    public var addedBy: String
    public var sentAt: Date?
    public var kitchen: KitchenStatus
    public var voided: VoidInfo?
    /// 網路商店的商品與規格（賣出扣同一份庫存）
    public var productId: String?
    public var variantId: String?

    // 以下是非餐飲業用的欄位（沒有就是 nil，JSON 裡不出現）

    /// 品項種類（nil = 一般商品）
    public var kind: ItemKind?
    /// 門市的規格 id（ItemVariant.id）
    public var skuId: String?
    /// 「黑・M」
    public var variantName: String?
    /// 業績算給誰（設計師、教練、店員；nil = 整張單的銷售人員或開單的人）
    public var staffId: String?
    /// 助理（洗髮、吹整）
    public var assistantId: String?
    /// 服務要多久（分鐘）
    public var durationMinutes: Int?
    /// 賣出的課程卡／會籍的規則（加進來那一刻抄一份）
    public var pass: PassSpec?
    /// 會籍續約：新的這張從哪一天開始（接在舊的到期日後面；nil = 結帳那天）
    public var passStartsAt: Date?
    /// 儲值：每一份加多少儲值金
    public var credit: Money?
    /// 用客人的課程卡抵
    public var redeem: PassRedemption?
    /// 抽成（萬分比）：品項的，沒有就用服務人員的
    public var commissionBps: Int?
    /// 出餐進度最後一次改的時間（廚房螢幕的「剛出餐」）
    public var kitchenAt: Date?

    public init(
        id: String, itemId: String?, name: String, categoryId: String? = nil, categoryName: String? = nil,
        unitPrice: Money, modifiers: [AppliedModifier] = [], quantity: Int = 1, note: String = "", discount: Discount? = nil,
        seat: Int? = nil, course: Int = 0, station: String? = nil, taxKind: TaxKind = .taxable, addedAt: Date, addedBy: String,
        sentAt: Date? = nil, kitchen: KitchenStatus = .new, voided: VoidInfo? = nil, productId: String? = nil, variantId: String? = nil,
        kind: ItemKind? = nil, skuId: String? = nil, variantName: String? = nil, staffId: String? = nil, assistantId: String? = nil,
        durationMinutes: Int? = nil, pass: PassSpec? = nil, passStartsAt: Date? = nil, credit: Money? = nil,
        redeem: PassRedemption? = nil, commissionBps: Int? = nil
    ) {
        self.id = id; self.itemId = itemId; self.name = name; self.categoryId = categoryId; self.categoryName = categoryName
        self.unitPrice = unitPrice; self.modifiers = modifiers; self.quantity = quantity; self.note = note; self.discount = discount
        self.seat = seat; self.course = course; self.station = station; self.taxKind = taxKind; self.addedAt = addedAt
        self.addedBy = addedBy; self.sentAt = sentAt; self.kitchen = kitchen; self.voided = voided
        self.productId = productId; self.variantId = variantId
        self.kind = kind; self.skuId = skuId; self.variantName = variantName; self.staffId = staffId; self.assistantId = assistantId
        self.durationMinutes = durationMinutes; self.pass = pass; self.passStartsAt = passStartsAt; self.credit = credit
        self.redeem = redeem; self.commissionBps = commissionBps
    }

    public var isActive: Bool { voided == nil }
    public var isSent: Bool { kitchen != .new }
    public var itemKind: ItemKind { kind ?? .goods }

    /// 單價＋加料（用課程卡抵的是 0）
    public var unitTotal: Money { redeem != nil ? .zero : unitPrice + Money.sum(modifiers.map(\.priceDelta)) }
    /// 小計（折扣前）
    public var gross: Money { unitTotal * quantity }
    public var lineDiscount: Money { discount?.amount(on: gross) ?? .zero }
    /// 課程卡抵掉的價值（業績用）
    public var redeemedValue: Money { (redeem?.value ?? .zero) * quantity }

    /// 「半糖・少冰・加珍珠」
    public var modifierText: String { modifiers.map(\.name).joined(separator: "・") }

    /// 「經典直筒褲 黑・M」
    public var displayName: String { variantName.map { "\(name) \($0)" } ?? name }

    /// 同一個品項、同樣的加料與備註、還沒送出：再點一次就加數量，不另起一行
    public func canMerge(with other: TicketLine) -> Bool {
        itemId != nil && itemId == other.itemId && unitPrice == other.unitPrice && modifiers == other.modifiers
            && note == other.note && discount == nil && other.discount == nil && seat == other.seat && course == other.course
            && skuId == other.skuId && staffId == other.staffId && assistantId == other.assistantId && redeem == other.redeem
            && passStartsAt == other.passStartsAt
            && !isSent && !other.isSent && isActive && other.isActive
    }
}

/// 換貨：退回原單的哪些品項、值多少（新單結帳時當作付款抵掉）
public struct ExchangeCredit: Codable, Sendable, Hashable {
    /// 原單
    public var ticketId: String
    public var number: String
    public var lines: [RefundLine]
    /// 退回的品項值多少（照原單實收）
    public var amount: Money

    public init(ticketId: String, number: String, lines: [RefundLine], amount: Money) {
        self.ticketId = ticketId; self.number = number; self.lines = lines; self.amount = amount
    }
}

/// 同款換規格（換尺寸、換顏色、價格一樣）：不動錢、不動發票，只記庫存
public struct VariantSwap: Codable, Sendable, Hashable {
    public var lineId: String
    public var quantity: Int
    public var fromSkuId: String?
    public var toSkuId: String
    public var toVariantName: String
    /// 新規格在網路商店的規格（扣庫存）
    public var toProductVariantId: String?

    public init(lineId: String, quantity: Int, fromSkuId: String?, toSkuId: String, toVariantName: String, toProductVariantId: String? = nil) {
        self.lineId = lineId; self.quantity = quantity; self.fromSkuId = fromSkuId; self.toSkuId = toSkuId
        self.toVariantName = toVariantName; self.toProductVariantId = toProductVariantId
    }
}

/// 會員（用電話查到的）
public struct MemberRef: Codable, Sendable, Hashable {
    public var id: String?
    public var phone: String
    public var name: String?
    public var tierName: String?

    public init(id: String? = nil, phone: String, name: String? = nil, tierName: String? = nil) {
        self.id = id; self.phone = phone; self.name = name; self.tierName = tierName
    }

    /// 0912-***-678
    public var maskedPhone: String {
        let d = phone.filter(\.isNumber)
        guard d.count >= 10 else { return phone }
        return "\(d.prefix(4))-***-\(d.suffix(3))"
    }
}

public enum TicketStatus: String, Codable, Sendable, Hashable {
    case open, closed, voided
}

/// 開出去的發票（單子上記一份，細節在 POSInvoice）
public struct InvoiceStamp: Codable, Sendable, Hashable {
    /// AB12345678
    public var number: String
    public var randomCode: String
    /// 期別（民國年＋雙數月，11510）
    public var period: String
    public var issuedAt: Date
    public var buyer: InvoiceBuyer
    public var total: Money
    public var voidedAt: Date?
    public var voidReason: String?

    public init(number: String, randomCode: String, period: String, issuedAt: Date, buyer: InvoiceBuyer, total: Money, voidedAt: Date? = nil, voidReason: String? = nil) {
        self.number = number; self.randomCode = randomCode; self.period = period; self.issuedAt = issuedAt
        self.buyer = buyer; self.total = total; self.voidedAt = voidedAt; self.voidReason = voidReason
    }

    public var isVoided: Bool { voidedAt != nil }
    /// AB-12345678
    public var display: String { number.count == 10 ? "\(number.prefix(2))-\(number.suffix(8))" : number }
}

public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// 畫面與廚房單上的號碼（A023）
    public var number: String
    public var deviceId: String
    public var orderType: OrderType
    public var tableIds: [String]
    public var guests: Int
    public var lines: [TicketLine]
    public var discount: Discount?
    public var serviceChargeBps: Int
    public var tip: Money
    public var member: MemberRef?
    public var note: String
    public var invoiceBuyer: InvoiceBuyer
    public var status: TicketStatus
    public var payments: [Payment]
    public var invoice: InvoiceStamp?
    public var refunds: [Refund]
    public var openedAt: Date
    public var openedBy: String
    public var businessDate: String
    public var billPrintedAt: Date?
    public var closedAt: Date?
    public var closedBy: String?
    public var voidInfo: VoidInfo?
    /// 從哪張單拆出來的
    public var splitFrom: String?
    /// 外帶、外送的客人稱呼（「王先生」「#12」）
    public var customerName: String?
    /// 併到哪一張單（併單後這張就關掉，報表不算作廢）
    public var mergedInto: String?
    /// 在哪一台結帳（錢進了哪個錢櫃）
    public var closedDeviceId: String?
    /// 開單時的營業模式（收據要不要印內用外帶、報表分模式）
    public var serviceMode: ServiceMode?
    /// 整張單的銷售人員（服飾的業績；行上沒指定的都算他）
    public var salespersonId: String?
    /// 換貨單：退回原單的品項當作付款
    public var exchange: ExchangeCredit?
    /// 從哪一筆預約開的（美業、私人教練）
    public var appointmentId: String?
    /// 結帳後同款換規格的紀錄
    public var swaps: [VariantSwap]?

    public init(
        id: String, number: String, deviceId: String, orderType: OrderType, tableIds: [String] = [], guests: Int = 0,
        lines: [TicketLine] = [], discount: Discount? = nil, serviceChargeBps: Int = 0, tip: Money = .zero, member: MemberRef? = nil,
        note: String = "", invoiceBuyer: InvoiceBuyer = .paper, status: TicketStatus = .open, payments: [Payment] = [],
        invoice: InvoiceStamp? = nil, refunds: [Refund] = [], openedAt: Date, openedBy: String, businessDate: String,
        billPrintedAt: Date? = nil, closedAt: Date? = nil, closedBy: String? = nil, voidInfo: VoidInfo? = nil,
        splitFrom: String? = nil, customerName: String? = nil, mergedInto: String? = nil, closedDeviceId: String? = nil,
        serviceMode: ServiceMode? = nil, salespersonId: String? = nil, exchange: ExchangeCredit? = nil, appointmentId: String? = nil,
        swaps: [VariantSwap]? = nil
    ) {
        self.id = id; self.number = number; self.deviceId = deviceId; self.orderType = orderType; self.tableIds = tableIds
        self.guests = guests; self.lines = lines; self.discount = discount; self.serviceChargeBps = serviceChargeBps; self.tip = tip
        self.member = member; self.note = note; self.invoiceBuyer = invoiceBuyer; self.status = status; self.payments = payments
        self.invoice = invoice; self.refunds = refunds; self.openedAt = openedAt; self.openedBy = openedBy
        self.businessDate = businessDate; self.billPrintedAt = billPrintedAt; self.closedAt = closedAt; self.closedBy = closedBy
        self.voidInfo = voidInfo; self.splitFrom = splitFrom; self.customerName = customerName
        self.mergedInto = mergedInto; self.closedDeviceId = closedDeviceId
        self.serviceMode = serviceMode; self.salespersonId = salespersonId; self.exchange = exchange
        self.appointmentId = appointmentId; self.swaps = swaps
    }

    public var activeLines: [TicketLine] { lines.filter(\.isActive) }
    public var unsentLines: [TicketLine] { lines.filter { $0.isActive && !$0.isSent } }
    public var isOpen: Bool { status == .open }
    public var totals: TicketTotals { TicketTotals(self) }
    public var itemCount: Int { activeLines.reduce(0) { $0 + $1.quantity } }
    public var approvedPayments: [Payment] { payments.filter { $0.status == .approved } }
    public var refundedAmount: Money { Money.sum(refunds.map(\.amount)) }

    /// 「A1+A2・4 位」「外帶 A023」；服飾、美業、課程：「王小美」「A023」
    public func title(floor: FloorPlan) -> String {
        if orderType == .dineIn && !tableIds.isEmpty { return floor.tableNames(tableIds) }
        if serviceMode?.showsOrderType == false {
            if let name = customerName, !name.isEmpty { return name }
            if let m = member { return m.name ?? m.maskedPhone }
            return number
        }
        if let name = customerName, !name.isEmpty { return "\(orderType.label) \(name)" }
        return "\(orderType.label) \(number)"
    }

    /// 這一行的業績算給誰：行上指定的 → 整單的銷售人員 → 開單的人
    public func performer(of line: TicketLine) -> String {
        line.staffId ?? salespersonId ?? openedBy
    }

    /// 換貨單已經抵掉多少（換貨的付款）
    public var exchangeApplied: Money {
        Money.sum(approvedPayments.filter { $0.tender == .exchange }.map(\.amount))
    }
}
