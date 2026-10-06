import Testing
@testable import POSCore

struct KeypadTests {
    @Test func moneyEntryReplacesInitialValue() {
        var e = KeypadEntry(KeypadSpec.price(name: "雞排", current: Money(dollars: 80)))
        #expect(e.display == "80")
        #expect(e.isPristine)
        e.press(.digit(9))
        #expect(e.display == "9")
        e.press(.doubleZero)
        #expect(e.display == "900")
        e.press(.digit(5))
        #expect(e.display == "9,005")
        e.press(.backspace)
        #expect(e.money == Money(dollars: 900))
    }

    @Test func noLeadingZerosForNumbersButKeptForCodes() {
        var q = KeypadEntry(.quantity(name: "珍奶", current: 1))
        q.press(.digit(0)); q.press(.digit(3))
        #expect(q.value == 3)
        var code = KeypadEntry(KeypadSpec(kind: .code(minLength: 8, maxLength: 8), title: "代碼"))
        for d in [0, 0, 1, 2, 3, 4, 5, 6] { code.press(.digit(d)) }
        #expect(code.digits == "00123456")
        #expect(code.canCommit)
        code.press(.digit(7))
        #expect(code.digits == "00123456") // 滿了
    }

    @Test func taxIdLiveCheck() {
        var e = KeypadEntry(.taxId)
        e.type("2209")
        #expect(e.isIncomplete)
        #expect(!e.isVerified)
        e.type("9131")
        #expect(e.display == "2209 9131")
        #expect(e.isVerified)
        e.press(.backspace); e.press(.digit(2))
        #expect(!e.isVerified)
        #expect(e.problem == "統一編號檢查碼不對")
    }

    @Test func pinIsMasked() {
        var e = KeypadEntry(.pin())
        e.type("12")
        #expect(e.display == "●●")
        #expect(e.pinDots?.filled == 2)
        #expect(e.pinDots?.total == 4)
        #expect(!e.canCommit)
        e.type("3456")
        #expect(e.pinDots?.total == 6)
        #expect(e.canCommit)
    }

    @Test func phoneAndLimits() {
        var p = KeypadEntry(.phone)
        p.type("0912345678")
        #expect(p.display == "0912 345 678")
        #expect(p.canCommit)
        var r = KeypadEntry(.refund(max: Money(dollars: 500)))
        r.press(.clear); r.type("600")
        #expect(r.problem != nil)
        var pct = KeypadEntry(.discountPercent(presets: [1000, 1500]))
        #expect(pct.spec.quickKeys.map(\.label) == ["9 折", "85 折"])
        pct.type("150")
        #expect(pct.problem == "不能超過 100%")
        var party = KeypadEntry(.partySize())
        #expect(party.problem == "至少 1")
        party.type("4")
        #expect(party.canCommit)
    }

    @Test func cashQuickKeys() {
        let spec = KeypadSpec.cashTendered(due: Money(dollars: 198), presets: [Money(dollars: 500), Money(dollars: 1000)])
        #expect(spec.quickKeys.first?.label == "剛好")
        #expect(spec.quickKeys.first?.commits == true)
        #expect(spec.quickKeys.map(\.digits) == ["198", "200", "500", "1000"])
    }
}
