//
//  CorrectionParserTests.swift
//  BillifyTests
//
//  Tests for conversational editing (spec §48): correction-style messages
//  should parse into typed field updates, and ordinary chat answers should
//  parse to nothing so they keep flowing through the slot-filler.
//

import Testing
@testable import Billify

struct CorrectionParserTests {

    // MARK: - Change-verb corrections

    @Test func changeQuantityWithVerb() {
        #expect(CorrectionParser.parse(from: "change the quantity to 25 bags") == [.productQuantity(25)])
    }

    @Test func updateBuyerName() {
        #expect(CorrectionParser.parse(from: "update buyer name to Ravi Traders") == [.buyerName("Ravi Traders")])
    }

    @Test func keepCompanySuffixesInNames() {
        #expect(CorrectionParser.parse(from: "change buyer name to Raj and Sons") == [.buyerName("Raj and Sons")])
    }

    @Test func changeWeight() {
        #expect(CorrectionParser.parse(from: "change the weight to 40 kg") == [.productWeight(40)])
    }

    @Test func changeRateWithUnit() {
        #expect(CorrectionParser.parse(from: "set the rate to 30 per kg") == [.productRate(30)])
    }

    @Test func fromOldToNewQuantity() {
        #expect(CorrectionParser.parse(from: "change the quantity from 20 to 25 bags") == [.productQuantity(25)])
    }

    @Test func changeUnitToBags() {
        #expect(CorrectionParser.parse(from: "change the unit to bags") == [.productUnit(.bages)])
    }

    @Test func changeInvoiceTypeWithoutKeyword() {
        #expect(CorrectionParser.parse(from: "change to credit note") == [.invoiceType(.creditNote)])
    }

    @Test func changeTaxTypeWithoutKeyword() {
        #expect(CorrectionParser.parse(from: "make it igst") == [.taxType(.national)])
    }

    @Test func multipleCorrectionsInOneMessage() {
        let result = CorrectionParser.parse(from: "change the quantity to 25 and weight to 40")
        #expect(result == [.productQuantity(25), .productWeight(40)])
    }

    @Test func correctionWinsOverBulkHeuristic() {
        let result = CorrectionParser.parse(from: "change the quantity to 25 and weight to 40 and rate to 30 and buyer to Ravi")
        #expect(result == [.productQuantity(25), .productWeight(40), .productRate(30), .buyerName("Ravi")])
    }

    // MARK: - Assignment-style corrections (no verb)

    @Test func gstRateNotPattern() {
        #expect(CorrectionParser.parse(from: "the GST is 18% not 5%") == [.taxRate(18)])
    }

    @Test func quantityWithoutVerb() {
        #expect(CorrectionParser.parse(from: "quantity is 25 bags") == [.productQuantity(25)])
    }

    @Test func gstinColon() {
        #expect(CorrectionParser.parse(from: "GSTIN: 33AIMPM2628J1Z4") == [.buyerGstin("33AIMPM2628J1Z4")])
    }

    @Test func dateAssignment() {
        #expect(CorrectionParser.parse(from: "the date is 25-08-2026") == [.invoiceDate("25-08-2026")])
    }

    @Test func vehicleNumber() {
        #expect(CorrectionParser.parse(from: "vehicle no is TN 38 AB 1234") == [.vehicleNo("TN 38 AB 1234")])
    }

    @Test func originalInvoiceNumber() {
        #expect(CorrectionParser.parse(from: "original invoice number is 17") == [.originalInvoiceNo("17")])
    }

    // MARK: - Ordinary answers must NOT parse as corrections

    @Test func plainNumberIsNotACorrection() {
        #expect(CorrectionParser.parse(from: "25") == [])
    }

    @Test func plainQuantityWithUnitIsNotACorrection() {
        #expect(CorrectionParser.parse(from: "25 bags") == [])
    }

    @Test func buyerNameIsNotACorrection() {
        #expect(CorrectionParser.parse(from: "Ravi Traders") == [])
    }

    @Test func acknowledgementIsNotACorrection() {
        #expect(CorrectionParser.parse(from: "ok") == [])
    }

    @Test func createInvoiceIsNotACorrection() {
        #expect(CorrectionParser.parse(from: "create a tax invoice") == [])
    }

    @Test func bulkPasteStaysOnBulkPath() {
        let bulk = "GSTIN 33AIMPM2628J1Z4 HSN 7023 50 kgs rate 30 rs 25 bags supplier Ravi Traders Coimbatore Tamil Nadu India 641697"
        #expect(CorrectionParser.parse(from: bulk) == [])
    }

    @Test func compactDigitDensePasteStaysOnBulkPath() {
        // No verbs or assignment syntax — belongs to BulkTextExtractor even
        // though it's short and full of digits.
        #expect(CorrectionParser.parse(from: "GSTIN 33AIMPM2628J1Z4 HSN 7023 rate 30") == [])
    }
}