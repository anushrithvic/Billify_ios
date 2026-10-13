//
//  InvoiceHistoryStore.swift
//  Billify
//
//  Saved invoices (roadmap Phase 8/9, light version). Every document the user
//  generates is kept here so the home screen can list them ("Generate
//  invoices"), reopen + re-render the PDF, and the QA assistant can answer
//  questions about past billing.
//
//  Storage is a single JSON file in Application Support — the catalog stays
//  small and InvoiceData is already Codable, so no database layer is needed.
//  An entry stores the complete InvoiceData; the PDF itself is always
//  re-rendered from that data, so future layout fixes improve old invoices too.
//

import Foundation
import Combine

/// One saved document. `id` is stable across regenerations of the same
/// document (see `fingerprint`), so reopening or regenerating updates the
/// entry instead of duplicating it.
struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: String          // fingerprint — stable per document identity
    var data: InvoiceData
    var generatedAt: Date

    var invoiceType: InvoiceType { data.invoiceType }
    var invoiceNo: String { data.invoiceDetails.invoiceNo }
    var buyerName: String { data.buyer.name }
    var dateLabel: String { data.invoiceDetails.date }
    var total: Double { CalculationEngine.calculate(data).grandTotal }
}

final class InvoiceHistoryStore: ObservableObject {
    // (final so `shared` can reference the type in its initializer)

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    /// Shared instance rooted in Application Support (used by the app).
    static let shared = InvoiceHistoryStore(directory: InvoiceHistoryStore.defaultDirectory)

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Billify", isDirectory: true)
    }

    /// `directory` is injectable so tests can point at a temp folder.
    init(directory: URL = InvoiceHistoryStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("invoices.json")
        load()
    }

    // MARK: - Saving

    /// Upserts an entry for the given finished invoice. Regenerating the same
    /// document (same type + number + buyer + date) updates the stored copy in
    /// place rather than appending a duplicate row to the list.
    @discardableResult
    func record(_ data: InvoiceData) -> HistoryEntry {
        let fingerprint = Self.fingerprint(of: data)
        let entry = HistoryEntry(id: fingerprint, data: data, generatedAt: Date())
        if let idx = entries.firstIndex(where: { $0.id == fingerprint }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        save()
        return entry
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Stable identity for a document regardless of generatedAt.
    static func fingerprint(of data: InvoiceData) -> String {
        let parts = [
            data.invoiceType.rawValue,
            data.invoiceDetails.invoiceNo,
            data.invoiceDetails.date,
            MemoryStore.key(for: data.buyer.name)
        ]
        return parts.joined(separator: "|").lowercased()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.generatedAt > $1.generatedAt }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
