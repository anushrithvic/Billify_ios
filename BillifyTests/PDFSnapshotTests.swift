//
//  PDFSnapshotTests.swift
//  BillifyTests
//
//  Renders a realistic sample invoice so the layout can be eyeballed
//  (the generated PDF lands in the simulator's temporary directory) and
//  guards against generator crashes on realistic data.
//

import Testing
import Foundation
@testable import Billify

struct PDFSnapshotTests {

    private func sampleInvoice() -> InvoiceData {
        var data = InvoiceData()
        data.invoiceType = .taxInvoice
        data.invoiceDetails.invoiceNo = "1"
        data.invoiceDetails.date = "28-08-2026"
        data.invoiceDetails.ewayBill = "231056789012"

        data.buyer = Party(
            name: "SRI KUMARAN MILLS",
            gstin: "33AABCT1234F1Z5",
            address: [
                "SF NO. 114/2, PAPPAMPALAYAM",
                "KALANGAL PALAYAM POST",
                "TIRUPUR - 641604",
                "TAMIL NADU"
            ])
        data.shippingSameAsBuyer = true

        data.transport = Transport(
            transporter: "SREE BALAJI ROADWAYS",
            vehicleNo: "TN38AB1234",
            lrNo: "LR-2026-0042",
            gstin: "33AABCT5678G1Z7")

        var product = Product()
        product.name = "100% COMBED COTTON YARN 40s"
        product.hsn = "5205"
        product.unit = .bales
        product.quantity = 100
        product.weightKg = 4000
        product.ratePerKg = 150
        data.products = [product]

        data.tax.type = .state
        data.tax.rate = 5.0
        return data
    }

    @Test func rendersSampleInvoiceToPDF() throws {
        let invoice = sampleInvoice()
        let output = PDFGenerator.generate(invoice)
        #expect(!output.pdfData.isEmpty)
        #expect(output.fileName == "invoice_1.pdf")

        // Keep the file around so it can be converted to an image for review.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("billify-layout-sample.pdf")
        try output.pdfData.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rendersEmptyDraftWithoutCrashing() throws {
        let output = PDFGenerator.generate(InvoiceData())
        #expect(!output.pdfData.isEmpty)
    }
}
