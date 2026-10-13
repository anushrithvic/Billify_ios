//
//  BulkTextExtractor.swift
//  Billify
//
//  Extracts invoice fields from a single unstructured block of text
//  (spec §29 Method 3, §36). This is deliberately regex/keyword-based rather
//  than a full NLP model — it's meant to catch the common, fairly
//  standardized ways people phrase invoice info (GSTINs, weights, rates,
//  vehicle numbers all have fairly rigid formats in India). A future phase
//  can swap this out for an LLM-based extractor without changing anything
//  downstream, since the output is still just an InvoiceData + a list of
//  what it's still unsure about (spec §33).
//
//  Robustness notes (what the extractor tries hard to handle):
//  • Everything matches case-insensitively (lowercased pastes are common)
//  • GSTINs / vehicle numbers are normalized to uppercase
//  • E-way bill, LR number, transporter GSTIN and original-invoice
//    references (credit notes) are extracted, not just invoice number/date
//  • Buyer names come from many phrasings ("for X", "buyer : X", "billed
//    to X", "customer X", …) and buyer addresses are captured too
//  • Multiple product rows ("…100 bales cotton yarn HSN 5205 / 200 bales
//    waste HSN 5202…") become separate Product entries instead of one
//    merged blob
//

import Foundation

struct ExtractionResult {
    var data: InvoiceData
    /// Fields the extractor found but isn't fully confident about
    /// (spec §33 — OCR/extraction uncertainty should be surfaced, not silently guessed).
    var uncertainFields: [String] = []
}

enum BulkTextExtractor {

    // MARK: - Regexes for well-formatted Indian invoice fields

    /// Standard 15-character GSTIN format: 2-digit state code, 10-char PAN
    /// (5 letters, 4 digits, 1 letter), 1 alphanumeric entity code, literal
    /// "Z", 1 alphanumeric checksum.
    private static let gstinPattern = #"\b\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d]\b"#

    /// Indian vehicle number, e.g. TN38AB1234 or TN-38-AB-1234.
    private static let vehiclePattern = #"\b[A-Z]{2}[\s-]?\d{1,2}[\s-]?[A-Z]{1,3}[\s-]?\d{3,4}\b"#

    /// HSN code — 4 to 8 digits, usually right after the word "HSN".
    private static let hsnCodePattern = #"\b(?:hsn|h\.s\.n\.?)\s*(?:code)?\s*[:#\-]?\s*(\d{4,8})(?!\d)"#

    /// Product rows written the natural way: "100 bales cotton yarn hsn 5205".
    private static let productRowPattern = #"(\d+(?:\.\d+)?)\s+(\#(quantityUnitWords))\s+(?:of\s+)?([A-Za-z][A-Za-z0-9&.,' \-]{1,60}?)\s+(?:hsn|h\.s\.n\.?)\s*[:#\-]?\s*(\d{4,8})(?!\d)"#

    /// Name written directly before an HSN code: "cotton yarn HSN 5205".
    private static let nameBeforeHsnPattern = #"(?:^|[.;\n])\s*([A-Za-z][A-Za-z0-9&.,' \-]{1,60}?)\s+(?:hsn|h\.s\.n\.?)\s*[:#\-]?\s*(\d{4,8})(?!\d)"#

    private static let weightPattern = #"(?<![/@.])(\d+(?:\.\d+)?)\s*kgs?\b"#
    /// Any number written directly before "per kg"/"/kg"/"per kilogram" — with
    /// or without a rate/price/₹ prefix ("rate 150 per kg", "price of 500 per
    /// KG", "₹40/kg", "500 per kg", "150/- per kg").
    private static let ratePattern = #"(?:(?:rate|price)\s*(?:of|is|as)?\s*[:#]?\s*|@\s*|(?:rs\.?|₹)\s*)?(\d+(?:\.\d+)?)\s*(?:/-)?\s*(?:per\s*kg\b|/kg|per\s*kilogram\b)"#
    /// Words used for a countable line-item quantity. Kept broader than the
    /// app's 3 stored unit cases (bags/bales/bores, spec §9) so a quantity
    /// written as "20 pieces" or "15 rolls" is still captured as a number —
    /// it just maps to the closest stored unit rather than being silently
    /// dropped for using an unrecognized word.
    private static let quantityUnitWords = #"bags?|bales?|bores?|pieces?|pcs\.?|nos\.?|rolls?|cartons?|boxes?|units?"#
    /// Natural product clause without an HSN: "10 KG of cotton with price of
    /// 500 per KG" (weight-quantified) or "100 bales of cotton waste @ 40/kg".
    private static let productClauseKgPattern = #"\b(\d+(?:\.\d+)?)\s*(?:kg|kgs?|kilograms?)\s+of\s+([A-Za-z][A-Za-z0-9&.,' \-]{1,60}?)(?=(?:\s+(?:with|and|at|rate|price|@))|,|$)"#
    private static let productClauseUnitPattern = #"\b(\d+)\s+(\#(quantityUnitWords))\s+of\s+([A-Za-z][A-Za-z0-9&.,' \-]{1,60}?)(?=(?:\s+(?:with|and|at|rate|price|@))|,|$)"#
    private static let quantityPattern = #"(\d+)\s*(\#(quantityUnitWords))\b"#
    private static let invoiceNoPattern = #"\b(?:invoice|(?<!way )bill)\s*(?:no\.?|number)?\s*[:#\-]?\s*((?=[A-Z0-9/\-]*\d)[A-Z0-9][A-Z0-9/\-]{0,20})\b"#
    /// E-way bills are exactly 12 digits and usually labelled ("E-way bill no",
    /// "e-way 2310…").
    private static let ewayPattern = #"\b(?:e-?way\s*bill|ewaybill|e-?way)\s*(?:no\.?|number)?\s*[:#\-]?\s*([0-9]{12})\b"#
    private static let lrPattern = #"\b(?:lr|l\.r\.?)\s*(?:no\.?|number)?\s*[:#\-]?\s*((?=[A-Z0-9/\- ]*\d)[A-Z0-9][A-Z0-9/\- ]{0,12})\b"#
    private static let transporterGstinPattern = #"\btransporter(?:'s)?\s+gst(?:in)?\s*[:#\-]?\s*(\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d])"#

    /// Numeric dates like 28-08-2026 or 28/08/2026.
    private static let dateNumericPattern = #"\b(\d{1,2}[-/]\d{1,2}[-/]\d{2,4})\b"#
    /// Written-month dates like "28 August 2026" or "28th Aug 2026".
    private static let dateWrittenPattern = #"\b(\d{1,2}(?:st|nd|rd|th)?\s+(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\s+\d{4})\b"#

    /// Products the user (a trader supplying spinning mills) actually bills —
    /// matched only as a last resort when no structural pattern was found.
    private static let commodityPhrases = [
        "cotton yarn", "cotton waste", "combed yarn", "carded yarn", "blow room waste",
        "comber noil", "yarn waste", "cotton bales", "cotton", "yarn", "waste",
        "sliver", "roving", "noil", "polyester", "viscose", "grey yarn"
    ]

    // MARK: - Entry point

    static func extract(from rawText: String) -> ExtractionResult {
        var data = InvoiceData()
        var uncertain: [String] = []
        let lower = rawText.lowercased()

        // Commas inside numbers ("4,000 kgs") break digit parsing; harmless to
        // drop them when they sit between digits.
        let text = rawText.replacingOccurrences(
            of: #",(?=\d)"#, with: "", options: .regularExpression)

        // --- Invoice type ---
        if lower.contains("credit note") {
            data.invoiceType = .creditNote
        } else if lower.contains("debit note") {
            data.invoiceType = .debitNote
        } else if lower.contains("delivery challan") || lower.contains("delivery note") {
            data.invoiceType = .deliveryChallan
        } else {
            data.invoiceType = .taxInvoice
        }

        // --- Tax type ---
        if lower.contains("national") || lower.contains("igst") {
            data.tax.type = .national
        } else if lower.contains("state") || lower.contains("cgst") || lower.contains("sgst") {
            data.tax.type = .state
        }

        // --- GSTINs (buyer, then transporter) ---
        let gstins = matches(of: gstinPattern, in: text).map { $0.uppercased() }
        if let first = gstins.first { data.buyer.gstin = first }
        if gstins.count > 1 { data.transport.gstin = gstins[1] }
        if let transporterGstin = firstCapturedGroup(of: transporterGstinPattern, in: text) {
            data.transport.gstin = transporterGstin.uppercased()
        }

        // --- Vehicle number ---
        if let vehicle = firstMatch(of: vehiclePattern, in: text) {
            data.transport.vehicleNo = vehicle
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .uppercased()
        }

        // --- E-way bill & LR number ---
        if let eway = firstCapturedGroup(of: ewayPattern, in: text) {
            data.invoiceDetails.ewayBill = eway
        }
        if let lr = firstCapturedGroup(of: lrPattern, in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            data.transport.lrNo = lr
        }

        // --- Buyer (name & address before products, so a known buyer name can
        // be scrubbed out of product-name captures) ---
        let buyerName = extractBuyerName(from: text, lower: lower)
        if let buyerName { data.buyer.name = buyerName } else { uncertain.append("Buyer name") }
        if let addressLines = extractBuyerAddress(from: text, buyerName: buyerName) {
            data.buyer.address = addressLines
        }

        // --- Shipping (only when explicitly labelled) ---
        if let shipping = extractShipping(from: text) {
            data.shipping = shipping
            data.shippingSameAsBuyer = false
        }

        // --- Products (one or many) ---
        let productResult = extractProducts(from: text, lower: lower, buyerName: buyerName)
        data.products = productResult.products
        if productResult.needsNameConfirmation {
            uncertain.append("Product name")
        }

        // --- Invoice number ---
        if let invNo = firstCapturedGroup(of: invoiceNoPattern, in: text) {
            data.invoiceDetails.invoiceNo = invNo
        }

        // --- Dates (invoice date, plus original-invoice date for credit notes) ---
        let dates = collectDates(from: text)
        if data.invoiceType.referencesOriginalInvoice,
           let original = originalInvoiceReference(in: text) {
            // A credit note's own date usually precedes the original reference;
            // whatever date is mentioned after it belongs to the original invoice.
            data.invoiceDetails.originalInvoiceNo = original.number
            // Don't let the original's number masquerade as our own.
            if data.invoiceDetails.invoiceNo == original.number {
                data.invoiceDetails.invoiceNo = ""
            }
            if let originalDate = collectDates(from: original.tail).first {
                data.invoiceDetails.originalInvoiceDate = originalDate
            }
            if let own = dates.first(where: { date in
                guard let ownRange = rangeOf(date, in: text) else { return false }
                return ownRange.lowerBound < original.range.lowerBound
            }) {
                data.invoiceDetails.date = own
            }
        }

        if data.invoiceDetails.date.isEmpty {
            if let hinted = dateFollowingDateKeyword(in: text) {
                data.invoiceDetails.date = hinted
            } else if let date = dates.first {
                data.invoiceDetails.date = date
            } else {
                // No date mentioned anywhere in the paste (or just the word
                // "today") — default to today's date rather than leaving it
                // blank. It's editable in the review screen before the PDF
                // is generated, so this is a starting point, not a guess
                // presented as fact.
                data.invoiceDetails.date = todayString()
            }
        }

        // --- Transporter name ---
        if let transporter = extractAfterKeyword("transporter", in: text) {
            data.transport.transporter = transporter
        }

        return ExtractionResult(data: data, uncertainFields: uncertain)
    }

    // MARK: - Products

    private struct ProductExtraction {
        var products: [Product]
        var needsNameConfirmation: Bool
    }

    private static func extractProducts(from text: String, lower: String, buyerName: String?) -> ProductExtraction {
        // 1) Full rows: "100 bales cotton yarn HSN 5205" — repeatable.
        let rowMatches = allFullMatches(of: productRowPattern, in: text)
        if !rowMatches.isEmpty {
            var products: [Product] = []
            for row in rowMatches {
                var p = Product()
                if let qty = Int(row.group1 ?? "") { p.quantity = qty }
                p.unit = unit(from: row.group2 ?? "")
                p.name = cleanProductName(row.group3 ?? "", excluding: buyerName)
                p.hsn = row.group4 ?? ""
                products.append(p)
            }
            distribute(weights: text, rates: text, into: &products)
            return ProductExtraction(products: products, needsNameConfirmation: false)
        }

        // 1.5) Multiple products on separate lines/segments that don't share
        // the strict "N bags NAME hsn CODE" shape rowMatches expects above —
        // e.g. one product per line, "Product 1: … Product 2: …", or the
        // name written before its HSN on each line. Only kicks in when at
        // least two segments independently look like a product line on their
        // own (their own HSN, or a quantity paired with a weight/rate) —
        // ordinary multi-line pastes (buyer name on one line, address on the
        // next, invoice number on a third) never look like that, so this
        // doesn't risk misreading unrelated lines as extra products.
        if let segmented = extractProductsFromSegments(text, buyerName: buyerName), segmented.count >= 2 {
            return ProductExtraction(
                products: segmented,
                needsNameConfirmation: segmented.contains { $0.name.isEmpty }
            )
        }

        // 2) Clause reader — the general path for natural sentences (and the
        //    reason this extractor stopped being a list of fixed templates).
        //    The sentence is cut into clauses at field-introducing words
        //    ("with", "for", "consisting", "in 30 bags", "as a product",
        //    "invoice number"…) and each clause is classified by what it
        //    *contains*: a weight, a rate, a count, a name. Fields are then
        //    assembled order-independently, so "price of 200 per KG … in 30
        //    bags" parses exactly like "in 30 bags … price of 200 per KG" —
        //    word order no longer decides whether a sentence extracts.
        if let clauseProduct = productFromClauses(text, lower: lower, buyerName: buyerName) {
            return ProductExtraction(
                products: [clauseProduct],
                needsNameConfirmation: clauseProduct.name.isEmpty && !clauseProduct.hsn.isEmpty
            )
        }

        // 3) HSN alone → a product row with the code but no confirmed name.
        if let hsn = firstCapturedGroup(of: hsnCodePattern, in: text) {
            var p = Product()
            p.hsn = hsn
            if let qtyMatch = firstFullMatch(of: quantityPattern, in: text) {
                p.quantity = Int(qtyMatch.group1 ?? "")
                p.unit = unit(from: qtyMatch.group2 ?? "")
            }
            if let weightStr = firstCapturedGroup(of: weightPattern, in: text) {
                p.weightKg = Double(weightStr)
            }
            if let rateStr = firstCapturedGroup(of: ratePattern, in: text) {
                p.ratePerKg = Double(rateStr)
            }
            p.name = commodityName(in: lower)
            return ProductExtraction(products: [p], needsNameConfirmation: p.name.isEmpty)
        }

        return ProductExtraction(products: [], needsNameConfirmation: false)
    }

    // MARK: - Multi-line / multi-segment products

    /// Splits a paste into candidate product segments and extracts a product
    /// from each segment that looks like one on its own, for pastes with
    /// several products that aren't in the strict repeatable row format
    /// (different field order per line, dash-separated fields, etc.).
    private static func extractProductsFromSegments(_ text: String, buyerName: String?) -> [Product]? {
        let segments = splitProductSegments(text).filter(segmentLooksLikeProduct)
        guard segments.count >= 2 else { return nil }

        var products: [Product] = []
        for segment in segments {
            if let p = productFromClauses(segment, lower: segment.lowercased(), buyerName: buyerName) {
                products.append(p)
            } else if let hsn = firstCapturedGroup(of: hsnCodePattern, in: segment) {
                var p = Product()
                p.hsn = hsn
                if let qty = firstFullMatch(of: quantityPattern, in: segment) {
                    p.quantity = Int(qty.group1 ?? "")
                    p.unit = unit(from: qty.group2 ?? "")
                }
                if let weightStr = firstCapturedGroup(of: weightPattern, in: segment) {
                    p.weightKg = Double(weightStr)
                }
                if let rateStr = firstCapturedGroup(of: ratePattern, in: segment) {
                    p.ratePerKg = Double(rateStr)
                }
                products.append(p)
            }
        }
        return products.isEmpty ? nil : products
    }

    /// Breaks a paste into per-product candidate chunks. Explicit numbered
    /// markers ("Product 1:", "Item 2)", a leading "1.") start a new chunk
    /// when present; otherwise lines and `;`-separated clauses are the
    /// boundaries.
    private static func splitProductSegments(_ text: String) -> [String] {
        let markerPattern = #"(?:^|[\n;])\s*(?:product|item)\s*\d+\s*[:#\-\)]\s*|(?:^|\n)\s*\d{1,2}[\.\)]\s+"#
        if let regex = try? NSRegularExpression(pattern: markerPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: nsRange)
            if matches.count >= 2 {
                var chunks: [String] = []
                for (i, m) in matches.enumerated() {
                    guard let matchRange = Range(m.range, in: text) else { continue }
                    let start = matchRange.upperBound
                    let end = i + 1 < matches.count
                        ? (Range(matches[i + 1].range, in: text)?.lowerBound ?? text.endIndex)
                        : text.endIndex
                    guard start < end else { continue }
                    let chunk = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !chunk.isEmpty { chunks.append(chunk) }
                }
                if chunks.count >= 2 { return chunks }
            }
        }
        // Fall back to plain line/semicolon boundaries.
        return text.components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A segment only counts as its own product when it carries product-shaped
    /// data by itself — an HSN code, or a quantity paired with a weight/rate
    /// (or a weight and a rate together). This is what keeps ordinary
    /// multi-line pastes from being misread as several separate products.
    private static func segmentLooksLikeProduct(_ segment: String) -> Bool {
        if firstCapturedGroup(of: hsnCodePattern, in: segment) != nil { return true }
        let hasQuantity = firstFullMatch(of: quantityPattern, in: segment) != nil
        let hasWeight = firstCapturedGroup(of: weightPattern, in: segment) != nil
        let hasRate = firstCapturedGroup(of: ratePattern, in: segment) != nil
        return (hasQuantity && (hasWeight || hasRate)) || (hasWeight && hasRate)
    }

    // MARK: - Clause reader

    /// Cuts a sentence into clauses at field-introducing words. The anchors
    /// carry lookaheads so ordinary prose ("…and sons", "…in Coimbatore")
    /// doesn't split, while "with", "for", "consisting 10 KG's", "in 30 bags",
    /// "as a product", "invoice number 2" and friends do.
    private static let clauseAnchorPattern = #"\bfor\s+(?=[A-Za-z])|\bwith\s+(?=[A-Za-z])|\band\s+(?=\d)|\bin\s+(?=\d)|\bconsisting\s*(?:of)?\s+(?=\d)|\bbuyer\b|\bbilled\s+to\b|\bcustomer\b|\bconsignee\b|\bas\s+(?:a|the)\s+product\b|\binvoice\s*(?:no\.?|number)?\s*(?=\d)|\bdated?\b|\bhsn\b|\bh\.s\.n\.?\b"#

    private static func segment(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: clauseAnchorPattern, options: [.caseInsensitive]) else {
            return [text]
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [text] }

        var clauses: [String] = []
        var cursor = text.startIndex
        for match in matches {
            guard let lowerBound = Range(match.range, in: text)?.lowerBound else { continue }
            if lowerBound > cursor {
                clauses.append(String(text[cursor..<lowerBound]))
            }
            cursor = lowerBound
        }
        if cursor < text.endIndex {
            clauses.append(String(text[cursor...]))
        }
        return clauses
    }

    /// Assembles one product from a clause-segmented sentence. Every field is
    /// gathered from whatever clause mentions it — position in the sentence is
    /// irrelevant, which is what makes the extractor survive natural phrasing.
    private static func productFromClauses(_ text: String, lower: String, buyerName: String?) -> Product? {
        let clauses = segment(text)

        var weights: [Double] = []
        var rates: [Double] = []
        var quantities: [(value: Int, unit: ProductUnit)] = []
        var hsn = ""
        var naturalProducts: [Product] = []
        var nameClauses: [(index: Int, name: String)] = []
        var nameBeforeHsn: (name: String, code: String)? = nil
        var markerIndex: Int? = nil

        for (index, clause) in clauses.enumerated() {
            let c = clause
            if let w = firstCapturedGroup(of: weightPattern, in: c).flatMap(Double.init), w > 0 {
                weights.append(w)
            }
            if let r = firstCapturedGroup(of: ratePattern, in: c).flatMap(Double.init), r > 0 {
                rates.append(r)
            }
            if let q = firstFullMatch(of: quantityPattern, in: c),
               let n = Int(q.group1 ?? ""), n > 0 {
                quantities.append((n, unit(from: q.group2 ?? "")))
            }
            if hsn.isEmpty, let h = firstCapturedGroup(of: hsnCodePattern, in: c) {
                hsn = h
            }
            if let natural = naturalProductClause(in: c) {
                naturalProducts.append(natural)
            }
            if isProductMarkerClause(c) { markerIndex = index }
            if nameBeforeHsn == nil, let match = firstFullMatch(of: nameBeforeHsnPattern, in: c) {
                nameBeforeHsn = (match.group1 ?? "", match.group2 ?? "")
            }
            if let name = nameFromClause(c, buyerName: buyerName) {
                nameClauses.append((index, name))
            }
        }

        // Nothing product-like in the sentence at all — let the chat ask
        // instead of inventing an empty row.
        guard !weights.isEmpty || !rates.isEmpty || !quantities.isEmpty || !hsn.isEmpty
                || !naturalProducts.isEmpty || !nameClauses.isEmpty || nameBeforeHsn != nil
                || !commodityName(in: lower).isEmpty else {
            return nil
        }

        var p = Product()
        p.hsn = hsn.isEmpty ? (nameBeforeHsn?.code ?? "") : hsn

        // Name resolution, in order of authority:
        // 1. The clause right before an "as a product" marker
        //    ("with cotton Lint as a product" → "cotton Lint")
        // 2. A natural "10 KG of cotton" / "20 bales of waste" clause
        // 3. A bare name before an HSN ("cotton yarn HSN 5205")
        // 4. The leftover words of the sentence after every number/unit/field
        //    is stripped ("cotton lint 10 kg 200 per kg 30 bags" → "cotton lint")
        // 5. A known spinning-mill commodity keyword
        if let markerIndex,
           let best = nameClauses.last(where: { $0.index < markerIndex }) {
            p.name = best.name
        }
        if p.name.isEmpty, let natural = naturalProducts.first {
            p.name = natural.name
        }
        if p.name.isEmpty, let nbh = nameBeforeHsn {
            p.name = cleanProductName(nbh.name, excluding: buyerName)
        }
        if p.name.isEmpty, let leftover = leftoverName(from: text, buyerName: buyerName) {
            // An exact commodity match keeps the canonical capitalized form
            // ("cotton" → "Cotton"); anything longer stays as the user wrote it.
            let commodity = commodityName(in: lower)
            p.name = (commodity.caseInsensitiveCompare(leftover) == .orderedSame) ? commodity : leftover
        }
        if p.name.isEmpty {
            p.name = commodityName(in: lower)
        }

        // Weight/quantity prefer a natural clause's own values, then standalone
        // mentions anywhere in the sentence.
        if let natural = naturalProducts.first {
            p.weightKg = natural.weightKg ?? weights.first
            p.quantity = natural.quantity ?? quantities.first?.value
            p.unit = natural.quantity != nil ? natural.unit : (quantities.first?.unit ?? .bages)
        } else {
            p.weightKg = weights.first
            p.quantity = quantities.first?.value
            p.unit = quantities.first?.unit ?? .bages
        }
        p.ratePerKg = rates.first

        return p
    }

    /// "as a product" / "as the product" — marks the previous name clause.
    private static func isProductMarkerClause(_ clause: String) -> Bool {
        firstMatch(of: #"\bas\s+(?:a|the)\s+product\b"#, in: clause) != nil
    }

    /// A clause that consists of a product name: only letters, no quantities,
    /// weights, rates, HSNs or field words ("with cotton Lint" qualifies;
    /// "for Anish traders" and "with the price of 200 per KG" don't).
    private static func nameFromClause(_ clause: String, buyerName: String?) -> String? {
        let t = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return nil }
        if firstFullMatch(of: quantityPattern, in: t) != nil { return nil }
        if firstCapturedGroup(of: weightPattern, in: t) != nil { return nil }
        if firstCapturedGroup(of: hsnCodePattern, in: t) != nil { return nil }

        let fieldWords = ["invoice", "date", "gstin", "gst", "transporter", "vehicle", "rate",
                          "price", "product", "consisting", "hsn", "buyer", "customer",
                          "consignee", "billed", "today", "eway", "challan", "delivery",
                          "credit", "debit", "tax", "create", "please", "kindly", "for",
                          "number", "no"]
        for word in fieldWords where containsFieldWord(t, word) { return nil }
        if let buyerName, !buyerName.isEmpty, containsFieldWord(t, buyerName) { return nil }

        let name = cleanProductName(t, excluding: buyerName)
        return isValidProductName(name) ? name : nil
    }

    /// The words left over after every number, unit, rate, date and field
    /// label is stripped from the sentence — the product name, usually.
    private static func leftoverName(from text: String, buyerName: String?) -> String? {
        var t = text
        if let buyerName, !buyerName.isEmpty {
            t = t.replacingOccurrences(of: buyerName, with: "", options: [.caseInsensitive])
        }
        for pattern in [gstinPattern, vehiclePattern, hsnCodePattern, weightPattern,
                        quantityPattern, ratePattern, invoiceNoPattern, ewayPattern,
                        dateNumericPattern, dateWrittenPattern] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(
            of: #"\b(?:per|kg|kgs|kilograms?|rate|price|of|at|the|in|and|with|for|as|a|an|bags?|bales?|bores?|qty|quantity|weight|unit|consisting|product|hsn|invoice|date|today|create|make|please|kindly)\b"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        let joined = t.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: \.isLetter) }
            .joined(separator: " ")
        return isValidProductName(joined) ? joined : nil
    }

    private static func containsFieldWord(_ text: String, _ word: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b",
            options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Parses "<amount> <kg|bales|…> of <product name>" into a Product. Used for
    /// natural chat-style sentences that describe one item without an HSN.
    private static func naturalProductClause(in text: String) -> Product? {
        // Weight-quantified: "10 KG of cotton". Quantity is unknown — only the
        // weight matters to the total (weight × rate), so leave quantity nil.
        if let match = firstFullMatch(of: productClauseKgPattern, in: text) {
            let name = cleanProductName(match.group2 ?? "", excluding: nil)
            guard isValidProductName(name), let weight = Double(match.group1 ?? "") else { return nil }
            var p = Product()
            p.name = name
            p.weightKg = weight
            return p
        }
        // Count-quantified: "100 bales of cotton waste".
        if let match = firstFullMatch(of: productClauseUnitPattern, in: text) {
            let name = cleanProductName(match.group3 ?? "", excluding: nil)
            guard isValidProductName(name), let quantity = Int(match.group1 ?? "") else { return nil }
            var p = Product()
            p.name = name
            p.unit = unit(from: match.group2 ?? "")
            p.quantity = quantity
            return p
        }
        return nil
    }

    /// If a paste carries weight/rate numbers separate from product rows, attach
    /// them positionally (row 1's weight/rate to product 1, etc.).
    private static func distribute(weights source: String, rates rateSource: String, into products: inout [Product]) {
        let weights = allCapturedGroups(of: weightPattern, group: 1, in: source).compactMap { Double($0) }
        let rates = allCapturedGroups(of: ratePattern, group: 1, in: rateSource).compactMap { Double($0) }
        guard !products.isEmpty else { return }
        for i in products.indices {
            if products[i].weightKg == nil, i < weights.count { products[i].weightKg = weights[i] }
            if products[i].ratePerKg == nil, i < rates.count { products[i].ratePerKg = rates[i] }
        }
        // A lone "in 30 bags" / "… in 5 bales" mention after the product's rate
        // carries the bag count when a single description product was parsed
        // (row-style inputs already set quantity per row).
        if products.count == 1, products[0].quantity == nil,
           let qtyMatch = firstFullMatch(of: quantityPattern, in: source) {
            products[0].quantity = Int(qtyMatch.group1 ?? "")
            products[0].unit = unit(from: qtyMatch.group2 ?? "")
        }
    }

    private static func unit(from word: String) -> ProductUnit {
        if word.hasPrefix("bag") { return .bages }
        if word.hasPrefix("bale") { return .bales }
        if word.hasPrefix("bore") { return .bores }
        return .bages
    }

    /// Trims filler words and any known buyer name out of a captured product name.
    private static func cleanProductName(_ raw: String, excluding buyerName: String?) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let buyerName, !buyerName.isEmpty,
           let range = name.range(of: buyerName, options: [.caseInsensitive]) {
            name.removeSubrange(range)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ",;:- \n"))
        for filler in ["please ", "kindly ", "make an invoice for ", "create an invoice for ",
                       "create invoice for ", "an invoice for ", "for ", "the product ",
                       "product ", "invoice ", "with "] {
            if name.lowercased().hasPrefix(filler) {
                name = String(name.dropFirst(filler.count))
                break
            }
        }
        // Bulk pastes often use dashes as bullets/separators ("Cotton Yarn -
        // HSN 5205 - 100 bales…"), which would otherwise leave a trailing "-"
        // stuck to the captured name.
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
    }

    /// A captured product name must actually look like a name — short, mostly
    /// letters, no stray commas/clauses left over.
    private static func isValidProductName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let letters = trimmed.filter(\.isLetter).count
        guard letters >= 3, letters > trimmed.filter(\.isNumber).count else { return false }
        guard !trimmed.contains(","), !trimmed.lowercased().contains(" for ") else { return false }
        return true
    }

    private static func commodityName(in lower: String) -> String {
        for phrase in commodityPhrases where lower.contains(phrase) {
            return phrase.split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
        return ""
    }

    // MARK: - Buyer

    /// Buyer names come in many phrasings: "invoice for X", "buyer : X",
    /// "billed to X", "customer X"… Try each until one yields a name.
    private static func extractBuyerName(from text: String, lower: String) -> String? {
        // A bare "for X" clause is only treated as a buyer when the message is
        // clearly about an invoice ("invoice for cotton yarn…" alone shouldn't
        // invent a buyer called "Cotton Yarn").
        let hasInvoiceContext = lower.contains("invoice") || lower.contains("bill")
            || lower.contains("credit note") || lower.contains("challan")
            || lower.contains("delivery") || lower.contains("gst")
            || matches(of: gstinPattern, in: text).isEmpty == false

        let labels = ["buyer name", "buyer", "billed to", "bill to", "sold to", "m/s",
                      "consignee", "customer", "party name"]
        for label in labels {
            if let candidate = valueAfterKeyword(label, in: text) {
                return candidate
            }
        }
        if hasInvoiceContext, let candidate = valueAfterKeyword("for", in: text) {
            return candidate
        }
        return nil
    }

    /// Captures the value written after a field label like "buyer :",
    /// stopping at the next field or clause boundary.
    ///
    /// Clause words ("with product …", "… at ₹40/kg") terminate the value so a
    /// phrase like "for Radhika Mills with product as 10 KG of cotton…" yields
    /// just "Radhika Mills" rather than swallowing the rest of the sentence.
    ///
    /// The label is also allowed to be followed by a connector ("is", "are",
    /// "named", "known as") and a leading article ("the"/"a"/"an") before the
    /// real value starts — natural phrasing like "the buyer is ABC Traders"
    /// is at least as common as the stiffer "buyer: ABC Traders", and without
    /// consuming that connector here it used to leak straight into the
    /// captured value ("is ABC Traders"). "and"/"who"/"which"/a few trailing
    /// verbs are also treated as clause boundaries so a run-on sentence with
    /// no comma ("customer is X and they ordered...") doesn't get swallowed
    /// whole.
    private static func valueAfterKeyword(_ keyword: String, in text: String, stopAtComma: Bool = true) -> String? {
        let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: keyword)
            + "\\s*[:#\\-]?\\s*(?:\\b(?:is|are|was|were|named|called|known\\s+as)\\b)?\\s*(?:\\b(?:the|a|an)\\b)?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let matchRange = Range(match.range, in: text) else { return nil }
        let rest = String(text[matchRange.upperBound...])

        let clauseStops = #"gstin|gst|phone|ph|hsn|invoice|date|transporter|vehicle|rate|price|with|product|quantity|qty|unit|weight|and|who|which|wants|needs|requires|ordered|ordering|order"#
        var stopBits = #"(?:\n|;|\b(?:"# + clauseStops + #")\b|\b\d{2}[A-Z]{5})"#
        if stopAtComma { stopBits = #"(?:,|\n|;|\b(?:"# + clauseStops + #")\b|\b\d{2}[A-Z]{5})"# }

        var end = rest.endIndex
        if let stopRegex = try? NSRegularExpression(pattern: "(?i)" + stopBits),
           let stopMatch = stopRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let stopRange = Range(stopMatch.range, in: rest) {
            end = stopRange.lowerBound
        }
        var candidate = String(rest[rest.startIndex..<end])
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))

        guard candidate.count >= 2 else { return nil }
        // A name should be mostly words rather than a bare number or quantity
        // clause. Address lines are allowed to start with a street number, so
        // we only enforce the letter→digit balance here rather than rejecting
        // a leading digit outright.
        let letters = candidate.filter(\.isLetter).count
        guard letters >= 2, letters > candidate.filter(\.isNumber).count else { return nil }
        return candidate
    }
    
    
    private static func extractBuyerAddress(from text: String, buyerName: String?) -> [String]? {
        // 1) Explicitly labelled: "address : X" or "buyer address : X"
        //    (addresses run across commas, so don't stop at the first one).
        for label in ["buyer address", "address"] {
            if let value = valueAfterKeyword(label, in: text, stopAtComma: false) {
                let lines = splitAddress(value)
                if !lines.isEmpty { return lines }
            }
        }

        // 2) "for <name>, <address chunk>, … GSTIN …" — the comma-separated run
        //    between the buyer name and their GSTIN is usually the address.
        guard let buyerName, !buyerName.isEmpty else { return nil }
        guard let nameRange = text.range(of: buyerName, options: [.caseInsensitive]) else { return nil }
        let tail = String(text[nameRange.upperBound...])
        guard let gstRange = tail.range(of: gstinPattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let chunk = String(tail[tail.startIndex..<gstRange.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;\n "))
        let lines = splitAddress(chunk)
        return lines.isEmpty ? nil : lines
    }

    private static func splitAddress(_ value: String) -> [String] {
        let pieces = value
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count >= 2 }
        guard !pieces.isEmpty else { return [] }
        return Array(pieces.prefix(4)).padding(toLength: 4, withPad: "")
    }

    private static func extractShipping(from text: String) -> Party? {
        var party = Party()
        if let name = valueAfterKeyword("ship to", in: text) {
            party.name = name
        }
        if let value = valueAfterKeyword("shipping address", in: text, stopAtComma: false) {
            party.address = splitAddress(value)
        }
        if !party.name.isEmpty && party.gstin.isEmpty,
           let gstin = valueAfterKeyword("shipping gstin", in: text) {
            party.gstin = gstin.uppercased()
        }
        if party.name.isEmpty && party.address.allSatisfy(\.isEmpty) { return nil }
        return party
    }

    // MARK: - Transporter

    private static func extractAfterKeyword(_ keyword: String, in text: String) -> String? {
        valueAfterKeyword(keyword, in: text)
    }

    // MARK: - Dates

    private static func dateFollowingDateKeyword(in text: String) -> String? {
        let pattern = #"(?i)\b(?:date|dated|dt)\s*[:#\-]?\s*(\d{1,2}[-/]\d{1,2}[-/]\d{2,4}|\d{1,2}(?:st|nd|rd|th)?\s+(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\s+\d{4})"#
        return firstCapturedGroup(of: pattern, in: text)
    }

    private static func collectDates(from text: String) -> [String] {
        matches(of: dateNumericPattern, in: text) + matches(of: dateWrittenPattern, in: text)
    }

    private static func rangeOf(_ date: String, in text: String) -> Range<String.Index>? {
        text.range(of: date)
    }

    private static func containsWord(_ word: String, in lowerText: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b") else {
            return false
        }
        let range = NSRange(lowerText.startIndex..., in: lowerText)
        return regex.firstMatch(in: lowerText, range: range) != nil
    }

    /// Today's date as dd-MM-yyyy — the app's display format for invoice dates.
    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// "original invoice 17" / "against invoice 17" — returns the number plus
    /// the text that follows it (where the original's date usually sits).
    private static func originalInvoiceReference(in text: String) -> (number: String, tail: String, range: Range<String.Index>)? {
        let pattern = #"(?i)\b(?:original|against)\s+invoice\s*(?:no\.?|number)?\s*[:#\-]?\s*((?=[A-Z0-9/\-]*\d)[A-Z0-9][A-Z0-9/\-]{0,20})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let fullRange = Range(match.range, in: text),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else { return nil }
        return (String(text[groupRange]), String(text[fullRange.upperBound...]), fullRange)
    }

    // MARK: - Regex helpers

    private static func matches(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive)) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        matches(of: pattern, in: text, options: options).first
    }

    private static func firstCapturedGroup(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        allCapturedGroups(of: pattern, group: 1, in: text, options: options).first
    }

    private static func allCapturedGroups(of pattern: String, group: Int, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive)) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group, let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    private struct DoubleGroupMatch {
        let group1: String?
        let group2: String?
        let group3: String?
        let group4: String?
    }

    private static func firstFullMatch(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> DoubleGroupMatch? {
        allFullMatches(of: pattern, in: text, options: options).first
    }

    private static func allFullMatches(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [DoubleGroupMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive)) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            func group(_ idx: Int) -> String? {
                guard idx < match.numberOfRanges, let r = Range(match.range(at: idx), in: text) else { return nil }
                return String(text[r])
            }
            return DoubleGroupMatch(group1: group(1), group2: group(2), group3: group(3), group4: group(4))
        }
    }
}

private extension Array where Element == String {
    /// Pads a split-address array back to the model's four lines.
    func padding(toLength n: Int, withPad: String) -> [String] {
        count >= n ? Array(prefix(n)) : self + Array(repeating: withPad, count: n - count)
    }
}
