//
//  InvoiceQAEngine.swift
//  Billify
//
//  The "Ask Billify" assistant: answers plain-language questions about the
//  invoices saved in history — totals, counts, customers, a specific document —
//  plus the everyday doubts a first-time user has (what is an HSN code, when
//  do I need an e-way bill, credit note vs debit note…).
//
//  Deliberately rule-based: invoice data is small and structured, the question
//  space is finite, and there is no network/LLM dependency. The parser is a
//  pure function over (question, entries, today) so it is fully testable.
//

import Foundation

enum InvoiceQAEngine {

    // MARK: - Entry point

    static func answer(_ rawQuestion: String, entries: [HistoryEntry], today: Date = Date()) -> String {
        let q = normalize(rawQuestion)
        guard !q.isEmpty else { return helpText }

        // 1) What can you do / how do I / doubts about the app itself.
        if isHelpQuestion(q) { return helpText }
        if let concept = conceptAnswer(for: q) { return concept }

        // 2) Data questions need something to look at.
        if entries.isEmpty {
            if looksDataish(q) {
                return "You don't have any saved invoices yet. Generate your first one from the home screen — **Create Tax Invoice** — and it will be saved here automatically."
            }
            return helpText
        }

        // 3) Buyer-scoped questions ("how much did I bill Sri Kumaran Mills?").
        let buyerScope = bestBuyerMatch(in: q, entries: entries)

        // 4) Specific document lookup.
        if let doc = documentNumber(in: q) {
            let matches = entries.filter {
                $0.invoiceNo == doc.number && (buyerScope == nil || fuzzy($0.buyerName, buyerScope!))
            }
            if matches.isEmpty {
                let who = buyerScope.map { " for \($0)" } ?? ""
                return "I couldn't find an invoice numbered **\(doc.number)**\(who)."
            }
            return listing(matches, header: "Found:")
        }

        // 5) Next-number helper.
        if nextNumberRequested(q) {
            return nextInvoiceNumberAdvice(entries: entries)
        }

        // 6) Customer list.
        if q.contains("customer") || q.contains("client") || q.contains("who do i bill")
            || q.contains("who i bill") || q.contains("buyers") {
            return customerSummary(entries: entries)
        }

        // 7) Time-scoped summary ("in august", "this month", "2026").
        let scope = timeScope(from: q, today: today)

        // 8) Money questions.
        if isMoneyQuestion(q) {
            let pool = filtered(entries, buyer: buyerScope, scope: scope)
            let total = pool.reduce(0) { $0 + $1.total }
            let label = description(of: scope, buyer: buyerScope)
            if pool.isEmpty {
                let emptyLabel = label.isEmpty ? "yet" : label
                return "No invoices \(emptyLabel) to add up."
            }
            let plural = pool.count == 1 ? "" : "s"
            if label.isEmpty {
                return "Total billed across \(pool.count) document\(plural) is **₹\(inr(total))**."
            }
            return "Total \(label) is **₹\(inr(total))** across \(pool.count) document\(plural)."
        }

        // 9) Counting questions.
        if countRequested(q) {
            let pool = filtered(entries, buyer: buyerScope, scope: scope)
            let label = description(of: scope, buyer: buyerScope)
            if pool.isEmpty {
                let emptyLabel = label.isEmpty ? "" : " \(label)"
                return "No invoices found\(emptyLabel)."
            }
            let byType = pool.reduce(into: [String: Int]()) { counts, entry in
                counts[entry.invoiceType.rawValue, default: 0] += 1
            }
            if let type = documentType(in: q) {
                let n = byType[type.rawValue] ?? 0
                let plural = n == 1 ? "" : "s"
                return "You've issued **\(n) \(type.rawValue.lowercased())\(plural)**\(label.isEmpty ? "" : " \(label)")."
            }
            let detail = byType.keys.sorted().map { key in
                let n = byType[key] ?? 0
                return "\(n) \(key.lowercased())\(n == 1 ? "" : "s")"
            }.joined(separator: ", ")
            let plural = pool.count == 1 ? "" : "s"
            return "You've issued **\(pool.count)** document\(plural)\(label.isEmpty ? "" : " \(label)") — \(detail)."
        }

        // 10) Recent / listing requests.
        if q.contains("recent") || q.contains("latest") || q.contains("last invoice")
            || q.contains("newest") || q.contains("list") {
            return listing(Array(entries.prefix(6)), header: "Your most recent documents:")
        }

        return fallbackText
    }

    // MARK: - Scoping

    private struct TimeScope {
        var year: Int?
        var month: Int?
        var dayStart: Date?
        var dayEnd: Date?
        var label: String
    }

    /// Which saved documents count for the question: buyer filter ∧ time scope.
    private static func filtered(_ entries: [HistoryEntry], buyer: String?, scope: TimeScope?) -> [HistoryEntry] {
        entries.filter { entry in
            if let buyer, !fuzzy(entry.buyerName, buyer) { return false }
            guard let scope else { return true }
            let date = effectiveDate(of: entry)
            if let dayStart = scope.dayStart, let dayEnd = scope.dayEnd {
                return date >= dayStart && date < dayEnd
            }
            let comps = Calendar.current.dateComponents([.year, .month], from: date)
            if let year = scope.year, comps.year != year { return false }
            if let month = scope.month, comps.month != month { return false }
            return true
        }
    }

    private static func effectiveDate(of entry: HistoryEntry) -> Date {
        // Prefer the invoice's own date (what the user typed), falling back to
        // the moment it was generated.
        for fmt in ["dd-MM-yyyy", "dd/MM/yyyy", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: entry.dateLabel) { return d }
        }
        return entry.generatedAt
    }

    private static func timeScope(from q: String, today: Date) -> TimeScope? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: today)
        let thisYear = comps.year ?? 2026
        let thisMonth = comps.month ?? 1

        func monthScope(month: Int, year: Int) -> TimeScope {
            TimeScope(year: year, month: month, dayStart: nil, dayEnd: nil,
                      label: "\(DateFormatter().monthSymbols[month - 1]) \(year)")
        }

        if q.contains("this month") { return monthScope(month: thisMonth, year: thisYear) }
        if q.contains("last month") || q.contains("previous month") {
            let d = cal.date(byAdding: .month, value: -1, to: today) ?? today
            let c = cal.dateComponents([.year, .month], from: d)
            return monthScope(month: c.month ?? 1, year: c.year ?? thisYear)
        }
        if q.contains("this year") { return TimeScope(year: thisYear, month: nil, dayStart: nil, dayEnd: nil, label: "\(thisYear)") }
        if q.contains("last year") {
            let d = cal.date(byAdding: .year, value: -1, to: today) ?? today
            let y = cal.component(.year, from: d)
            return TimeScope(year: y, month: nil, dayStart: nil, dayEnd: nil, label: "\(y)")
        }
        if q.contains("today") {
            let start = cal.startOfDay(for: today)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? today
            return TimeScope(year: nil, month: nil, dayStart: start, dayEnd: end, label: "today")
        }
        if q.contains("yesterday") {
            let day = cal.date(byAdding: .day, value: -1, to: today) ?? today
            let start = cal.startOfDay(for: day)
            let end = cal.date(byAdding: .day, value: 1, to: start) ?? today
            return TimeScope(year: nil, month: nil, dayStart: start, dayEnd: end, label: "yesterday")
        }
        // A bare year (2026) anywhere in the question.
        if let yearMatch = firstMatch(#"\b(20\d{2})\b"#, in: q) {
            return TimeScope(year: Int(yearMatch), month: nil, dayStart: nil, dayEnd: nil, label: yearMatch)
        }
        // A month name ("in august", "during aug", "for march 2025").
        let months = DateFormatter().monthSymbols.map { $0.lowercased() }
        let shorts = DateFormatter().shortMonthSymbols.map {
            $0.lowercased().replacingOccurrences(of: ".", with: "")
        }
        for (idx, long) in months.enumerated() {
            if q.contains(" " + long) || q.contains(long + " ") {
                return monthScope(month: idx + 1, year: thisYear)
            }
        }
        for (idx, short) in shorts.enumerated() {
            if q.contains(" " + short) || q.contains(short + " ") {
                return monthScope(month: idx + 1, year: thisYear)
            }
        }
        return nil
    }

    // MARK: - Buyers

    /// Picks the buyer name from history that the question is most likely
    /// about. Matches loosely, like MemoryStore ("sri kumaran" → "SRI KUMARAN
    /// MILLS").
    private static func bestBuyerMatch(in q: String, entries: [HistoryEntry]) -> String? {
        let unique = Array(Set(entries.map(\.buyerName).filter { !$0.isEmpty }))
        // Exact-ish containment first (longest name wins).
        let contained = unique.filter { name in
            let k = key(name)
            return k.count >= 3 && q.contains(k)
        }.sorted { $0.count > $1.count }
        if let hit = contained.first { return hit }
        // Then loose word-overlap on multiword names ("billed ravi mills").
        let qWords = Set(q.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        var best: (name: String, score: Int)?
        for name in unique {
            let overlap = key(name).split(separator: " ").map(String.init).filter { qWords.contains($0) }.count
            if overlap > 0, overlap >= (best?.score ?? 0) {
                best = (name, overlap)
            }
        }
        return best?.name
    }

    // MARK: - Query recognisers

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHelpQuestion(_ q: String) -> Bool {
        let phrases = ["what can you do", "how do i", "how do you", "how to", "help", "doubts", "features", "what do you know"]
        return phrases.contains { q.contains($0) } && !q.contains("how many")
    }

    private static func looksDataish(_ q: String) -> Bool {
        let words = ["total", "how much", "how many", "invoice", "customer", "client", "sales", "billed", "revenue", "recent", "latest", "month", "august", "today", "yesterday", "count", "sum"]
        return words.contains { q.contains($0) }
    }

    private static func countRequested(_ q: String) -> Bool {
        q.contains("how many") || q.contains("count") || q.contains("count of")
    }

    private static func isMoneyQuestion(_ q: String) -> Bool {
        let words = ["total", "how much", "sales", "billed", "revenue", "earned", "money", "sum", "value", "amount"]
        return words.contains { q.contains($0) }
    }

    private static func nextNumberRequested(_ q: String) -> Bool {
        let phrases = ["next invoice number", "next number", "auto number", "what number should", "suggest a number", "last invoice number"]
        return phrases.contains { q.contains($0) }
    }

    /// "invoice no 5", "show invoice 5", "credit note 12"… Returns the number
    /// so the lookup can be precise.
    private static func documentNumber(in q: String) -> (number: String, type: InvoiceType?)? {
        let patterns = [
            #"(?:invoice|bill)\s*(?:no\.?|number)?\s*[:#]?\s*(\d+)"#,
            #"(?:credit note|debit note|delivery challan|challan)\s*(?:no\.?|number)?\s*[:#]?\s*(\d+)"#
        ]
        for pattern in patterns {
            if let m = firstMatch(pattern, in: q) {
                return (m, documentType(in: q))
            }
        }
        // "number 5" or a bare number in a "show/find/open" request.
        if (q.contains("show") || q.contains("find") || q.contains("open") || q.contains("display")),
           let m = firstMatch(#"(?:no\.?|number)?\s*[:#]?\s*(\d+)"#, in: q) {
            return (m, documentType(in: q))
        }
        return nil
    }

    private static func documentType(in q: String) -> InvoiceType? {
        if q.contains("credit note") { return .creditNote }
        if q.contains("debit note") { return .debitNote }
        if q.contains("challan") || q.contains("delivery") { return .deliveryChallan }
        if q.contains("tax invoice") || q.contains("tax") { return .taxInvoice }
        return nil
    }

    // MARK: - Answers

    private static func customerSummary(entries: [HistoryEntry]) -> String {
        let byBuyer = Dictionary(grouping: entries, by: { $0.buyerName.isEmpty ? "(unnamed)" : $0.buyerName })
        let rows = byBuyer.map { name, list -> (String, Int, Double) in
            (name, list.count, list.reduce(0) { $0 + $1.total })
        }.sorted { $0.2 > $1.2 }
        let buyerPlural = byBuyer.count == 1 ? "" : "s"
        var lines = ["You've billed **\(byBuyer.count)** customer\(buyerPlural):"]
        for (name, count, total) in rows {
            let plural = count == 1 ? "" : "s"
            lines.append("• **\(name)** — \(count) document\(plural), ₹\(inr(total))")
        }
        return lines.joined(separator: "\n")
    }

    private static func nextInvoiceNumberAdvice(entries: [HistoryEntry]) -> String {
        let numbers = entries.compactMap { Int($0.invoiceNo.filter(\.isNumber)) }
        guard let max = numbers.max() else {
            return "No invoice numbers saved yet — start wherever you like (commonly **1**)."
        }
        return "Your last invoice number was **\(max)**. The next one is likely **\(max + 1)** — mention it while creating, or I can take it from there."
    }

    private static func listing(_ matches: [HistoryEntry], header: String) -> String {
        var lines = [header]
        for entry in matches {
            let type = entry.invoiceType == .taxInvoice ? "Invoice" : entry.invoiceType.rawValue
            let buyer = entry.buyerName.isEmpty ? "—" : entry.buyerName
            let number = entry.invoiceNo.isEmpty ? "(no number)" : entry.invoiceNo
            let date = entry.dateLabel.isEmpty ? "no date" : entry.dateLabel
            lines.append("• **\(type) \(number)** · \(date) · \(buyer) · ₹\(inr(entry.total))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Concept answers ("doubts")

    private static func conceptAnswer(for q: String) -> String? {
        // Plain-language app questions (no definitional cue needed).
        if q.contains("remember") && (q.contains("product") || q.contains("buyer") || q.contains("memory")) {
            return "I keep a small memory of the products and buyers you use. Once you enter a product with its HSN code, or a buyer with GSTIN/address, the next time you name them I fill those in automatically and don't ask again. This memory lives only on this device."
        }
        if q.contains("where") && (q.contains("saved") || q.contains("stored")) {
            return "Every invoice you generate is saved on this device — see them under **Generate invoices** on the home screen. Nothing is uploaded anywhere."
        }

        // Term explanations must be *asked for* ("what is…", "define…") — merely
        // naming a term in a data question ("how many credit notes") is not a
        // concept request.
        let cues = ["what is", "what are", "define", "explain", "meaning", "difference",
                    "tell me about", "do i need", "when do i", "when to", "about "]
        guard cues.contains(where: { q.contains($0) }) else { return nil }

        if q.contains("difference") && q.contains("credit") && q.contains("debit") {
            return "A **Credit Note** is issued when you reduce an amount you already billed — e.g. goods returned or a pricing correction — so it lowers what the buyer owes. A **Debit Note** is the opposite: it adds a charge against an earlier invoice (extra quantity, revised rate, or charges you missed). Both must name the original invoice they refer to."
        }
        if q.contains("credit note") { return creditNoteText }
        if q.contains("debit note") { return debitNoteText }
        if q.contains("challan") { return challanText }
        if q.contains("gstin") { return gstinText }
        if isWholeWord("hsn", q) { return hsnText }
        if q.contains("e-way") || q.contains("eway") { return ewayText }
        if q.contains("cgst") || q.contains("sgst") { return cgstSgstText }
        if q.contains("igst") { return igstText }
        if (q.contains("state") && q.contains("tax")) || (q.contains("gst") && q.contains("rate")) {
            return "If the buyer is in **the same state** as you, charge CGST + SGST (State tax). If the buyer is in **another state**, charge IGST (National). Billify applies whichever you pick and prints the other as \"-\"."
        }
        return nil
    }

    private static let creditNoteText = "A **Credit Note** is issued to a buyer when an earlier invoice needs to be reduced — goods returned, short supply, or a rate correction. You enter the original invoice's number and date, and Billify prints the reference on the document."
    private static let debitNoteText = "A **Debit Note** adds an amount a buyer owes against an earlier invoice — for example extra goods supplied or a charge that was missed. Like a credit note, it references the original invoice it relates to."
    private static let challanText = "A **Delivery Challan** accompanies goods being dispatched — it lists products and quantities but carries **no tax**, so Billify skips GSTIN and tax questions for it."
    private static let gstinText = "**GSTIN** is the 15-character Goods & Services Tax number registered to a business (2-digit state code + PAN + entity + checksum). You need the buyer's GSTIN on tax invoices and credit/debit notes to claim input tax credit — delivery challans don't need it."
    private static let hsnText = "**HSN** is the Harmonised System code — the standard product classification used in GST. Cotton yarn is 5205, cotton waste 5202, and so on. Give me a product once with its HSN and I'll remember it."
    private static let ewayText = "An **e-way bill** is the 12-digit document number required when transporting goods above the value threshold (₹50,000). It's optional on the invoice form — leave it blank if it doesn't apply."
    private static let cgstSgstText = "**CGST** (Central GST) and **SGST** (State GST) are the two halves of GST on sales **within the same state**. At a 5% total rate that's 2.5% + 2.5%."
    private static let igstText = "**IGST** (Integrated GST) is charged instead of CGST + SGST when the buyer is in a **different state**. At 5% you print IGST 5% and show \"-\" for the state rows."

    // MARK: - Presentation helpers

    private static func description(of scope: TimeScope?, buyer: String?) -> String {
        var parts: [String] = []
        if let buyer { parts.append("for **\(buyer)**") }
        if let label = scope?.label { parts.append("in **\(label)**") }
        return parts.joined(separator: " ")
    }

    private static func inr(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_IN")
        formatter.maximumFractionDigits = value == value.rounded() ? 0 : 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func fuzzy(_ name: String, _ typed: String) -> Bool {
        let a = key(name), b = key(typed)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let longer = a.count >= b.count ? a : b
        let shorter = a.count >= b.count ? b : a
        return shorter.count >= 4 && longer.contains(shorter)
    }

    private static func isWholeWord(_ word: String, _ text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static let helpText = """
    I'm your invoice assistant. Ask me about your saved documents:

    • "How much have I billed in total?"
    • "Invoices this month / in August"
    • "How many invoices for Sri Kumaran Mills?"
    • "Show invoice 5" / "Who are my customers?"
    • "What should my next invoice number be?"

    Or ask about concepts — GSTIN, HSN, e-way bill, credit note vs debit note —
    and I'll explain. Start generating invoices from the home screen and they'll
    show up here automatically.
    """

    private static let fallbackText = "I didn't quite catch that. Try things like “total sales this month”, “how many credit notes”, “who are my customers”, or “what is an HSN code”."
}
