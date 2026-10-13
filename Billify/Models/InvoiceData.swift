//
//  InvoiceData.swift
//  Billify
//
//  The standardized invoice model (spec §37-38). Image extraction, conversational
//  chat, and bulk-text extraction must all produce this same structure — it's the
//  contract between the input layer and everything downstream (validation,
//  calculation, PDF generation).
//

import Foundation

enum InvoiceType: String, CaseIterable, Codable, Identifiable {
    case taxInvoice = "Tax Invoice"
    case creditNote = "Credit Note"
    case debitNote = "Debit Note"
    case deliveryChallan = "Delivery Challan"

    var id: String { rawValue }

    /// Documents that must name the invoice they refer back to (a credit note
    /// reverses an earlier sale; a debit note adds a charge against one).
    var referencesOriginalInvoice: Bool {
        self == .creditNote || self == .debitNote
    }
}

enum TaxType: String, CaseIterable, Codable, Identifiable {
    case state = "State"       // CGST + SGST
    case national = "National" // IGST

    var id: String { rawValue }
}

struct InvoiceDetails: Codable, Equatable {
    var invoiceNo: String = ""
    var date: String = ""              // kept as display string (e.g. "28-08-2026")
    var ewayBill: String = ""
    // Replaces the original app's combined "Original&Date" string (spec §4, §42)
    var originalInvoiceNo: String = ""
    var originalInvoiceDate: String = ""
}

struct TaxInfo: Codable, Equatable {
    var type: TaxType = .state
    /// Rate is data, not a hard-coded constant (spec §14) — the calculation
    /// engine applies whatever rate is supplied/validated here.
    var rate: Double = 5.0
}

struct InvoiceData: Codable, Equatable {
    var invoiceType: InvoiceType = .taxInvoice
    var invoiceDetails: InvoiceDetails = InvoiceDetails()

    var buyer: Party = Party()
    var shipping: Party = Party()
    var shippingSameAsBuyer: Bool = false   // replaces the old global `same` IntVar (spec §8)

    var transport: Transport = Transport()
    var products: [Product] = []
    var tax: TaxInfo = TaxInfo()

    /// Effective shipping party, resolving the "same as buyer" flag.
    var effectiveShipping: Party {
        shippingSameAsBuyer ? buyer : shipping
    }

    // MARK: - Required-field logic (spec §40-43)
    // Requirements differ by document type, so this isn't one fixed checklist.

    /// Ordered list of required fields still missing, as human-readable labels.
    /// ViewModels use this to know what to ask/prompt for next.
    var missingRequiredFields: [String] {
        var missing: [String] = []

        if invoiceDetails.invoiceNo.isEmpty { missing.append("Invoice Number") }
        if invoiceDetails.date.isEmpty { missing.append("Date") }

        if buyer.name.isEmpty { missing.append("Buyer Name") }
        if invoiceType != .deliveryChallan && buyer.gstin.isEmpty {
            missing.append("Buyer GSTIN")
        }
        if buyer.address[0].isEmpty { missing.append("Buyer Address") }

        if products.isEmpty {
            missing.append("At least one Product")
        } else {
            for (i, p) in products.enumerated() {
                if p.hsn.isEmpty { missing.append("Product \(i + 1) HSN Code") }
                if p.quantity == nil { missing.append("Product \(i + 1) Quantity") }
                if p.weightKg == nil { missing.append("Product \(i + 1) Weight (KG)") }
                if p.ratePerKg == nil { missing.append("Product \(i + 1) Rate per KG") }
            }
        }

        // Delivery Challans don't need tax info (spec §43)
        if invoiceType != .deliveryChallan {
            // tax.type/rate always have defaults, so nothing to flag as "missing" —
            // but Credit Notes need the original invoice reference (spec §42)
        }

        if invoiceType.referencesOriginalInvoice {
            if invoiceDetails.originalInvoiceNo.isEmpty { missing.append("Original Invoice Number") }
            if invoiceDetails.originalInvoiceDate.isEmpty { missing.append("Original Invoice Date") }
        }

        return missing
    }

    var isReadyForPreview: Bool {
        missingRequiredFields.isEmpty
    }
}
