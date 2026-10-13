//
//  BulkTextExtractorTests.swift
//  BillifyTests
//
//  Behavioral tests for the improved bulk-text extraction: real-world phrasings
//  that previously fell through (lowercase GSTINs, E-way bills, buyer address
//  blocks, credit-note references, multiple product rows).
//

import Testing
import Foundation
@testable import Billify

struct BulkTextExtractorTests {

    private func extract(_ text: String) -> ExtractionResult {
        BulkTextExtractor.extract(from: text)
    }

    // MARK: - GSTIN / identifiers

    @Test func lowercaseGstinIsMatchedAndUpperCased() {
        let result = extract("gstin 33aimpm2628j1z4")
        #expect(result.data.buyer.gstin == "33AIMPM2628J1Z4")
    }

    @Test func secondGstinGoesToTransporter() {
        let result = extract("buyer gstin 33AIMPM2628J1Z4 transporter gstin 33ABCDE1234F1Z5")
        #expect(result.data.buyer.gstin == "33AIMPM2628J1Z4")
        #expect(result.data.transport.gstin == "33ABCDE1234F1Z5")
    }

    @Test func ewayBillIsExtractedNotMistakenForInvoice() {
        let result = extract("e-way bill no 231056789012 invoice no 42")
        #expect(result.data.invoiceDetails.ewayBill == "231056789012")
        #expect(result.data.invoiceDetails.invoiceNo == "42")
    }

    @Test func lrAndVehicleNormalized() {
        let result = extract("vehicle no tn-38-ab-1234 lr no LR-2026-0042")
        #expect(result.data.transport.vehicleNo == "TN38AB1234")
        #expect(result.data.transport.lrNo == "LR-2026-0042")
    }

    // MARK: - Realistic full paragraph (spinning-mill style)

    @Test func fullRealisticParagraph() {
        let text = """
        Create a tax invoice for SRI KUMARAN MILLS, SF NO 114/2 PAPPAMPALAYAM, TIRUPUR - 641604,
        gstin 33AABCT1234F1Z5. Product 100 bales cotton yarn hsn 5205 weight 4000 kgs rate rs 150
        per kg. invoice no 23 date 12-08-2026 vehicle tn38ab1234 eway 231056789012 lr 4587
        """
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "SRI KUMARAN MILLS")
        #expect(d.buyer.gstin == "33AABCT1234F1Z5")
        #expect(d.buyer.address.joined(separator: " ").contains("TIRUPUR"))
        #expect(d.products.count == 1)
        #expect(d.products[0].name.lowercased().contains("cotton yarn"))
        #expect(d.products[0].hsn == "5205")
        #expect(d.products[0].quantity == 100)
        #expect(d.products[0].unit == .bales)
        #expect(d.products[0].weightKg == 4000)
        #expect(d.products[0].ratePerKg == 150)
        #expect(d.invoiceDetails.invoiceNo == "23")
        #expect(d.invoiceDetails.date == "12-08-2026")
        #expect(d.transport.vehicleNo == "TN38AB1234")
        #expect(d.invoiceDetails.ewayBill == "231056789012")
        #expect(d.transport.lrNo == "4587")
    }

    @Test func buyerNameViaBuyerLabel() {
        let result = extract("buyer : Ravi Textiles, gstin 33AIMPM2628J1Z4")
        #expect(result.data.buyer.name == "Ravi Textiles")
    }

    @Test func buyerAddressViaLabel() {
        let text = "for SRI KUMARAN MILLS\nbuyer address : SF NO 114/2, PAPPAMPALAYAM, TIRUPUR - 641604, TAMIL NADU\n"
        let result = extract(text)
        let addr = result.data.buyer.address.filter { !$0.isEmpty }
        #expect(addr.count == 4)
        #expect(addr[0].contains("114/2"))
        #expect(addr.joined(separator: " ").contains("TIRUPUR"))
    }

    @Test func productOnlyMessageDoesNotInventBuyer() {
        let result = extract("100 bales cotton yarn hsn 5205 4000 kgs rate rs 150 per kg")
        #expect(result.data.buyer.name.isEmpty)
        #expect(result.uncertainFields.contains("Buyer name"))
        #expect(result.data.products.first?.name.lowercased().contains("cotton yarn") == true)
    }

    // MARK: - Credit notes

    @Test func debitNoteIsDetectedWithOriginalReference() {
        let result = extract("debit note 3 against original invoice 17 & date 12-08-2026 product 10 bales cotton yarn hsn 5205")
        #expect(result.data.invoiceType == .debitNote)
        #expect(result.data.invoiceDetails.originalInvoiceNo == "17")
        #expect(result.data.invoiceDetails.originalInvoiceDate == "12-08-2026")
        #expect(result.data.products.count == 1)
    }

    @Test func creditNoteOriginalInvoiceReference() {
        let result = extract("credit note 5 against original invoice 17 & date 12-08-2026")
        #expect(result.data.invoiceType == .creditNote)
        #expect(result.data.invoiceDetails.originalInvoiceNo == "17")
        #expect(result.data.invoiceDetails.originalInvoiceDate == "12-08-2026")
        #expect(result.data.invoiceDetails.invoiceNo.isEmpty) // not the original's number
    }

    // MARK: - Products

    @Test func multipleProductRowsBecomeSeparateProducts() {
        let text = "1) 100 bales cotton yarn hsn 5205 rate 150 2) 20 bales cotton waste hsn 5202 rate 40"
        let result = extract(text)
        #expect(result.data.products.count == 2)
        #expect(result.data.products[0].name.lowercased().contains("cotton yarn"))
        #expect(result.data.products[0].hsn == "5205")
        #expect(result.data.products[0].quantity == 100)
        #expect(result.data.products[1].name.lowercased().contains("waste"))
        #expect(result.data.products[1].hsn == "5202")
        #expect(result.data.products[1].quantity == 20)
    }

    @Test func hsnOnlyProductUsesCommodityKeyword() {
        let result = extract("hsn 5205 rate 30 per kg 100 bales 4000 kgs cotton")
        let p = result.data.products.first
        #expect(p != nil)
        #expect(p?.hsn == "5205")
        #expect(p?.name == "Cotton")
        #expect(p?.quantity == 100)
        #expect(p?.unit == .bales)
        #expect(p?.weightKg == 4000)
        #expect(p?.ratePerKg == 30)
    }

    @Test func numbersWithCommasAreParsed() {
        let result = extract("hsn 5205 4,000 kgs rate 150 per kg")
        #expect(result.data.products.first?.weightKg == 4000)
    }

    // MARK: - Natural chat-style sentences

    @Test func naturalChatSentenceCreatesFullDraft() {
        let text = "Create an invoice for Radhika Mills with product as 10 KG of cotton with price of 500 per KG with invoice number 2 date today"
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "Radhika Mills")
        #expect(d.products.count == 1)
        let p = d.products[0]
        #expect(p.name == "cotton")
        #expect(p.weightKg == 10)
        #expect(p.ratePerKg == 500)
        #expect(p.quantity == nil) // weight-only clause: bale count unknown
        #expect(d.invoiceDetails.invoiceNo == "2")
        // "date today" resolves instead of nagging for confirmation
        #expect(d.invoiceDetails.date == BulkTextExtractor.todayString())
        #expect(!result.uncertainFields.contains { $0.contains("Date") })
    }

    @Test func buyerNameStopsAtWithClause() {
        let text = "invoice for Raj Textiles with gstin 33AIMPM2628J1Z4 product 100 bales cotton yarn hsn 5205"
        let result = extract(text)
        #expect(result.data.buyer.name == "Raj Textiles")
        #expect(result.data.buyer.gstin == "33AIMPM2628J1Z4")
        #expect(result.data.products.count == 1)
        #expect(result.data.products[0].quantity == 100)
    }

    @Test func balesOfProductClauseWithPrice() {
        let text = "create a delivery challan for KK Spinners product 20 bales of cotton waste at price of 400 per kg"
        let result = extract(text)
        #expect(result.data.invoiceType == .deliveryChallan)
        #expect(result.data.buyer.name == "KK Spinners")
        let p = result.data.products.first
        #expect(p != nil)
        #expect(p?.name == "cotton waste")
        #expect(p?.quantity == 20)
        #expect(p?.unit == .bales)
        #expect(p?.ratePerKg == 400)
        #expect(p?.weightKg == nil)
    }

    @Test func nameFirstProductWithConsistingAndTrailingBags() {
        // "with <name> as a product", weight with a possessive suffix (KG's),
        // and the bag count written after the rate ("in 30 bags").
        let text = "Create an invoice for Anish traders with cotton Lint as a product consisting 10 KG's with the price of 200 per KG in 30 bags"
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "Anish traders")
        #expect(d.products.count == 1)
        let p = d.products[0]
        #expect(p.name == "cotton Lint")
        #expect(p.weightKg == 10)
        #expect(p.ratePerKg == 200)
        #expect(p.quantity == 30)
        #expect(p.unit == .bages)
    }

    @Test func nameFirstProductWithConsistingOfAndTrailingBales() {
        let text = "create invoice for SRM Mills with cotton waste as a product consisting of 40 KGS at the price of 35 per KG in 5 bales"
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "SRM Mills")
        let p = d.products.first
        #expect(p != nil)
        #expect(p?.name == "cotton waste")
        #expect(p?.weightKg == 40)
        #expect(p?.ratePerKg == 35)
        #expect(p?.quantity == 5)
        #expect(p?.unit == .bales)
    }

    @Test func noAsAProductMarkerFallsThroughToOtherParsers() {
        // Regression: the name-first pattern must not fire without its marker,
        // leaving "with price of…"-style text to the other product parsers.
        let text = "create an invoice for Ravi Textiles with 100 bales cotton yarn hsn 5205 rate 150 per kg"
        let result = extract(text)
        #expect(result.data.buyer.name == "Ravi Textiles")
        let p = result.data.products.first
        #expect(p != nil)
        #expect(p?.name.lowercased().contains("cotton yarn") == true)
        #expect(p?.quantity == 100)
        #expect(p?.ratePerKg == 150)
    }

    @Test func scrambledOrderNaturalSentence() {
        // Same information as the "typical" sentence, but every field appears
        // in a different order — the clause reader must assemble fields
        // order-independently (rate first, buyer last, count after the rate).
        let text = "price of 200 per KG with cotton Lint as a product consisting 10 KG's in 30 bags for Anish traders invoice number 2 date today"
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "Anish traders")
        let p = d.products.first
        #expect(p != nil)
        #expect(p?.name == "cotton Lint")
        #expect(p?.weightKg == 10)
        #expect(p?.ratePerKg == 200)
        #expect(p?.quantity == 30)
        #expect(p?.unit == .bages)
        #expect(d.invoiceDetails.invoiceNo == "2")
        #expect(d.invoiceDetails.date == BulkTextExtractor.todayString())
    }

    @Test func bareNumberedDescriptionWithoutLabels() {
        // No labels at all — just numbers and units scattered around the name.
        let text = "cotton lint 10 kg 200 per kg 30 bags"
        let result = extract(text)
        let p = result.data.products.first
        #expect(p != nil)
        #expect(p?.name == "cotton lint")
        #expect(p?.weightKg == 10)
        #expect(p?.ratePerKg == 200)
        #expect(p?.quantity == 30)
        #expect(p?.unit == .bages)
    }

    @Test func weightBeforeNameAndRateBeforeCount() {
        // Name written after the weight, rate before the count — and the name
        // only recoverable from the sentence's leftover words.
        let text = "create invoice for Ravi Textiles with 25 kgs cotton waste as a product at 40 per kg in 5 bales"
        let result = extract(text)
        let d = result.data
        #expect(d.buyer.name == "Ravi Textiles")
        let p = d.products.first
        #expect(p != nil)
        #expect(p?.name == "Cotton Waste")
        #expect(p?.weightKg == 25)
        #expect(p?.ratePerKg == 40)
        #expect(p?.quantity == 5)
        #expect(p?.unit == .bales)
    }

    @MainActor
    @Test func truncatedPasteStillCompletesPipeline() {
        // A paste truncated mid-sentence (as happens with long typeText in the
        // UI) must not break the pipeline: buyer + summary still appear.
        let vm = ChatViewModel(
            memory: MemoryStore(defaults: UserDefaults(suiteName: "bulk-extractor-truncated-\(UUID().uuidString)")!),
            initialType: .taxInvoice)
        vm.inputText = "Create an invoice for Radhika Mills, SF NO 114/2 PAPPAMPALAYAM TIRUPUR - 641604, gstin 33AIMPM2628J1Z4 with 100 bales cotton yarn hsn 5205 4000 kgs rate 150 per kg with invoice number"
        vm.send()
        #expect(vm.messages.contains { $0.text.contains("Buyer: Radhika Mills") })
        #expect(vm.draft.buyer.gstin == "33AIMPM2628J1Z4")
    }

    @MainActor
    @Test func chatPipelinePreservesExtractedAddress() {
        // Regression: merge() used to drop the extracted buyer address, so a
        // complete paste still asked "What's the buyer's address?" and the
        // draft never reached the preview.
        let vm = ChatViewModel(
            memory: MemoryStore(defaults: UserDefaults(suiteName: "bulk-extractor-address-\(UUID().uuidString)")!),
            initialType: .taxInvoice)
        vm.inputText = "Create an invoice for Radhika Mills, SF NO 114/2 PAPPAMPALAYAM TIRUPUR - 641604, gstin 33AIMPM2628J1Z4 with 100 bales cotton yarn hsn 5205 4000 kgs rate 150 per kg with invoice number 2 date today"
        vm.send()
        // The whole pipeline (extract → merge → memory → summary → preview)
        // completes without blocking, and the address survives the merge.
        #expect(vm.messages.contains { $0.text.contains("Buyer: Radhika Mills") })
        #expect(vm.draft.buyer.address.joined(separator: " ").contains("TIRUPUR"))
        #expect(vm.draft.isReadyForPreview)
    }

    @Test func writtenMonthDateIsExtracted() {
        let result = extract("date 28th August 2026 invoice for Ravi Textiles")
        #expect(result.data.invoiceDetails.date == "28th August 2026")
        #expect(result.data.buyer.name == "Ravi Textiles")
    }
}
