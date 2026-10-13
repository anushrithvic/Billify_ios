//
//  CorrectionParser.swift
//  Billify
//
//  Conversational editing (spec §48): detects correction-style messages
//  ("change the quantity to 25 bags", "the GST is 18% not 5%") and parses
//  them into typed field updates. Pure parsing with no state — mirrors the
//  role BulkTextExtractor plays for pasted text. The ChatViewModel applies
//  the results and confirms each change back to the user.
//

import Foundation

enum CorrectionParser {

    enum Correction: Equatable {
        case invoiceType(InvoiceType)
        case taxType(TaxType)
        case taxRate(Double)
        case buyerName(String)
        case buyerGstin(String)
        case buyerAddress(String)
        case invoiceNo(String)
        case invoiceDate(String)
        case ewayBill(String)
        case originalInvoiceNo(String)
        case originalInvoiceDate(String)
        case productName(String)
        case productHsn(String)
        case productQuantity(Int)
        case productUnit(ProductUnit)
        case productWeight(Double)
        case productRate(Double)
        case vehicleNo(String)
        case transporter(String)
        case transporterGstin(String)
    }

    // MARK: - Keyword table
    // Ordered most-specific first: at any position the first entry that
    // matches wins, so "original invoice number" beats "invoice number",
    // "gstin" beats "gst", and "gst rate" beats "rate".
    private static let fieldKeywords: [(pattern: String, numeric: Bool, parse: (String) -> Correction?)] = [
        ("original invoice (no|number)", false, { .originalInvoiceNo($0) }),
        ("original invoice date", false, { .originalInvoiceDate($0) }),
        ("transporter gstin", false, { .transporterGstin($0) }),
        ("(product|item) name", false, { .productName($0) }),
        ("buyer name", false, { .buyerName($0) }),
        ("buyer gstin", false, { .buyerGstin($0) }),
        ("invoice (no|number)", false, { .invoiceNo($0) }),
        ("invoice date", false, { .invoiceDate($0) }),
        ("e[ -]?way bill", false, { .ewayBill($0) }),
        ("document type", false, { Self.parseInvoiceType(in: $0).map(Correction.invoiceType) }),
        ("invoice type", false, { Self.parseInvoiceType(in: $0).map(Correction.invoiceType) }),
        ("tax type", false, { Self.parseTaxType(in: $0).map(Correction.taxType) }),
        ("(gst|tax) rate", true, { Self.parseNumber($0).map(Correction.taxRate) }),
        ("(quantity|qty)", true, { Self.parseInteger($0).map(Correction.productQuantity) }),
        ("weight", true, { Self.parseNumber($0).map(Correction.productWeight) }),
        ("rate per kg", true, { Self.parseNumber($0).map(Correction.productRate) }),
        ("hsn", false, { .productHsn($0) }),
        ("unit", false, { Self.parseUnit($0).map(Correction.productUnit) }),
        ("address", false, { .buyerAddress($0) }),
        ("gstin", false, { .buyerGstin($0) }),
        ("vehicle (no|number)", false, { .vehicleNo($0) }),
        ("transporter", false, { .transporter($0) }),
        ("vehicle", false, { .vehicleNo($0) }),
        ("(party|buyer)", false, { .buyerName($0) }),
        ("date", false, { .invoiceDate($0) }),
        ("gst", true, { Self.parseNumber($0).map(Correction.taxRate) }),
        ("name", false, { .buyerName($0) }),
        ("rate", true, { Self.parseNumber($0).map(Correction.productRate) }),
        ("invoice", false, { .invoiceNo($0) }),
        ("tax", true, { Self.parseNumber($0).map(Correction.taxRate) }),
    ]

    // MARK: - Entry point

    static func parse(from text: String) -> [Correction] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Long or digit-dense pasted text belongs on the BulkTextExtractor
        // path — unless it's a targeted correction. The digit heuristic alone
        // would swallow corrections whose values are number-heavy ("the date
        // is 25-08-2026", "vehicle no is TN 38 AB 1234"), so messages with a
        // change verb or assignment syntax still get parsed as edits.
        if looksLikeBulkText(trimmed) && !hasStrongVerbCue(trimmed) && !hasAssignmentSyntax(trimmed) {
            return []
        }

        // Collect every keyword hit, sorted by position. The sort is stable,
        // so at equal positions the more specific (earlier table) entry wins.
        var hits: [(index: Int, range: NSRange)] = []
        let ns = trimmed as NSString
        for (index, entry) in fieldKeywords.enumerated() {
            let regex = try! NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive])
            for match in regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length)) {
                hits.append((index, match.range))
            }
        }
        hits.sort {
            $0.range.location == $1.range.location ? $0.index < $1.index : $0.range.location < $1.range.location
        }

        guard !hits.isEmpty else {
            return fallbackTypeCorrections(for: trimmed)
        }

        let hasCue = hasChangeCue(trimmed)
        var corrections: [Correction] = []
        var accepted: [NSRange] = []

        for (position, hit) in hits.enumerated() {
            guard !accepted.contains(where: { NSIntersectionRange($0, hit.range).length > 0 }) else { continue }

            // The value is everything up to the next keyword hit (or the end).
            let nextStart = hits[(position + 1)...].first { $0.range.location >= hit.range.upperBound }?.range.location
            let valueRange = NSRange(location: hit.range.upperBound, length: (nextStart ?? trimmed.count) - hit.range.upperBound)
            let entry = fieldKeywords[hit.index]
            let rawValue = ns.substring(with: valueRange)

            let cleaned = cleanedValue(rawValue, numeric: entry.numeric)
            guard !cleaned.isEmpty else { continue }
            // A plain value is only accepted without a change cue when it
            // starts with a digit ("quantity 25"), so normal chat answers
            // ("25 bags") still go through the slot-filler.
            if !hasCue && !(cleaned.first?.isNumber == true) { continue }
            guard let correction = entry.parse(cleaned) else { continue }

            corrections.append(correction)
            accepted.append(hit.range)
        }

        // Document/tax-type renames can stand alone or join keyword matches:
        // "change to credit note", "make it IGST", "change to credit note and qty to 25".
        for extra in fallbackTypeCorrections(for: trimmed) where !corrections.contains(extra) {
            corrections.append(extra)
        }
        return corrections
    }

    // MARK: - Fallbacks (no keyword matched)

    private static func fallbackTypeCorrections(for text: String) -> [Correction] {
        guard hasChangeCue(text) else { return [] }
        var corrections: [Correction] = []
        if let type = parseInvoiceType(in: text) { corrections.append(.invoiceType(type)) }
        if let tax = parseTaxType(in: text) { corrections.append(.taxType(tax)) }
        return corrections
    }

    private static func parseInvoiceType(in text: String) -> InvoiceType? {
        let lower = text.lowercased()
        if lower.contains("credit note") { return .creditNote }
        if lower.contains("debit note") { return .debitNote }
        if lower.contains("delivery challan") || lower.contains("delivery note") || lower.contains("challan") {
            return .deliveryChallan
        }
        if lower.contains("tax invoice") { return .taxInvoice }
        return nil
    }

    private static func parseTaxType(in text: String) -> TaxType? {
        let lower = text.lowercased()
        if lower.contains("igst") || lower.contains("national") || lower.contains("inter") { return .national }
        if lower.contains("cgst") || lower.contains("sgst") || lower.contains("intra") || lower.contains("state") {
            return .state
        }
        return nil
    }

    private static func parseUnit(_ value: String) -> ProductUnit? {
        let lower = value.lowercased()
        let stem = String(lower.prefix(3))
        return ProductUnit.allCases.first { unit in
            let raw = unit.rawValue.lowercased()
            return lower.contains(raw) || raw.hasPrefix(stem)
        }
    }

    // MARK: - Value cleaning

    private static let leadingFillers = [
        "should be", "make it", "i want", "we want", "i need", "let's", "lets",
        "please", "kindly", "is", "are", "was", "were", "to", "as", "of", "for",
        "from", "the", "a", "an", "be", "make", "use", "it", "its", "now",
        "currently", "still", "at", "with", "want", "need",
    ]

    private static let trailingFillers = [
        "please", "kindly", "ok", "okay", "thanks", "thank you", "now", "the",
        "and", "then", "only", "also", "as well", "bro", "sir", "gst",
    ]

    private static let numericTrailingFillers = [
        "kg", "kgs", "kilogram", "kilograms", "per kg", "per kgs", "per kilo",
        "per", "qty", "bags", "bag", "bales", "bale", "bores", "bore", "nos",
        "pcs", "pieces", "rs", "rupees", "inr", "percent", "paise",
        "ton", "tons", "tonne", "tonnes",
    ]

    /// Strips filler words/punctuation around a raw value and cuts it at
    /// "not"/"instead" (the new value comes first) and at "from X to Y"
    /// (the new value is the last "to ..." clause).
    private static func cleanedValue(_ raw: String, numeric: Bool) -> String {
        var v = raw

        if let r = v.range(of: #"\b(not|instead of|instead)\b.*"#, options: .regularExpression) {
            v = String(v[..<r.lowerBound])
        }
        if let r = v.range(of: #"\bto\b[^,;]*$"#, options: .regularExpression) {
            v = String(v[r])
        }

        // Leading junk.
        var changed = true
        while changed {
            changed = false
            var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = s.first, ":,;.!?=₹$&()/\\->—–".contains(first) {
                s.removeFirst()
                changed = true
            }
            if s.isEmpty { return "" }
            let lower = s.lowercased()
            for filler in leadingFillers where lower == filler || lower.hasPrefix(filler + " ") {
                s.removeFirst(filler.count)
                changed = true
                break
            }
            v = s
        }

        // Trailing junk.
        changed = true
        while changed {
            changed = false
            var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = s.last, ":,;.!?=₹$&()/\\->—–%".contains(last) {
                s.removeLast()
                changed = true
            }
            if s.isEmpty { return "" }
            let lower = s.lowercased()
            let fillers = numeric ? trailingFillers + numericTrailingFillers : trailingFillers
            for filler in fillers where lower == filler || lower.hasSuffix(" " + filler) {
                s.removeLast(filler.count)
                changed = true
                break
            }
            v = s
        }

        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cues

    private static func hasStrongVerbCue(_ text: String) -> Bool {
        text.range(of: #"\b(change|update|set|correct|edit|fix|revise|modify|replace|adjust)\b"#,
                   options: .regularExpression) != nil
    }

    private static func hasChangeCue(_ text: String) -> Bool {
        hasStrongVerbCue(text)
            || text.range(of: #"\b(is|should|instead|not|make|use|want)\b"#, options: .regularExpression) != nil
            || hasAssignmentSyntax(text)
    }

    private static func hasAssignmentSyntax(_ text: String) -> Bool {
        text.contains(":") || text.contains("=")
            || text.range(of: #"\bis\b"#, options: .regularExpression) != nil
    }

    // MARK: - Number parsing

    private static func parseNumber(_ s: String) -> Double? {
        guard let r = s.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(String(s[r]))
    }

    private static func parseInteger(_ s: String) -> Int? {
        guard let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(String(s[r]))
    }

    // MARK: - Bulk-text guard (mirrors ChatViewModel)

    private static func looksLikeBulkText(_ text: String) -> Bool {
        let wordCount = text.split(separator: " ").count
        let digitGroups = text.filter(\.isNumber).count
        return wordCount >= 12 || digitGroups >= 6
    }
}