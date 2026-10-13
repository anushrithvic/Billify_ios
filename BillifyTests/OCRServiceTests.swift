//
//  OCRServiceTests.swift
//  BillifyTests
//
//  Behavioral tests for Method-1 photo input (spec §29): the Vision-based
//  OCRService reads synthetic "photographed invoice" images, and the chat
//  pipeline folds the recognized text into the draft like a paste — including
//  re-mapping the seller's own printed GSTIN so it never becomes the buyer's.
//

import Testing
import UIKit
@testable import Billify

@MainActor
struct OCRServiceTests {

    // MARK: - Helpers

    /// Renders clean black-on-white text lines into a synthetic photo.
    private func imageFromLines(_ lines: [String]) -> UIImage {
        let font = UIFont.monospacedSystemFont(ofSize: 28, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
        ]
        let margin: CGFloat = 48
        let lineHeight: CGFloat = 44
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let width = (sizes.map(\.width).max() ?? 200) + margin * 2
        let height = CGFloat(lines.count) * lineHeight + margin * 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: margin, y: margin + CGFloat(index) * lineHeight),
                    withAttributes: attributes)
            }
        }
    }

    /// Waits (yielding the main actor) until `condition` holds or the timeout
    /// passes — the photo pipeline runs in a Task, so tests poll for its result.
    private func waitUntil(timeout: Duration = .seconds(30),
                           _ condition: @escaping () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: - OCRService

    @Test func recognizesTextInReadingOrder() async throws {
        let image = imageFromLines([
            "TAX INVOICE",
            "Buyer : Radhika Mills",
            "GSTIN : 33ABCDE1234F1Z5",
            "100 bales cotton yarn HSN 5205",
            "4000 kgs rate 150 per kg",
            "Invoice No : 42",
            "Date : 12-08-2026",
        ])
        let data = try #require(image.jpegData(compressionQuality: 1.0))
        let result = await OCRService.recognizeText(in: data)
        let lower = result.text.lowercased()

        #expect(lower.contains("radhika"))
        #expect(lower.contains("33abcde1234f1z5"))
        #expect(lower.contains("5205"))
        #expect(lower.contains("4000"))
        #expect(lower.contains("12-08-2026"))

        // Lines come back top → bottom, so the last drawn line should sort
        // after the first one.
        if let first = lower.range(of: "radhika"),
           let last = lower.range(of: "12-08-2026") {
            #expect(first.lowerBound < last.lowerBound)
        }
    }

    // MARK: - Chat pipeline

    @Test func photoPipelineExtractsFieldsAndRemapsSellerGstin() async throws {
        // A photographed invoice prints the seller's own GSTIN in the header
        // (first in the text) and the buyer's further down — the extractor's
        // "first GSTIN is the buyer" rule must be corrected for that.
        let image = imageFromLines([
            "ANUSH TRADERS",
            "6/24-A DEVANGAPURAM COIMBATORE",
            "GSTIN : 33AIMPM2628J1Z4",
            "TAX INVOICE",
            "Buyer : Radhika Mills",
            "GSTIN : 33ABCDE1234F1Z5",
            "Product : 100 bales cotton yarn HSN 5205",
            "weight 4000 kgs rate 150 per kg",
            "Invoice No : 42",
            "Date : 12-08-2026",
        ])

        let viewModel = ChatViewModel(
            memory: MemoryStore(defaults: UserDefaults(suiteName: "ocr-pipeline-\(UUID().uuidString)")!),
            initialType: .taxInvoice)
        viewModel.processPhoto(image)

        try await waitUntil {
            viewModel.messages.contains { $0.text.contains("here's what I found") }
        }

        #expect(viewModel.messages.contains { $0.text.contains("here's what I found") })
        // Seller's GSTIN was re-mapped: the second GSTIN (the buyer's) landed
        // on the buyer, and nothing was left on transport.
        #expect(viewModel.draft.buyer.gstin == "33ABCDE1234F1Z5")
        #expect(viewModel.draft.transport.gstin.isEmpty)
        #expect(viewModel.draft.buyer.name.localizedCaseInsensitiveContains("Radhika"))
        #expect(viewModel.draft.products.first?.quantity == 100)
        #expect(viewModel.draft.products.first?.unit == .bales)
        #expect(viewModel.draft.products.first?.name.lowercased().contains("cotton yarn") == true)
        #expect(viewModel.draft.products.first?.hsn == "5205")
        #expect(viewModel.draft.products.first?.weightKg == 4000)
        #expect(viewModel.draft.products.first?.ratePerKg == 150)
        #expect(viewModel.draft.invoiceDetails.invoiceNo == "42")
        #expect(viewModel.draft.invoiceDetails.date == "12-08-2026")
        // The photo bubble shows the user's thumbnail message.
        #expect(viewModel.messages.contains { message in
            if case .image = message.attachment { return true }
            return false
        })
    }
}
