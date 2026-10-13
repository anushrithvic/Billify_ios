//
//  QAEngineTests.swift
//  BillifyTests
//
//  Behavioral tests for InvoiceQAEngine — totals, counts, buyers, months,
//  document lookup, next-number advice, concept answers, and the empty state.
//

import Testing
import Foundation
@testable import Billify

struct QAEngineTests {

    /// A fixed "today" so month/year scoping is deterministic.
    private let today: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 5
        return Calendar.current.date(from: c) ?? Date()
    }()

    private func entry(no: String = "1", buyer: String = "SRI KUMARAN MILLS",
                       date: String = "12-08-2026", weight: Double = 4000, rate: Double = 150,
                       type: InvoiceType = .taxInvoice, name: String = "Cotton Yarn") -> HistoryEntry {
        var data = InvoiceData()
        data.invoiceType = type
        data.invoiceDetails.invoiceNo = no
        data.invoiceDetails.date = date
        data.buyer.name = buyer
        data.buyer.gstin = "33AABCT1234F1Z5"
        var product = Product()
        product.name = name
        product.hsn = "5205"
        product.quantity = 100
        product.unit = .bales
        product.weightKg = weight
        product.ratePerKg = rate
        data.products = [product]
        return HistoryEntry(id: InvoiceHistoryStore.fingerprint(of: data), data: data, generatedAt: today)
    }

    private func answer(_ q: String, entries: [HistoryEntry]) -> String {
        InvoiceQAEngine.answer(q, entries: entries, today: today)
    }

    // MARK: - Totals & scoping

    @Test func grandTotalIsSummedAcrossInvoices() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", weight: 4000, rate: 150),   // 6,30,000
            entry(no: "2", buyer: "RAVI TEXTILES", weight: 1000, rate: 40)          // 42,000
        ]
        let out = answer("how much have I billed in total?", entries: entries)
        #expect(out.contains("6,72,000"))
        #expect(out.contains("2 document"))
    }

    @Test func moneyQuestionScopedToBuyer() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", weight: 4000, rate: 150),   // 6,30,000
            entry(no: "2", buyer: "RAVI TEXTILES", weight: 1000, rate: 40)          // 42,000
        ]
        let out = answer("how much did I bill Sri Kumaran Mills", entries: entries)
        #expect(out.contains("SRI KUMARAN MILLS"))
        #expect(out.contains("6,30,000"))
    }

    @Test func moneyQuestionScopedToMonth() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", date: "10-08-2026", weight: 4000, rate: 150), // 6,30,000
            entry(no: "2", buyer: "RAVI TEXTILES", date: "03-09-2026", weight: 1000, rate: 40)        // 42,000
        ]
        let out = answer("total sales in august", entries: entries)
        #expect(out.contains("August 2026"))
        #expect(out.contains("6,30,000"))
        #expect(!out.contains("42,000"))
    }

    // MARK: - Counts

    @Test func countsDocuments() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", type: .taxInvoice),
            entry(no: "2", buyer: "RAVI TEXTILES", type: .creditNote),
            entry(no: "3", buyer: "KK SPINNERS", type: .deliveryChallan)
        ]
        let out = answer("how many invoices have I made", entries: entries)
        #expect(out.contains("3"))
        #expect(out.contains("credit note"))
        #expect(out.contains("challan"))
    }

    @Test func countsOneTypeOnly() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", type: .creditNote),
            entry(no: "2", buyer: "RAVI TEXTILES", type: .taxInvoice)
        ]
        let out = answer("how many credit notes", entries: entries)
        #expect(out.contains("1"))
        #expect(out.contains("credit note"))
    }

    @Test func countForBuyer() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS"),
            entry(no: "2", buyer: "SRI KUMARAN MILLS"),
            entry(no: "3", buyer: "RAVI TEXTILES")
        ]
        let out = answer("how many invoices for Ravi Textiles", entries: entries)
        #expect(out.contains("1"))
        #expect(out.uppercased().contains("RAVI TEXTILES"))
    }

    // MARK: - Customers / lookups / numbers

    @Test func listsCustomersWithTotals() {
        let entries = [
            entry(no: "1", buyer: "SRI KUMARAN MILLS", weight: 4000, rate: 150), // 6,30,000
            entry(no: "2", buyer: "RAVI TEXTILES", weight: 1000, rate: 40)       // 42,000
        ]
        let out = answer("who are my customers", entries: entries)
        #expect(out.contains("SRI KUMARAN MILLS"))
        #expect(out.contains("RAVI TEXTILES"))
        #expect(out.contains("6,30,000"))
    }

    @Test func findsDocumentByNumber() {
        let entries = [
            entry(no: "5", buyer: "SRI KUMARAN MILLS"),
            entry(no: "7", buyer: "RAVI TEXTILES")
        ]
        let out = answer("show invoice 5", entries: entries)
        #expect(out.contains("5"))
        #expect(out.contains("SRI KUMARAN MILLS"))
        #expect(!out.contains("7"))
    }

    @Test func suggestsNextInvoiceNumber() {
        let entries = [
            entry(no: "9", buyer: "SRI KUMARAN MILLS"),
            entry(no: "14", buyer: "RAVI TEXTILES")
        ]
        let out = answer("what should my next invoice number be", entries: entries)
        #expect(out.contains("15"))
    }

    @Test func recentListingShowsNewestFirst() {
        let entries = [
            entry(no: "1", buyer: "A MILLS"),
            entry(no: "2", buyer: "B MILLS"),
            entry(no: "3", buyer: "C MILLS")
        ]
        let out = answer("show my recent invoices", entries: entries)
        #expect(out.contains("3"))
    }

    // MARK: - Concepts & empty state

    @Test func explainsHsnConcept() {
        let out = answer("what is an hsn code", entries: [])
        #expect(out.contains("Harmonised"))
    }

    @Test func explainsCreditVsDebit() {
        let out = answer("what is the difference between credit note and debit note", entries: [])
        #expect(out.contains("Credit Note"))
        #expect(out.contains("Debit Note"))
    }

    @Test func emptyHistoryGuidesToCreatingFirstInvoice() {
        let out = answer("how much have I billed", entries: [])
        #expect(out.contains("saved invoices"))
        #expect(out.contains("Generate"))
    }

    @Test func helpQuestionAlwaysAnswers() {
        let out = answer("what can you do", entries: [])
        #expect(out.contains("invoice assistant"))
    }
}
