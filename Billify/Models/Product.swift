//
//  Product.swift
//  Billify
//
//  A single line item on an invoice. Billify 2.0 supports an array of these,
//  fixing the original app's one-product-per-invoice limitation (see spec §11).
//

import Foundation

enum ProductUnit: String, CaseIterable, Codable, Identifiable {
    case bages = "BAGES"   // Spelling kept intentionally to match the original app (spec §9)
    case bales = "BALES"
    case bores = "BORES"

    var id: String { rawValue }
}

struct Product: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    var name: String = ""
    var hsn: String = ""
    var unit: ProductUnit = .bages
    var quantity: Int? = nil        // number of bags/bales/bores
    var weightKg: Double? = nil
    var ratePerKg: Double? = nil

    /// Taxable value for this line item (quantity is not used in the total —
    /// the original app calculates off weight × rate, spec §13).
    var totalValue: Double? {
        guard let weightKg, let ratePerKg else { return nil }
        return weightKg * ratePerKg
    }

    var isComplete: Bool {
        !name.isEmpty && !hsn.isEmpty && quantity != nil && weightKg != nil && ratePerKg != nil
    }

    /// Human-readable one-line summary, used in preview and chat confirmations.
    var summary: String {
        var parts: [String] = [name.isEmpty ? "Unnamed product" : name]
        if let quantity { parts.append("\(quantity) \(unit.rawValue)") }
        if let weightKg { parts.append("\(weightKg.formattedTrim) KG") }
        if let ratePerKg { parts.append("₹\(ratePerKg.formattedTrim)/KG") }
        return parts.joined(separator: ", ")
    }
}

extension Double {
    /// Trims trailing ".0" for cleaner display (850.0 -> "850").
    var formattedTrim: String {
        self.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", self)
            : String(self)
    }
}
