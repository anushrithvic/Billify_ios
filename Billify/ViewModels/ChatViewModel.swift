//
//  ChatViewModel.swift
//  Billify
//
//  Owns the chat transcript and the current invoice draft (spec §34).
//
//  SCOPE NOTE:
//  Bulk pasted text is now routed through the real BulkTextExtractor (spec
//  §29 Method 3, §36). Correction-style messages ("change the quantity to
//  25 bags", "the GST is 18% not 5%") are routed through CorrectionParser
//  (spec §48) and applied to the matching field, with a confirmation posted
//  back. Everything else still goes through the simple `apply(answer:)`
//  slot-filler below — that part remains a placeholder for full
//  conversational NLP (a later phase), since most short answers ("ABC
//  Traders", "18%") don't need heavy parsing anyway. Image/OCR input
//  (spec §29 Method 1) is implemented: a photo is OCR'd on-device by
//  OCRService (Vision) and the recognized text runs through the same
//  BulkTextExtractor pipeline as a paste — with low-confidence lines and
//  uncertain fields surfaced to the user instead of silently trusted (§33),
//  and the seller's own printed GSTIN re-mapped so it isn't taken as the
//  buyer's.
//
//  MEMORY: the view model learns products (name→HSN) and buyers
//  (name→GSTIN/address) into a MemoryStore as invoices are built, and
//  consults it while filling fields — so a repeat product or buyer doesn't
//  re-trigger questions it already answered once.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var draft: InvoiceData = InvoiceData()
    @Published var inputText: String = ""
    @Published var isShowingPreview: Bool = false

    /// Long-term catalog of known products and buyers (persisted locally).
    private let memory: MemoryStore

    /// The field we're currently waiting on an answer for, if any.
    private var pendingField: PendingField? = nil

    /// Tracks whether we've explicitly asked/confirmed the document type yet.
    /// Without this, the conversational flow had no question that ever let a
    /// user pick Credit Note or Delivery Challan — it silently defaulted to
    /// Tax Invoice forever. This flag makes sure that question gets asked.
    private var invoiceTypeConfirmed = false

    enum PendingField {
        case invoiceType
        case buyerName
        case buyerGstin
        case buyerAddress
        case productName
        case productHsn
        case productQuantity
        case productUnit
        case productWeight
        case productRate
        case taxType
        case invoiceNo
        case invoiceDate
        case originalInvoiceNo
        case originalInvoiceDate
    }

    init(memory: MemoryStore? = nil, initialType: InvoiceType? = nil) {
        self.memory = memory ?? MemoryStore.shared
        if let initialType {
            // Seeded from the home screen: the document type is already decided,
            // so skip the type question and start collecting product details.
            draft.invoiceType = initialType
            invoiceTypeConfirmed = true
            greet(initialType: initialType)
            ask(.productName, "What product is it for?")
        } else {
            greet(initialType: nil)
        }
    }

    private func greet(initialType: InvoiceType?) {
        if let initialType {
            post(.billify, """
            I'll help you draft a **\(initialType.rawValue)**.

            Tell me about it however you like — type the details, or paste a whole
            block of text and I'll pull out the fields. I remember the products
            and buyers you use often, so repeat ones fill in automatically.
            """)
            return
        }
        post(.billify, """
        Hi! I'm Billify. I can create an invoice from a chat, pasted text, or a photo.

        I also remember the products and buyers you use often — next time you
        mention one, its HSN code or address fills in automatically.

        Want to get started? Tell me who the invoice is for, or just say "create an invoice".
        """)
    }

    // MARK: - Sending

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        post(.user, text)
        inputText = ""
        handle(userText: text)
    }

    private func post(_ sender: ChatSender, _ text: String, attachment: ChatAttachment = .none) {
        messages.append(ChatMessage(sender: sender, text: text, attachment: attachment))
    }

    private func looksLikeBulkText(_ text: String) -> Bool {
        let wordCount = text.split(separator: " ").count
        let digitGroups = text.filter(\.isNumber).count
        return wordCount >= 12 || digitGroups >= 6
    }

    /// A message is only allowed to override an *active* pending question
    /// (steal its answer slot) when it's unambiguously a paste of many words.
    /// This checks word count only, not digit density — a short digit-heavy
    /// reply like "520100" (a 6-digit HSN code) or "33ABCDE1234F1Z5" (a bare
    /// GSTIN) used to satisfy `looksLikeBulkText` on digit count alone, get
    /// routed to BulkTextExtractor instead of applied as the answer, find
    /// nothing to extract (no "HSN"/label keyword present), and silently
    /// vanish — leaving the question stuck asking the same thing again.
    /// Requiring word count here means a short numeric answer always goes to
    /// the field it was asked for, while a genuine bulk paste (12+ words)
    /// still overrides an outstanding question when that's clearly what it is.
    private func isDefinitelyBulkPaste(_ text: String) -> Bool {
        text.split(separator: " ").count >= 12
    }

    private func handle(userText: String) {
        let corrections = CorrectionParser.parse(from: userText)
        if !corrections.isEmpty {
            for correction in corrections {
                post(.billify, applyCorrection(correction))
            }
        } else if let field = pendingField, !isDefinitelyBulkPaste(userText) {
            if let note = apply(answer: userText, to: field) {
                post(.billify, note)
            }
            pendingField = nil
        } else if looksLikeBulkText(userText) {
            applyBulkExtraction(to: userText)
            pendingField = nil
        } else if draft.products.isEmpty && draft.buyer.name.isEmpty {
            // Very first short message with nothing extracted yet. If it
            // directly names a document type ("create a credit note"),
            // honor that instead of treating the whole sentence as a name.
            if let match = detectExplicitInvoiceType(in: userText) {
                draft.invoiceType = match
                invoiceTypeConfirmed = true
                post(.billify, "Got it — a **\(match.rawValue)**. Who's it for?")
            } else {
                draft.buyer.name = userText
                post(.billify, "Got it — invoice for **\(userText)**.")
                if let note = prefillBuyerFromMemory(named: userText) {
                    post(.billify, note)
                }
            }
        }

        // Sweep the draft for anything worth remembering (product→HSN pairs,
        // buyer records). Idempotent, so calling it after every turn is cheap.
        memory.learn(from: draft)
        askNext()
    }
    
    private func detectExplicitInvoiceType(in text: String) -> InvoiceType? {
        let lower = text.lowercased()
        if lower.contains("credit note") { return .creditNote }
        if lower.contains("debit note") { return .debitNote }
        if lower.contains("delivery challan") || lower.contains("delivery note") { return .deliveryChallan }
        if lower.contains("tax invoice") { return .taxInvoice }
        return nil
    }

    private func applyBulkExtraction(to text: String) {
        finishExtraction(BulkTextExtractor.extract(from: text), sourceText: text)
    }

    /// Merges an extraction into the draft, pre-fills from memory and posts
    /// the field summary + uncertainty warnings. Pasted text and photo OCR
    /// both end up here so the two inputs behave identically downstream.
    private func finishExtraction(_ result: ExtractionResult,
                                  sourceText: String,
                                  sourceIsPhoto: Bool = false,
                                  ocrLowConfidenceLines: [String] = []) {
        draft = merge(current: draft, extracted: result.data)
        // Pre-fill anything the catalog already knows (e.g. HSN for a product
        // the paste named but didn't give a code for).
        for i in draft.products.indices where draft.products[i].name.isEmpty == false {
            if draft.products[i].hsn.isEmpty, let hsn = memory.hsn(forProductNamed: draft.products[i].name) {
                draft.products[i].hsn = hsn
            }
        }
        if !draft.buyer.name.isEmpty {
            prefillBuyerFromMemory(named: draft.buyer.name)
        }
        // A paste that only carries a GSTIN (no name typed) still resolves
        // the buyer's full saved record, if one's known.
        prefillBuyerFromMemoryByGstin()

        if detectExplicitInvoiceType(in: sourceText) != nil || !invoiceTypeConfirmed {
            invoiceTypeConfirmed = true
        }

        // A photo that genuinely contained no invoice details deserves a
        // clearer response than an empty summary.
        if sourceIsPhoto && extractionWasEmpty(result.data) {
            post(.billify, "I read your photo but didn't find any invoice details in it — you can type the details instead, or try a clearer photo.")
            return
        }

        var summaryLines = [sourceIsPhoto ? "I read your photo — here's what I found:" : "Got it — here's what I found:"]
        if !draft.buyer.name.isEmpty { summaryLines.append("• Buyer: \(draft.buyer.name)") }
        if !draft.buyer.gstin.isEmpty { summaryLines.append("• GSTIN: \(draft.buyer.gstin)") }
        for p in draft.products where !p.summary.isEmpty {
            summaryLines.append("• Product: \(p.summary)")
        }
        if !draft.invoiceDetails.invoiceNo.isEmpty { summaryLines.append("• Invoice No: \(draft.invoiceDetails.invoiceNo)") }
        if !draft.invoiceDetails.date.isEmpty { summaryLines.append("• Date: \(draft.invoiceDetails.date)") }
        if !draft.transport.vehicleNo.isEmpty { summaryLines.append("• Vehicle: \(draft.transport.vehicleNo)") }

        if !result.uncertainFields.isEmpty {
            summaryLines.append("⚠️ I'm not fully confident about: \(result.uncertainFields.joined(separator: ", ")). Please double check or correct these.")
        }
        if sourceIsPhoto, !ocrLowConfidenceLines.isEmpty {
            let sample = Array(ocrLowConfidenceLines.prefix(5)).joined(separator: " · ")
            summaryLines.append("⚠️ Some of the photo was hard to read, so please double-check: \(sample)")
        }

        post(.billify, summaryLines.joined(separator: "\n"))
    }

    /// Photo input (spec §29 Method 1): OCRs the image, folds the recognized
    /// text through the same extractor as a paste, and confirms what landed
    /// where. The recognition itself runs off the main actor inside
    /// OCRService, so the chat stays responsive while a photo is processed.
    func processPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            post(.billify, "Sorry — I couldn't read that image. Could you try another photo?")
            return
        }
        post(.user, "📷 Photo", attachment: .image(image))
        // A photo is a whole-document input, never the answer to the question
        // currently on screen.
        pendingField = nil
        post(.billify, "Reading the text in your photo…")
        let readingMessageID = messages.last?.id

        Task {
            let ocr = await OCRService.recognizeText(in: data)
            if let readingMessageID {
                messages.removeAll { $0.id == readingMessageID }
            }
            let text = ocr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                post(.billify, "I couldn't make out any text in that photo. Could you retake it closer, straighter, and in good light?")
                askNext()
                return
            }
            var result = BulkTextExtractor.extract(from: text)
            remapSellerGstin(in: &result.data)
            finishExtraction(result, sourceText: text, sourceIsPhoto: true, ocrLowConfidenceLines: ocr.lowConfidenceLines)
            memory.learn(from: draft)
            askNext()
        }
    }

    /// The photo picker or camera handed us nothing usable.
    func photoFailedToLoad() {
        post(.billify, "Sorry — I couldn't load that photo. Please try again.")
    }

    /// Photos of existing invoices usually print the *seller's* GSTIN in the
    /// header — and it comes first in the text, which would make the
    /// extractor's "first GSTIN is the buyer" rule (right for a typed
    /// sentence) assign our own GSTIN as the buyer's. When the photo's first
    /// GSTIN is this company's, re-map it: the second GSTIN, if any, is the
    /// real buyer's — otherwise the buyer GSTIN is simply unknown.
    private func remapSellerGstin(in data: inout InvoiceData) {
        let ownGstin = CompanyInfo.default.gstin
        guard !ownGstin.isEmpty, data.buyer.gstin == ownGstin else { return }
        if !data.transport.gstin.isEmpty, data.transport.gstin != ownGstin {
            data.buyer.gstin = data.transport.gstin
            data.transport.gstin = ""
        } else {
            data.buyer.gstin = ""
        }
    }

    /// Whether an extraction found nothing usable at all (used to give photo
    /// input a clearer "no invoice details" response).
    private func extractionWasEmpty(_ data: InvoiceData) -> Bool {
        data.buyer.name.isEmpty && data.buyer.gstin.isEmpty
            && data.buyer.address.allSatisfy(\.isEmpty)
            && data.products.isEmpty
            && data.invoiceDetails.invoiceNo.isEmpty
            && data.invoiceDetails.date.isEmpty
            && data.transport.isEmpty
    }

    private func merge(current: InvoiceData, extracted: InvoiceData) -> InvoiceData {
        var result = current

        if result.buyer.name.isEmpty { result.buyer.name = extracted.buyer.name }
        if result.buyer.gstin.isEmpty { result.buyer.gstin = extracted.buyer.gstin }
        for i in 0..<4 where i < extracted.buyer.address.count {
            if result.buyer.address[i].isEmpty && !extracted.buyer.address[i].isEmpty {
                result.buyer.address[i] = extracted.buyer.address[i]
            }
        }
        if result.shippingSameAsBuyer == false && result.shipping.name.isEmpty && result.shipping.address.allSatisfy(\.isEmpty) {
            result.shipping = extracted.shipping
        }
        if result.transport.vehicleNo.isEmpty { result.transport.vehicleNo = extracted.transport.vehicleNo }
        if result.transport.transporter.isEmpty { result.transport.transporter = extracted.transport.transporter }
        if result.transport.gstin.isEmpty { result.transport.gstin = extracted.transport.gstin }
        if result.invoiceDetails.invoiceNo.isEmpty { result.invoiceDetails.invoiceNo = extracted.invoiceDetails.invoiceNo }
        if result.invoiceDetails.date.isEmpty { result.invoiceDetails.date = extracted.invoiceDetails.date }

        if result.products.isEmpty {
            result.products = extracted.products
        } else if !extracted.products.isEmpty {
            if result.products[0].name.isEmpty { result.products[0].name = extracted.products[0].name }
            if result.products[0].hsn.isEmpty { result.products[0].hsn = extracted.products[0].hsn }
            if result.products[0].quantity == nil { result.products[0].quantity = extracted.products[0].quantity }
            if result.products[0].weightKg == nil { result.products[0].weightKg = extracted.products[0].weightKg }
            if result.products[0].ratePerKg == nil { result.products[0].ratePerKg = extracted.products[0].ratePerKg }
        }

        if extracted.invoiceType != .taxInvoice || !invoiceTypeConfirmed {
            result.invoiceType = extracted.invoiceType
        }
        result.tax.type = extracted.tax.type

        return result
    }

    /// Applies a short chat answer to the field being asked about. Returns an
    /// optional note for the user (e.g. when memory auto-fills a known value).
    private func apply(answer: String, to field: PendingField) -> String? {
        switch field {
        case .invoiceType:
            if let match = InvoiceType.allCases.first(where: {
                answer.localizedCaseInsensitiveContains($0.rawValue.split(separator: " ").first ?? "")
            }) {
                draft.invoiceType = match
            }
            invoiceTypeConfirmed = true
        case .buyerName:
            draft.buyer.name = answer
            return prefillBuyerFromMemory(named: answer)
        case .buyerGstin:
            draft.buyer.gstin = answer
            return prefillBuyerFromMemoryByGstin()
        case .buyerAddress:
            draft.buyer.address[0] = answer
        case .productName:
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].name = answer
            // Known product → auto-fill its HSN so the flow never asks again.
            if draft.products[draft.products.count - 1].hsn.isEmpty,
               let hsn = memory.hsn(forProductNamed: answer) {
                draft.products[draft.products.count - 1].hsn = hsn
                return "I remember **\(answer)** — set HSN **\(hsn)** automatically."
            }
        case .productHsn:
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].hsn = answer
        case .productQuantity:
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].quantity = Int(answer.filter(\.isNumber))
        case .productUnit:
            if let unit = ProductUnit.allCases.first(where: {
                answer.localizedCaseInsensitiveContains($0.rawValue)
            }) {
                ensureLastProductIndex()
                draft.products[draft.products.count - 1].unit = unit
            }
        case .productWeight:
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].weightKg = Double(answer.filter { $0.isNumber || $0 == "." })
        case .productRate:
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].ratePerKg = Double(answer.filter { $0.isNumber || $0 == "." })
        case .taxType:
            if answer.localizedCaseInsensitiveContains("nat") {
                draft.tax.type = .national
                draft.tax.rate = 5.0
            } else {
                draft.tax.type = .state
                draft.tax.rate = 5.0
            }
        case .invoiceNo:
            draft.invoiceDetails.invoiceNo = answer
        case .invoiceDate:
            draft.invoiceDetails.date = answer
        case .originalInvoiceNo:
            draft.invoiceDetails.originalInvoiceNo = answer
        case .originalInvoiceDate:
            draft.invoiceDetails.originalInvoiceDate = answer
        }
        return nil
    }

    /// Fills the draft buyer's blank GSTIN/address lines from memory. Returns
    /// a confirmation note if anything was filled.
    @discardableResult
    private func prefillBuyerFromMemory(named name: String) -> String? {
        guard let known = memory.buyer(named: name) else { return nil }
        var filledSomething = false
        if !known.gstin.isEmpty && draft.buyer.gstin.isEmpty {
            draft.buyer.gstin = known.gstin
            filledSomething = true
        }
        for i in 0..<4 where i < known.address.count {
            if draft.buyer.address[i].isEmpty && !known.address[i].isEmpty {
                draft.buyer.address[i] = known.address[i]
                filledSomething = true
            }
        }
        if filledSomething {
            return "I remember **\(name)** — filled in their saved GSTIN and address."
        }
        return nil
    }

    /// Fills the draft buyer's blank name/address from a saved record found
    /// by GSTIN — a GSTIN is unique per registered business, so typing (or
    /// pasting) one that's already known can fill in everything else, the
    /// same way a known name does. This is what lets someone just type a
    /// GSTIN and have the buyer's name and address come up automatically.
    /// Returns a confirmation note if anything was filled.
    @discardableResult
    private func prefillBuyerFromMemoryByGstin() -> String? {
        guard !draft.buyer.gstin.isEmpty,
              let known = memory.buyer(withGstin: draft.buyer.gstin) else { return nil }
        var filledSomething = false
        if draft.buyer.name.isEmpty && !known.name.isEmpty {
            draft.buyer.name = known.name
            filledSomething = true
        }
        for i in 0..<4 where i < known.address.count {
            if draft.buyer.address[i].isEmpty && !known.address[i].isEmpty {
                draft.buyer.address[i] = known.address[i]
                filledSomething = true
            }
        }
        if filledSomething {
            return "I recognize this GSTIN — filled in the saved name and address for **\(known.name)**."
        }
        return nil
    }

    private func ensureLastProductIndex() {
        if draft.products.isEmpty {
            draft.products.append(Product())
        }
    }

    // MARK: - Conversational corrections (spec §48)

    /// Applies a parsed correction to the draft and returns a confirmation
    /// message to post back to the user.
    private func applyCorrection(_ correction: CorrectionParser.Correction) -> String {
        switch correction {
        case .invoiceType(let type):
            draft.invoiceType = type
            invoiceTypeConfirmed = true
            return "Updated document type to **\(type.rawValue)**."
        case .taxType(let type):
            draft.tax.type = type
            let label = type == .national ? "IGST (National)" : "CGST + SGST (State)"
            return "Updated tax type to **\(label)**."
        case .taxRate(let rate):
            draft.tax.rate = rate
            return "Updated GST rate to **\(rate.formattedTrim)%**."
        case .buyerName(let value):
            draft.buyer.name = value
            // A different buyer name is a different party: if memory has full
            // details for it, adopt them wholesale (overwriting fields that
            // belonged to whoever was named before).
            if let known = memory.buyer(named: value) {
                if !known.gstin.isEmpty { draft.buyer.gstin = known.gstin }
                for i in 0..<4 where i < known.address.count {
                    draft.buyer.address[i] = known.address[i]
                }
                return "Updated buyer name to **\(value)** — restored their saved GSTIN and address."
            }
            return "Updated buyer name to **\(value)**."
        case .buyerGstin(let value):
            draft.buyer.gstin = value
            if let note = prefillBuyerFromMemoryByGstin() {
                return "Updated buyer GSTIN to **\(value)**. \(note)"
            }
            return "Updated buyer GSTIN to **\(value)**."
        case .buyerAddress(let value):
            draft.buyer.address[0] = value
            return "Updated buyer address to **\(value)**."
        case .invoiceNo(let value):
            draft.invoiceDetails.invoiceNo = value
            return "Updated invoice number to **\(value)**."
        case .invoiceDate(let value):
            draft.invoiceDetails.date = value
            return "Updated invoice date to **\(value)**."
        case .ewayBill(let value):
            draft.invoiceDetails.ewayBill = value
            return "Updated e-way bill number to **\(value)**."
        case .originalInvoiceNo(let value):
            draft.invoiceDetails.originalInvoiceNo = value
            return "Updated original invoice number to **\(value)**."
        case .originalInvoiceDate(let value):
            draft.invoiceDetails.originalInvoiceDate = value
            return "Updated original invoice date to **\(value)**."
        case .productName(let value):
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].name = value
            return "Updated product name to **\(value)**."
        case .productHsn(let value):
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].hsn = value
            return "Updated HSN code to **\(value)**."
        case .productQuantity(let value):
            ensureLastProductIndex()
            let name = draft.products[draft.products.count - 1].name
            draft.products[draft.products.count - 1].quantity = value
            return "Updated quantity of **\(name.isEmpty ? "product" : name)** to **\(value)**."
        case .productUnit(let unit):
            ensureLastProductIndex()
            draft.products[draft.products.count - 1].unit = unit
            return "Updated unit to **\(unit.rawValue)**."
        case .productWeight(let value):
            ensureLastProductIndex()
            let name = draft.products[draft.products.count - 1].name
            draft.products[draft.products.count - 1].weightKg = value
            return "Updated weight of **\(name.isEmpty ? "product" : name)** to **\(value.formattedTrim) KG**."
        case .productRate(let value):
            ensureLastProductIndex()
            let name = draft.products[draft.products.count - 1].name
            draft.products[draft.products.count - 1].ratePerKg = value
            return "Updated rate of **\(name.isEmpty ? "product" : name)** to **₹\(value.formattedTrim)/KG**."
        case .vehicleNo(let value):
            draft.transport.vehicleNo = value
            return "Updated vehicle number to **\(value)**."
        case .transporter(let value):
            draft.transport.transporter = value
            return "Updated transporter to **\(value)**."
        case .transporterGstin(let value):
            draft.transport.gstin = value
            return "Updated transporter GSTIN to **\(value)**."
        }
    }

    // MARK: - Asking

    private func askNext() {
        if !invoiceTypeConfirmed {
            ask(.invoiceType, "What type of document do you need — Tax Invoice, Credit Note, Debit Note, or Delivery Challan? (Say \"Tax Invoice\" if unsure.)")
            return
        }

        if draft.products.isEmpty || !draft.products[draft.products.count - 1].isComplete {
            if draft.products.isEmpty { draft.products.append(Product()) }
            let p = draft.products[draft.products.count - 1]
            if p.name.isEmpty { ask(.productName, "What product should I add?"); return }
            if p.hsn.isEmpty { ask(.productHsn, "What's the HSN code for \(p.name)?"); return }
            if p.quantity == nil { ask(.productQuantity, "How many \(p.unit.rawValue.lowercased())?"); return }
            if p.weightKg == nil { ask(.productWeight, "What's the total weight in KG?"); return }
            if p.ratePerKg == nil { ask(.productRate, "What's the rate per KG?"); return }
        }

        if draft.buyer.name.isEmpty { ask(.buyerName, "What's the buyer's name?"); return }
        if draft.buyer.gstin.isEmpty && draft.invoiceType != .deliveryChallan {
            ask(.buyerGstin, "What's the buyer's GSTIN?"); return
        }
        if draft.buyer.address[0].isEmpty { ask(.buyerAddress, "What's the buyer's address?"); return }

        if draft.invoiceDetails.invoiceNo.isEmpty { ask(.invoiceNo, "What invoice number should I use?"); return }
        // The date is never asked for — it defaults to today automatically,
        // and stays editable on the review screen right before generating.
        if draft.invoiceDetails.date.isEmpty {
            draft.invoiceDetails.date = BulkTextExtractor.todayString()
        }

        if draft.invoiceType.referencesOriginalInvoice {
            if draft.invoiceDetails.originalInvoiceNo.isEmpty {
                let docLabel = draft.invoiceType == .debitNote ? "debit note" : "credit note"
                ask(.originalInvoiceNo, "What's the original invoice number this \(docLabel) refers to?"); return
            }
            if draft.invoiceDetails.originalInvoiceDate.isEmpty {
                ask(.originalInvoiceDate, "What was the date of that original invoice?"); return
            }
        }

        // The inline preview card re-renders live off the draft, so once it's
        // been shown there's no need to re-post it after each correction.
        if draft.isReadyForPreview && !isShowingPreview {
            post(.billify, "I've got everything I need. Here's your invoice:", attachment: .invoicePreview)
            isShowingPreview = true
        }
    }

    private func ask(_ field: PendingField, _ question: String) {
        pendingField = field
        post(.billify, question)
    }

    // MARK: - Live name suggestions (autocomplete)

    /// Read-only peek for the view layer (suggestion chips show a buyer or
    /// product icon depending on which kind of name is being asked for).
    var isAwaitingBuyerName: Bool { pendingField == .buyerName }

    /// Names to offer as tappable chips above the composer — shown only while
    /// Billify is literally waiting on a buyer or product name (never during a
    /// bulk paste, a correction, or any other question), and only once at
    /// least one character is typed. Filter/sort/cap rules live in
    /// NameSuggester, which the Products & Buyers forms share.
    var nameSuggestions: [String] {
        switch pendingField {
        case .buyerName:
            return NameSuggester.suggestions(for: inputText, in: memory.buyers.map(\.name))
        case .productName:
            return NameSuggester.suggestions(for: inputText, in: memory.products.map(\.name))
        default:
            return []
        }
    }

    /// A suggestion chip was tapped: fill the pending field with the full
    /// saved name and carry on exactly as if it had been typed out and sent
    /// by hand.
    func applySuggestion(_ name: String) {
        guard pendingField == .buyerName || pendingField == .productName else { return }
        inputText = name
        send()
    }
}
