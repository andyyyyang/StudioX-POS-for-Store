import Testing
@testable import POSCore

struct MoneyTests {
    @Test func rounding() {
        #expect(Money(cents: 149).roundedToDollar() == Money(dollars: 1))
        #expect(Money(cents: 150).roundedToDollar() == Money(dollars: 2))
        #expect(Money(cents: -150).roundedToDollar() == Money(dollars: -2))
        #expect(Money(cents: -149).roundedToDollar() == Money(dollars: -1))
        #expect(Money(dollars: 1280).formatted == "NT$1,280")
        #expect(Money(dollars: -120).short == "−$120")
        #expect(Money(dollars: 1234567).plain == "1,234,567")
        #expect(Money(dollars: 999).plain == "999")
    }

    @Test func bps() {
        #expect(Money(dollars: 200).applying(bps: 1000) == Money(dollars: 20))
        #expect(Money(dollars: 185).applying(bps: 1000) == Money(dollars: 19)) // 18.5 → 19
        #expect(Money(dollars: 333).applying(bps: 1500) == Money(dollars: 50)) // 49.95 → 50
        #expect(percentText(bps: 1000) == "10%")
        #expect(percentText(bps: 1250) == "12.5%")
        #expect(percentText(bps: 1205) == "12.05%")
    }

    @Test func taxSplit() {
        let (sales, tax) = Tax.split(inclusive: Money(dollars: 198))
        #expect(sales == Money(dollars: 189))
        #expect(tax == Money(dollars: 9))
        let (s2, t2) = Tax.split(inclusive: Money(dollars: 105))
        #expect(s2 == Money(dollars: 100) && t2 == Money(dollars: 5))
        let (s3, t3) = Tax.split(inclusive: Money(dollars: 10))
        #expect(s3 + t3 == Money(dollars: 10))
        #expect(Tax.split(inclusive: Money(dollars: 100), rateBps: 0).tax == .zero)
    }
}

struct InvoiceValidationTests {
    @Test func taxIds() {
        #expect(InvoiceValidation.isTaxId("22099131"))
        #expect(InvoiceValidation.isTaxId("04595257"))
        #expect(!InvoiceValidation.isTaxId("12345678"))
        #expect(!InvoiceValidation.isTaxId("2209913"))
        #expect(!InvoiceValidation.isTaxId("2209913a"))
        // 第 7 碼是 7：28 → 10 → 1 或 0
        #expect(InvoiceValidation.isTaxId("12345670"))
        #expect(InvoiceValidation.isTaxId("12345671"))
        #expect(!InvoiceValidation.isTaxId("12345672"))
    }

    @Test func carriers() {
        #expect(InvoiceValidation.isMobileBarcode("/ABC+123"))
        #expect(InvoiceValidation.isMobileBarcode("/A.B-C12"))
        #expect(!InvoiceValidation.isMobileBarcode("ABC+1234"))
        #expect(!InvoiceValidation.isMobileBarcode("/abc+123"))
        #expect(!InvoiceValidation.isMobileBarcode("/ABC+12"))
        #expect(InvoiceValidation.isCitizenCertificate("AB12345678901234"))
        #expect(!InvoiceValidation.isCitizenCertificate("A123456789012345"))
        #expect(InvoiceValidation.isLoveCode("919"))
        #expect(InvoiceValidation.isLoveCode("8455"))
        #expect(!InvoiceValidation.isLoveCode("12"))
        #expect(!InvoiceValidation.isLoveCode("12345678"))
        #expect(InvoiceBuyer.business(taxId: "12345678", title: nil).problem != nil)
        #expect(InvoiceBuyer.business(taxId: "22099131", title: "台積電").problem == nil)
        #expect(InvoiceBuyer.consumer(carrier: .mobileBarcode("/ABC+123")).printsProof == false)
        #expect(InvoiceBuyer.paper.printsProof)
        #expect(InvoiceBuyer.business(taxId: "22099131", title: nil).printsProof)
        #expect(!InvoiceBuyer.donation(loveCode: "919").printsProof)
    }
}
