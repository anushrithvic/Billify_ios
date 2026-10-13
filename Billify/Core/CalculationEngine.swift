//
//  CalculationEngine.swift
//  Billify
//
//  Deterministic math only — no AI, no extraction (spec §45-46).
//  Takes a finished InvoiceData and produces an InvoiceCalculation.
//

import Foundation

enum CalculationEngine {

    static func calculate(_ data: InvoiceData) -> InvoiceCalculation {
        let taxableValue = data.products.reduce(0.0) { total, product in
            total + (product.totalValue ?? 0)
        }

        var cgst = 0.0
        var sgst = 0.0
        var igst = 0.0

        if data.invoiceType != .deliveryChallan {
            switch data.tax.type {
            case .state:
                let half = (data.tax.rate / 2.0) / 100.0
                cgst = (taxableValue * half).rounded()
                sgst = (taxableValue * half).rounded()
            case .national:
                let rate = data.tax.rate / 100.0
                igst = (taxableValue * rate).rounded()
            }
        }

        let grandTotal = taxableValue + cgst + sgst + igst
        let words = NumberToWords.convert(Int(grandTotal.rounded()))

        return InvoiceCalculation(
            taxableValue: taxableValue,
            cgst: cgst,
            sgst: sgst,
            igst: igst,
            grandTotal: grandTotal,
            amountInWords: words
        )
    }
}
