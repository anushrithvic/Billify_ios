//
//  InvoiceCalculation.swift
//  Billify
//
//  Shape of the deterministic calculation output (spec §13-14, §46). The AI/chat
//  layer never does this math itself — it only fills InvoiceData; this struct is
//  what a calculation engine (a later phase) will produce from it.
//

import Foundation

struct InvoiceCalculation: Codable, Equatable {
    var taxableValue: Double
    var cgst: Double
    var sgst: Double
    var igst: Double
    var grandTotal: Double
    var amountInWords: String

    static let empty = InvoiceCalculation(
        taxableValue: 0, cgst: 0, sgst: 0, igst: 0, grandTotal: 0, amountInWords: ""
    )
}
