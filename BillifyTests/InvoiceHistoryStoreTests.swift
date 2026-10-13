//
//  InvoiceHistoryStoreTests.swift
//  BillifyTests
//
//  Persistence + upsert semantics of InvoiceHistoryStore: records round-trip
//  through the JSON file, regenerating the same document updates instead of
//  duplicating, and removal works.
//

import Testing
import Foundation
@testable import Billify

struct InvoiceHistoryStoreTests {

    private func makeData(no: String = "1", buyer: String = "SRI KUMARAN MILLS",
                          date: String = "12-08-2026") -> InvoiceData {
        var data = InvoiceData()
        data.invoiceDetails.invoiceNo = no
        data.invoiceDetails.date = date
        data.buyer.name = buyer
        data.buyer.gstin = "33AABCT1234F1Z5"
        var product = Product()
        product.name = "Cotton Yarn"
        product.hsn = "5205"
        product.quantity = 100
        product.unit = .bales
        product.weightKg = 4000
        product.ratePerKg = 150
        data.products = [product]
        return data
    }

    private func tempStore() throws -> (InvoiceHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("billify-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = InvoiceHistoryStore(directory: dir)
        return (store, dir)
    }

    @Test func recordRoundTripsThroughDisk() throws {
        let (store, dir) = try tempStore()
        store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS"))

        // Fresh store over the same directory sees the saved entry.
        let reloaded = InvoiceHistoryStore(directory: dir)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries[0].invoiceNo == "5")
        #expect(reloaded.entries[0].buyerName == "SRI KUMARAN MILLS")
        #expect(reloaded.entries[0].total == 630000) // 4000kg × ₹150 + 5% GST
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func regeneratingSameDocumentDoesNotDuplicate() throws {
        let (store, dir) = try tempStore()
        store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS"))
        store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS"))
        #expect(store.entries.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func differentDocumentsStaySeparate() throws {
        let (store, dir) = try tempStore()
        store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS"))
        store.record(makeData(no: "6", buyer: "RAVI TEXTILES"))
        store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS", date: "01-09-2026"))
        #expect(store.entries.count == 3)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func removeDeletesEntry() throws {
        let (store, dir) = try tempStore()
        let a = store.record(makeData(no: "5", buyer: "SRI KUMARAN MILLS"))
        store.record(makeData(no: "6", buyer: "RAVI TEXTILES"))
        store.remove(a)
        #expect(store.entries.count == 1)
        #expect(store.entries[0].invoiceNo == "6")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func fingerprintDistinguishesTypesAndNumbers() {
        var data = makeData(no: "5", buyer: "SRI KUMARAN MILLS")
        let tax = InvoiceHistoryStore.fingerprint(of: data)
        data.invoiceType = .creditNote
        let credit = InvoiceHistoryStore.fingerprint(of: data)
        data.invoiceType = .debitNote
        let debit = InvoiceHistoryStore.fingerprint(of: data)
        #expect(tax != credit)
        #expect(credit != debit)
    }
}
