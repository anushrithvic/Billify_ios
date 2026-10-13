//
//  Memory.swift
//  Billify
//
//  Billify's long-term memory. The user works from a small, repeated set of
//  products and buyers (a spinning mill bills the same handful of mills again
//  and again), so once a product name has been paired with an HSN code, or a
//  buyer name with an address/GSTIN, later invoices shouldn't re-ask for them.
//
//  Persistence is plain JSON in UserDefaults — the catalog is tiny (tens of
//  entries), there's no server, and it keeps the app's plain-struct model
//  untouched. If full invoice persistence (Phase 8) lands later, this catalog
//  can migrate to SwiftData without callers changing: everything funnels
//  through the MemoryStore API below.
//

import Foundation
import Combine

/// A product the user has invoiced before: name → HSN code.
struct KnownProduct: Codable, Equatable, Identifiable {
    var name: String
    var hsn: String
    var lastUsed: Date

    var id: String { name }
    var key: String { MemoryStore.key(for: name) }
}

/// A buyer the user has invoiced before: name → GSTIN + address lines.
struct KnownBuyer: Codable, Equatable, Identifiable {
    var name: String
    var gstin: String
    var address: [String]

    var id: String { name }
    var key: String { MemoryStore.key(for: name) }
}

@MainActor
final class MemoryStore: ObservableObject {

    @Published private(set) var products: [KnownProduct] = []
    @Published private(set) var buyers: [KnownBuyer] = []

    private let defaults: UserDefaults
    private static let productsKey = "billify.memory.products.v1"
    private static let buyersKey = "billify.memory.buyers.v1"

    /// Shared instance backed by UserDefaults.standard — used app-wide so the
    /// Products & Buyers screen and every chat session see the same catalog
    /// live, the same way InvoiceHistoryStore.shared works for saved invoices.
    static let shared = MemoryStore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Lookup

    /// HSN remembered for a product name. Matching is case/space-insensitive
    /// and tolerates extra words ("cotton yarn" matches "Combed Cotton Yarn").
    func hsn(forProductNamed name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return products.first { isCloseMatch($0.key, name) }?.hsn
    }

    /// Full remembered buyer record for a loosely-matching name.
    func buyer(named name: String) -> KnownBuyer? {
        guard !name.isEmpty else { return nil }
        return buyers.first { isCloseMatch($0.key, name) }
    }

    /// Exact GSTIN lookup — a GSTIN is unique per registered business, so this
    /// is a straight match rather than the fuzzy name matching used elsewhere.
    /// This is what powers "type the GSTIN and everything else fills in",
    /// both in chat and in the Products & Buyers screen.
    func buyer(withGstin gstin: String) -> KnownBuyer? {
        let normalized = gstin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 15 else { return nil }
        return buyers.first { $0.gstin.uppercased() == normalized }
    }

    // MARK: - Learning

    func remember(productName name: String, hsn: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHsn = hsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedHsn.isEmpty else { return }
        let key = MemoryStore.key(for: trimmedName)
        if let idx = products.firstIndex(where: { $0.key == key }) {
            var entry = products[idx]
            entry.hsn = trimmedHsn
            entry.lastUsed = Date()
            products[idx] = entry
        } else {
            products.append(KnownProduct(name: trimmedName, hsn: trimmedHsn, lastUsed: Date()))
        }
        save()
    }

    /// Upserts a buyer record, filling any blank fields in an existing record
    /// rather than clobbering it (the first entry may only have an address,
    /// a later one may add the GSTIN).
    func remember(buyer party: Party) {
        let name = party.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = party.address.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let gstin = party.gstin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !(gstin.isEmpty && address.allSatisfy(\.isEmpty)) else { return }
        let key = MemoryStore.key(for: name)
        if let idx = buyers.firstIndex(where: { $0.key == key }) {
            var entry = buyers[idx]
            if !gstin.isEmpty && entry.gstin.isEmpty { entry.gstin = gstin }
            for i in 0..<4 where entry.address.count > i {
                if entry.address[i].isEmpty && !address[i].isEmpty { entry.address[i] = address[i] }
            }
            buyers[idx] = entry
        } else {
            buyers.append(KnownBuyer(name: name, gstin: gstin, address: address))
        }
        save()
    }

    /// Sweeps an invoice draft for anything worth remembering. Call it after
    /// any draft mutation — it's cheap and idempotent.
    func learn(from invoice: InvoiceData) {
        for product in invoice.products {
            remember(productName: product.name, hsn: product.hsn)
        }
        if !invoice.buyer.name.isEmpty {
            remember(buyer: invoice.buyer)
        }
    }

    // MARK: - Manual catalog management (Products & Buyers screen)

    /// Adds a new known product, or — when `originalName` is passed — updates
    /// that existing entry in place (so renaming a product doesn't leave a
    /// stale duplicate behind).
    func upsertProduct(originalName: String?, name: String, hsn: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHsn = hsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if let originalName, let idx = products.firstIndex(where: { $0.name == originalName }) {
            products[idx] = KnownProduct(name: trimmedName, hsn: trimmedHsn, lastUsed: products[idx].lastUsed)
        } else if let idx = products.firstIndex(where: { $0.key == MemoryStore.key(for: trimmedName) }) {
            products[idx].hsn = trimmedHsn
            products[idx].lastUsed = Date()
        } else {
            products.append(KnownProduct(name: trimmedName, hsn: trimmedHsn, lastUsed: Date()))
        }
        save()
    }

    func deleteProduct(named name: String) {
        products.removeAll { $0.name == name }
        save()
    }

    /// Adds a new known buyer, or — when `originalName` is passed — updates
    /// that existing entry in place. Unlike `remember(buyer:)` (which only
    /// fills in blanks, so an automatic partial extraction never clobbers a
    /// fuller saved record), this replaces the fields outright: the person is
    /// editing the record directly here, so their edit should win.
    func upsertBuyer(originalName: String?, name: String, gstin: String, address: [String]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedGstin = gstin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedAddress = address.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let entry = KnownBuyer(name: trimmedName, gstin: trimmedGstin, address: trimmedAddress)
        if let originalName, let idx = buyers.firstIndex(where: { $0.name == originalName }) {
            buyers[idx] = entry
        } else if let idx = buyers.firstIndex(where: { $0.key == MemoryStore.key(for: trimmedName) }) {
            buyers[idx] = entry
        } else {
            buyers.append(entry)
        }
        save()
    }

    func deleteBuyer(named name: String) {
        buyers.removeAll { $0.name == name }
        save()
    }

    // MARK: - Normalization

    /// Case/space-insensitive, punctuation-stripped key used for matching.
    static func key(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func isCloseMatch(_ key: String, _ typedName: String) -> Bool {
        let typed = MemoryStore.key(for: typedName)
        guard !typed.isEmpty else { return false }
        if key == typed { return true }
        let longer = key.count >= typed.count ? key : typed
        let shorter = key.count >= typed.count ? typed : key
        return shorter.count >= 4 && longer.contains(shorter)
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: Self.productsKey),
           let decoded = try? JSONDecoder().decode([KnownProduct].self, from: data) {
            products = decoded
        }
        if let data = defaults.data(forKey: Self.buyersKey),
           let decoded = try? JSONDecoder().decode([KnownBuyer].self, from: data) {
            buyers = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(products) {
            defaults.set(data, forKey: Self.productsKey)
        }
        if let data = try? JSONEncoder().encode(buyers) {
            defaults.set(data, forKey: Self.buyersKey)
        }
    }
}
