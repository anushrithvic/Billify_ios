//
//  FormFillEngine.swift
//  Billify
//
//  Fills a single Products & Buyers form from a block of text. This is what
//  the "Fill from text" paste box and the photo/camera path both funnel into:
//  a photo is OCR'd first (OCRService, on-device Vision) and its recognized
//  text arrives here exactly like a paste.
//
//  Deliberately a thin adapter over BulkTextExtractor — the same extraction
//  engine chat relies on, just aimed at one buyer or one product instead of a
//  whole invoice. Because the letterhead extraction fix is on hold, results
//  are as reliable as chat pastes currently are: labelled or loosely-labelled
//  text works well, a completely bare label-free block may come back
//  partially empty.
//
//  The blank-field-only rule ("never overwrite something already typed")
//  lives in the forms, not here: this engine only reports what it FOUND; the
//  forms decide what to do with it. Same for the save action — a flagged
//  duplicate is a note for the user, never a silent merge.
//

import Foundation

enum FormFillEngine {

    struct Result {
        // Product form targets.
        var productName: String?
        var productHsn: String?

        // Buyer form targets.
        var buyerName: String?
        var buyerGstin: String?
        /// Up to 4 lines; empty strings where nothing was found for that line.
        var buyerAddress: [String] = ["", "", "", ""]

        /// Set when the extracted GSTIN belongs to a buyer already saved (and
        /// isn't the one being edited) — the form shows an "Already saved as …"
        /// note instead of letting a near-duplicate slip in.
        var duplicateBuyerName: String?
    }

    /// Parses `text` into whatever form fields it can fill.
    ///
    /// - Parameters:
    ///   - memory: The catalog, used only to flag a GSTIN that's already saved.
    ///   - editingName: The name of the record currently being edited, if any —
    ///     a GSTIN matching *that* record is not a duplicate.
    static func fill(from text: String,
                     memory: MemoryStore,
                     ignoringBuyerNamed editingName: String? = nil) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result() }

        let extraction = BulkTextExtractor.extract(from: trimmed)
        var result = Result()

        // Product: the first row that carries a name and/or a code.
        if let product = extraction.data.products.first(where: { !$0.name.isEmpty || !$0.hsn.isEmpty }) {
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, looksLikeAProductName(name) {
                result.productName = name
            }
            let hsn = product.hsn.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hsn.isEmpty {
                result.productHsn = hsn
            }
        }

        // Buyer: name, GSTIN and whatever address lines were found.
        let buyer = extraction.data.buyer
        let buyerName = buyer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !buyerName.isEmpty {
            result.buyerName = buyerName
        }
        let gstin = buyer.gstin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gstin.isEmpty {
            result.buyerGstin = gstin
            if let known = memory.buyer(withGstin: gstin), known.name != editingName {
                result.duplicateBuyerName = known.name
            }
        }
        result.buyerAddress = buyer.address

        return result
    }

    /// Guards against cross-form misuse: pasting buyer/letterhead text into
    /// the *product* form shouldn't fill the name field with the extractor's
    /// leftover-words fallback ("Buyer … address …"). Chat is unaffected —
    /// this gate only applies to what the forms auto-fill.
    private static func looksLikeAProductName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let fieldWords = ["buyer", "address", "gstin", "invoice", "transporter"]
        return !fieldWords.contains { lower.contains($0) }
    }
}
