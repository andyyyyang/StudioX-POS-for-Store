import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 掃碼要收什麼（哪一個相機、哪一條路）
enum ScanPurpose: String, Hashable, Sendable {
    /// 一般的「掃碼」（手機的掃碼鍵、iPad 的外接條碼機）：照內容判斷——商品、會員、載具、折價券；相機一個接一個掃
    case any
    /// 只收載具（結帳的「用相機掃」）
    case carrier
    /// 只收會員：掛到這張單（沒有單：打開會員）
    case member
    /// 只收會員：會員頁打開這一位（不掛單）
    case memberProfile
    /// 只收折價券：套到這張單
    case coupon
}

/// 要打開的相機（model.scanRequest；最外層的 ScanPresenter 打開它）
struct ScanRequest: Identifiable, Equatable {
    let id = UUID()
    var purpose: ScanPurpose
}

/// 掃到一個碼之後：認出了什麼（提示、相機上的小標籤、下面的清單）、要不要關掉相機
struct ScanOutcome {
    enum Kind: Hashable { case carrier, member, product, coupon, unknown }

    let id = UUID()
    var kind: Kind
    /// 「載具 /ABC+123 已掛上 A012」「找不到折價券 ABC1」：一定說認出了什麼
    var text: String
    /// 認出來、也做好了（只收一種的相機：好了就關掉）
    var ok: Bool
    var tone: Tone
    /// 清單上的短名字（「拿鐵」「會員 王小美」）；nil＝不列
    var tally: String?
    /// 加了幾份（清單上「拿鐵 ×2」）
    var count = 1
    /// 要先關掉相機（打開會員頁、要選甜度或規格）
    var closesScanner = false

    static func done(_ kind: Kind, _ text: String, tally: String?, count: Int = 1, tone: Tone = .active) -> ScanOutcome {
        ScanOutcome(kind: kind, text: text, ok: true, tone: tone, tally: tally, count: count)
    }

    static func failed(_ kind: Kind, _ text: String, tone: Tone = .warning) -> ScanOutcome {
        ScanOutcome(kind: kind, text: text, ok: false, tone: tone, tally: nil)
    }

    /// 配對這種只要一串字的相機：掃到就收
    static func accepted() -> ScanOutcome {
        ScanOutcome(kind: .unknown, text: "掃到了", ok: true, tone: .active, tally: nil)
    }
}

/// 沒有單時掃到的載具：這台下一張開的單用（10 分鐘內；之後就不算了，免得掛到下一位客人）
struct PendingCarrier: Equatable {
    var carrier: InvoiceCarrier
    var at: Date

    var isFresh: Bool { Date().timeIntervalSince(at) < 600 }
}

/// 掃碼（docs/API.md「掃碼」）：手機不接條碼機，用相機掃；iPad 的外接條碼機打進來的字也走這裡。一個鍵，照內容判斷：
///
///   載具    掛到這張單的發票（沒有單：先記著，這台下一張單用）
///   商品    加一份（要選甜度、規格的：關掉相機後打開那張卡）
///   會員    查到就掛到這張單（沒有單：打開會員頁）
///   折價券  問後台能不能用 → 套到這張單（POSModel+Coupons）
extension POSModel {
    /// 掃到的東西掛到哪一張單：結帳中的，不然是選起來的
    var scanTicket: Ticket? {
        if let t = checkoutTicket, t.isOpen { return t }
        return selectedTicket
    }

    /// 打開相機（最外層的 ScanPresenter 接手；手機先收起單子的 sheet）
    func requestScan(_ purpose: ScanPurpose) {
        touch()
        scanRequest = ScanRequest(purpose: purpose)
    }

    /// 相機關掉了：要選甜度、規格的品項現在才打開那張卡
    func takeAfterScan() -> (@MainActor () -> Void)? {
        let f = afterScan
        afterScan = nil
        return f
    }

    /// 一個掃碼鍵：照內容判斷是什麼、做該做的事，提示說認出了什麼。context：這個相機只收一種（結帳的載具、會員頁的會員…）
    @discardableResult
    func handleScan(_ raw: String, context: ScanPurpose = .any) async -> ScanOutcome {
        touch()
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome: ScanOutcome
        if code.isEmpty {
            outcome = .failed(.unknown, "沒有掃到東西")
        } else {
            switch context {
            case .any:
                outcome = await route(ScanCode.classify(code, catalog: catalog))
            case .carrier:
                if let c = ScanCode.carrier(in: code) {
                    outcome = scanCarrier(c)
                } else {
                    outcome = .failed(.carrier, "這不是載具：手機條碼是 / 開頭 8 碼（掃到 \(Self.excerpt(code))）")
                }
            case .member, .memberProfile:
                if let phone = ScanCode.memberPhone(in: code) {
                    outcome = await scanMember(phone: phone, openProfile: context == .memberProfile)
                } else {
                    outcome = .failed(.member, "這不是會員條碼：會員卡的條碼是手機號碼（掃到 \(Self.excerpt(code))）")
                }
            case .coupon:
                outcome = await couponOutcome(code: code, to: scanTicket)
            }
        }
        show(outcome.text, tone: outcome.tone)
        return outcome
    }

    private func route(_ c: ScanCode) async -> ScanOutcome {
        switch c {
        case .carrier(let carrier):
            return scanCarrier(carrier)
        case .member(let phone):
            return await scanMember(phone: phone, openProfile: false)
        case .product(let m):
            return scanProduct(m)
        case .coupon(let code):
            // 對不到菜單的一串數字、又沒有單：多半是品號打錯（和以前的「品號」一樣說）
            if scanTicket == nil, code.allSatisfy(\.isNumber) { return .failed(.product, "找不到品號 \(code)") }
            return await couponOutcome(code: code, to: scanTicket, guessed: true)
        case .unknown(let s):
            return .failed(.unknown, "看不懂這個條碼：\(Self.excerpt(s))（不是商品、會員、載具，也不是折價券）")
        }
    }

    // MARK: 載具

    /// 掛到這張單的發票；沒有單就先記著（這台下一張開的單用）
    func scanCarrier(_ c: InvoiceCarrier) -> ScanOutcome {
        guard features.invoice, invoiceSettings.enabled else {
            return .failed(.carrier, "載具 \(c.id)：這家店沒有開電子發票")
        }
        guard let t = scanTicket else {
            pendingCarrier = PendingCarrier(carrier: c, at: Date())
            return .done(.carrier, "載具 \(c.id) 先記著：這台下一張單用", tally: "載具 \(c.id)", tone: .info)
        }
        setBuyer(.consumer(carrier: c), for: t)
        return .done(.carrier, "載具 \(c.id) 已掛上 \(t.number)", tally: "載具 \(c.id)")
    }

    /// 剛開的單：掛上沒有單時掃到的載具（10 分鐘內的）
    func applyPendingCarrier(to ticketId: String) {
        guard let p = pendingCarrier else { return }
        pendingCarrier = nil
        guard p.isFresh, let t = state.tickets[ticketId], t.isOpen else { return }
        setBuyer(.consumer(carrier: p.carrier), for: t)
        show("載具 \(p.carrier.id) 已掛上 \(t.number)")
    }

    // MARK: 會員

    /// 會員卡（條碼／QR 就是手機號碼）：查到就掛到這張單；沒有單（或會員頁的相機）就打開會員頁
    func scanMember(phone: String, openProfile: Bool) async -> ScanOutcome {
        let masked = MemberRef(phone: phone).maskedPhone
        let target = openProfile ? nil : scanTicket
        switch await findMember(code: phone) {
        case .found(let m), .cached(let m):
            let name = m.name ?? m.ref.maskedPhone
            let tier = m.tierName.map { "・\($0)" } ?? ""
            guard let t = target else { return openMember(m.ref, phone: m.phone, name: name + tier) }
            if t.member?.id == m.id {
                return .done(.member, "會員 \(name) 已經在 \(t.number) 上", tally: "會員 \(name)")
            }
            guard attach(m.ref, memberId: m.id, to: t) else { return .failed(.member, "會員 \(name) 沒有掛上，請再試一次", tone: .danger) }
            return .done(.member, "會員 \(name) 已掛上 \(t.number)", tally: "會員 \(name)")
        case .notFound:
            return .failed(.member, "\(masked) 還不是會員：在「找會員」打這支電話可以當場加入")
        case .offline:
            guard let t = target else { return .failed(.member, "離線，查不到會員 \(masked)") }
            // 和打電話找會員一樣：先記電話，後台結帳時再對到會員
            guard attach(MemberRef(phone: phone), memberId: nil, to: t) else { return .failed(.member, "會員 \(masked) 沒有掛上，請再試一次", tone: .danger) }
            return .done(.member, "離線，先記下會員電話 \(masked)（\(t.number)）", tally: "會員 \(masked)", tone: .warning)
        case .failed(let message):
            return .failed(.member, "查不到會員 \(masked)：\(message)", tone: .danger)
        }
    }

    /// 沒有單：打開會員頁的這一位（這台沒有會員頁就說一聲怎麼掛上）
    private func openMember(_ ref: MemberRef, phone: String, name: String) -> ScanOutcome {
        guard visibleSections.contains(.members) else {
            return .done(.member, "會員 \(name)：先開單再掃一次，就會掛上", tally: "會員 \(name)", tone: .info)
        }
        memberRequest = MembersFocus(phone: phone, ref: ref)
        if section != .members { go(.members) }
        var out = ScanOutcome.done(.member, "會員 \(name)", tally: "會員 \(name)")
        out.closesScanner = true
        return out
    }

    // MARK: 商品

    /// 品號、條碼、SKU：加一份（掃吊牌直接是那個規格）。要選甜度、規格、打金額的：相機開著時先關掉，再打開那張卡
    func scanProduct(_ m: Catalog.Match) -> ScanOutcome {
        let item = m.item
        guard checkoutTicket == nil else { return .failed(.product, "\(item.name)：結帳中不能加品項，先「回到點餐」") }
        guard visibleSections.contains(.order) else { return .failed(.product, "\(item.name)：這台是「\(role.label)」，不能點餐") }
        if section != .order { goToOrderIfShown() }
        if let v = m.variant {
            let name = "\(item.name) \(v.label)"
            guard isAvailable(item), v.isAvailable else { return .failed(.product, "\(name) 今天不能賣") }
            let qty = keypad.takeQuantity()
            add(item, variant: v, quantity: qty, modifiers: [], note: "")
            if let stock = v.stock, stock <= 0 {
                return .done(.product, "\(name) 帳上沒有庫存，照樣加入\(ticketSuffix)", tally: name, count: qty, tone: .warning)
            }
            return .done(.product, "\(name) 加 \(qty) 份\(ticketSuffix)", tally: name, count: qty)
        }
        guard isAvailable(item) else { return .failed(.product, "\(item.name) 今天賣完了") }
        if let why = choiceNeeded(for: item) {
            guard scannersOpen > 0 else {
                // 外接條碼機：沒有相機擋著，直接打開那張卡（和點菜單一樣）
                Task { await tap(item) }
                return .done(.product, "\(item.name)：\(why)", tally: item.name)
            }
            afterScan = { [weak self] in
                guard let self else { return }
                Task { await self.tap(item) }
            }
            var out = ScanOutcome.done(.product, "\(item.name)：關掉相機後\(why)", tally: item.name)
            out.closesScanner = true
            return out
        }
        let qty = keypad.takeQuantity()
        add(item, quantity: qty, modifiers: [], note: "")
        return .done(.product, "\(item.name) 加 \(qty) 份\(ticketSuffix)", tally: item.name, count: qty)
    }

    /// 點菜單時要先選的（甜度、規格、金額、會員）；沒有＝直接加
    private func choiceNeeded(for item: MenuItem) -> String? {
        if item.hasVariants { return "選" + (item.optionNames ?? ["規格"]).joined(separator: "、") }
        let groups = catalog.groups(for: item)
        if !groups.isEmpty { return "選" + groups.prefix(3).map(\.name).joined(separator: "、") }
        if item.openPrice { return "打金額" }
        if item.itemKind.needsMember, scanTicket?.member?.id == nil { return "先找會員" }
        return nil
    }

    /// 「・A012」：加到哪一張單
    private var ticketSuffix: String {
        selectedTicket.map { "・\($0.number)" } ?? ""
    }

    /// 提示裡的一小段（太長的網址截掉）
    static func excerpt(_ s: String) -> String {
        s.count > 24 ? String(s.prefix(24)) + "…" : s
    }
}

// MARK: - 右側鍵盤待機打的數字：打完停一下就自動做（不用再按鍵）

extension POSModel {
    /// 這串數字是什麼（會員電話、統編、對到的品號、數量…）
    func typedDigits(_ digits: String) -> TypedDigits? {
        TypedDigits.classify(digits, catalog: catalog, atCheckout: checkoutTicket != nil)
    }

    /// 鍵盤上方的題目與說明：打的時候就看得出它會被當成什麼
    func describeTyped(_ digits: String) -> (title: String, hint: String) {
        switch typedDigits(digits) {
        case .quantity(let n):
            return ("下一個品項 × \(n)", "點品項＝加 \(n) 份，或按「\(typedConfirmTitle(digits))」")
        case .partialPhone(let d):
            return ("會員電話 \(Self.dashedPhone(d))", "打滿 10 碼、停一下就帶入會員")
        case .member(let phone):
            return ("會員 \(Self.dashedPhone(phone))", "停一下就查這位會員、掛到這張單")
        case .taxId(let id):
            return ("統編 \(id)", "停一下就掛到這張單的發票")
        case .product(let m):
            let name = m.variant.map { "\(m.item.name) \($0.label)" } ?? m.item.name
            return ("品號 \(digits) → \(name)", "停一下就加入")
        case .code, nil:
            if case .amount(let price)? = TypedConfirm.classify(digits, catalog: catalog) {
                return (price.formatted, "沒有這個品號：按「加 \(price.formatted)」加一筆「\(Self.amountLineName)」")
            }
            return ("品號 \(digits)", "打完按「品號」；打錯按 C")
        }
    }

    /// 打完停一下：會員電話 → 查、掛上；統編（結帳中）→ 掛上；剛好對到的品號 → 加入。其他的等使用者
    func actOnTyped(_ digits: String) async {
        guard let kind = typedDigits(digits), kind.actsOnPause else { return }
        keypad.clearIdle()
        switch kind {
        case .member(let phone):
            _ = await handleScan(phone, context: .member)
        case .taxId(let id):
            guard let t = checkoutTicket ?? selectedTicket else { return }
            setBuyer(.business(taxId: id, title: nil), for: t)
            show("統編 \(id) 已掛上 \(t.number)")
        case .product:
            _ = await handleScan(digits)
        case .quantity, .partialPhone, .code:
            break
        }
    }

    /// 0912345678 → 0912-345-678（打到一半的照打的分段）
    static func dashedPhone(_ d: String) -> String {
        var out = ""
        for (i, ch) in d.enumerated() {
            if i == 4 || i == 7 { out.append("-") }
            out.append(ch)
        }
        return out
    }
}
