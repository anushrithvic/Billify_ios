//
//  CatalogView.swift
//  Billify
//
//  "Products & Buyers" — a dedicated space to set up the catalog Billify
//  otherwise only learns passively during chat (Models/Memory.swift). Add
//  HSN codes for products ahead of time, and buyers with their GSTIN and
//  address, so a new invoice never has to ask for something already on file.
//
//  The buyer form's GSTIN field is the main convenience here: type a GSTIN
//  that's already saved against another buyer and the name/address fill in
//  automatically, the same way it works mid-chat.
//
//  Faster entry helpers in both forms: live autocomplete under the Name field
//  (NameSuggester — the same filter the chat composer uses), a "paste details
//  → Fill from text" box, and a photo/camera path that OCRs on-device. Paste
//  and photo both funnel through FormFillEngine into one rule: only *blank*
//  fields get filled, anything already typed is left alone.
//

import SwiftUI
import UIKit
import PhotosUI

struct CatalogView: View {
    @EnvironmentObject private var memory: MemoryStore

    private enum Tab: String, CaseIterable, Identifiable {
        case products = "Products"
        case buyers = "Buyers"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .products
    @State private var editingProduct: KnownProduct?
    @State private var editingBuyer: KnownBuyer?
    @State private var isAddingProduct = false
    @State private var isAddingBuyer = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            switch tab {
            case .products: productsList
            case .buyers: buyersList
            }
        }
        .background(Theme.background)
        .navigationTitle("Products & Buyers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    switch tab {
                    case .products: isAddingProduct = true
                    case .buyers: isAddingBuyer = true
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(item: $editingProduct) { product in
            ProductFormView(originalName: product.name, name: product.name, hsn: product.hsn)
        }
        .sheet(isPresented: $isAddingProduct) {
            ProductFormView(originalName: nil, name: "", hsn: "")
        }
        .sheet(item: $editingBuyer) { buyer in
            BuyerFormView(originalName: buyer.name, name: buyer.name,
                          gstin: buyer.gstin, address: buyer.paddedAddress)
        }
        .sheet(isPresented: $isAddingBuyer) {
            BuyerFormView(originalName: nil, name: "", gstin: "", address: ["", "", "", ""])
        }
    }

    // MARK: - Products

    private var productsList: some View {
        Group {
            if memory.products.isEmpty {
                emptyState(
                    icon: "shippingbox",
                    title: "No saved products yet",
                    caption: "Add a product and its HSN code here, and it fills in automatically next time you invoice it."
                )
            } else {
                List {
                    Section {
                        ForEach(memory.products.sorted { $0.name < $1.name }) { product in
                            Button {
                                editingProduct = product
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(product.name)
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(Theme.ink)
                                        Text("HSN \(product.hsn.isEmpty ? "—" : product.hsn)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.inkSoft)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(Theme.inkSoft.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation { memory.deleteProduct(named: product.name) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("\(memory.products.count) saved product\(memory.products.count == 1 ? "" : "s")")
                            .textCase(.uppercase)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Buyers

    private var buyersList: some View {
        Group {
            if memory.buyers.isEmpty {
                emptyState(
                    icon: "person.crop.rectangle",
                    title: "No saved buyers yet",
                    caption: "Add a buyer's name, GSTIN and address here — invoices for them fill in automatically."
                )
            } else {
                List {
                    Section {
                        ForEach(memory.buyers.sorted { $0.name < $1.name }) { buyer in
                            Button {
                                editingBuyer = buyer
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(buyer.name)
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(Theme.ink)
                                        Text(buyer.gstin.isEmpty ? "No GSTIN saved" : buyer.gstin)
                                            .font(.caption)
                                            .foregroundStyle(Theme.inkSoft)
                                        let addr = buyer.address.filter { !$0.isEmpty }.joined(separator: ", ")
                                        if !addr.isEmpty {
                                            Text(addr)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.inkSoft.opacity(0.85))
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(Theme.inkSoft.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation { memory.deleteBuyer(named: buyer.name) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("\(memory.buyers.count) saved buyer\(memory.buyers.count == 1 ? "" : "s")")
                            .textCase(.uppercase)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func emptyState(icon: String, title: String, caption: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Theme.emerald.opacity(0.7))
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension KnownBuyer {
    /// The stored address may have fewer than 4 lines (older records); the
    /// form always shows exactly 4 fields.
    var paddedAddress: [String] {
        address.count >= 4 ? Array(address.prefix(4)) : address + Array(repeating: "", count: 4 - address.count)
    }
}

// MARK: - Product form

private struct ProductFormView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var memory: MemoryStore

    let originalName: String?
    @State var name: String
    @State var hsn: String
    @State private var fillOutcome: CatalogFillOutcome?

    /// Autocomplete under the Name field: saved product names with the typed
    /// prefix. The record being edited is never suggested against itself.
    private var nameSuggestions: [String] {
        NameSuggester.suggestions(for: name, in: memory.products.map(\.name).filter { $0 != originalName })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Product name (e.g. Cotton Yarn)", text: $name)
                        .autocorrectionDisabled()
                    CatalogNameSuggestions(suggestions: nameSuggestions, icon: "shippingbox") { picked in
                        name = picked
                    }
                    TextField("HSN code", text: $hsn)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                }
                CatalogFillSection(note: fillOutcome) { pasted in
                    fillFromText(pasted)
                } onPhotoFailed: {
                    fillOutcome = .failed("Couldn't read any text from that photo — try a clearer, closer shot.")
                }
                if originalName != nil {
                    Section {
                        Button("Delete product", role: .destructive) {
                            if let originalName { memory.deleteProduct(named: originalName) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(originalName == nil ? "Add product" : "Edit product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        memory.upsertProduct(originalName: originalName, name: name, hsn: hsn)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Theme.accent)
    }

    /// Paste-to-fill / photo-to-fill: fills only the fields still blank, so
    /// anything already typed (or pre-filled when editing) is never clobbered.
    private func fillFromText(_ text: String) {
        let result = FormFillEngine.fill(from: text, memory: memory)
        var filledSomething = false
        if let found = result.productName, name.isEffectivelyBlank {
            name = found
            filledSomething = true
        }
        if let found = result.productHsn, hsn.isEffectivelyBlank {
            hsn = found
            filledSomething = true
        }
        fillOutcome = filledSomething
            ? .filled("Filled the blank fields — check them before saving.")
            : .failed("Couldn't find product details in that text.")
    }
}

// MARK: - Buyer form

private struct BuyerFormView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var memory: MemoryStore

    let originalName: String?
    @State var name: String
    @State var gstin: String
    @State var address: [String]
    @State private var autofillNote: String?
    @State private var fillOutcome: CatalogFillOutcome?

    /// Autocomplete under the Name field: saved buyer names with the typed
    /// prefix. The record being edited is never suggested against itself.
    private var nameSuggestions: [String] {
        NameSuggester.suggestions(for: name, in: memory.buyers.map(\.name).filter { $0 != originalName })
    }

    private static let gstinRegex = try! NSRegularExpression(
        pattern: #"^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d]$"#)

    var body: some View {
        NavigationStack {
            Form {
                Section("Buyer") {
                    TextField("Buyer name", text: $name)
                        .autocorrectionDisabled()
                    CatalogNameSuggestions(suggestions: nameSuggestions, icon: "person") { picked in
                        name = picked
                    }
                    TextField("GSTIN", text: $gstin)
                        .autocapitalization(.allCharacters)
                        .autocorrectionDisabled()
                        .onChange(of: gstin) { _, newValue in
                            gstin = newValue.uppercased()
                            attemptAutofill()
                        }
                    if let autofillNote {
                        Label(autofillNote, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.emerald)
                    }
                }
                Section("Address") {
                    ForEach(0..<4, id: \.self) { i in
                        TextField("Address line \(i + 1)", text: addressBinding(i))
                    }
                }
                CatalogFillSection(note: fillOutcome) { pasted in
                    fillFromText(pasted)
                } onPhotoFailed: {
                    fillOutcome = .failed("Couldn't read any text from that photo — try a clearer, closer shot.")
                }
                if originalName != nil {
                    Section {
                        Button("Delete buyer", role: .destructive) {
                            if let originalName { memory.deleteBuyer(named: originalName) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(originalName == nil ? "Add buyer" : "Edit buyer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        memory.upsertBuyer(originalName: originalName, name: name, gstin: gstin, address: address)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Theme.accent)
    }

    private func addressBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < address.count ? address[i] : "" },
            set: { newValue in
                while address.count <= i { address.append("") }
                address[i] = newValue
            }
        )
    }

    /// When the typed GSTIN matches a *different* saved buyer, fill in any
    /// blank name/address fields from that record — the same "type the GST
    /// and everything else comes up" shortcut chat uses.
    private func attemptAutofill() {
        let trimmed = gstin.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        guard Self.gstinRegex.firstMatch(in: trimmed, range: fullRange) != nil,
              let known = memory.buyer(withGstin: trimmed),
              known.name != originalName else { return }

        var filledSomething = false
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = known.name
            filledSomething = true
        }
        for i in 0..<4 where i < known.address.count {
            if i < address.count, address[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !known.address[i].isEmpty {
                address[i] = known.address[i]
                filledSomething = true
            }
        }
        autofillNote = filledSomething ? "Filled in from \(known.name)'s saved record." : nil
    }

    /// Paste-to-fill / photo-to-fill: fills only the fields still blank, so
    /// anything already typed (or pre-filled when editing) is never clobbered.
    /// A GSTIN that's already saved against a *different* buyer is flagged so
    /// a near-duplicate isn't created silently.
    private func fillFromText(_ text: String) {
        let result = FormFillEngine.fill(from: text, memory: memory, ignoringBuyerNamed: originalName)
        var filledSomething = false
        if let found = result.buyerName, name.isEffectivelyBlank {
            name = found
            filledSomething = true
        }
        if let found = result.buyerGstin, gstin.isEffectivelyBlank {
            gstin = found
            filledSomething = true
        }
        for i in 0..<min(4, result.buyerAddress.count)
        where addressBinding(i).wrappedValue.isEffectivelyBlank && !result.buyerAddress[i].isEmpty {
            addressBinding(i).wrappedValue = result.buyerAddress[i]
            filledSomething = true
        }
        if let duplicate = result.duplicateBuyerName {
            fillOutcome = .alreadySaved(duplicate)
        } else {
            fillOutcome = filledSomething
                ? .filled("Filled the blank fields — check them before saving.")
                : .failed("Couldn't find buyer details in that text.")
        }
    }
}

// MARK: - Shared form helpers (Product + Buyer)

/// Outcome of a fill-from-text/photo pass, shown as a note under the fields.
enum CatalogFillOutcome {
    case filled(String)
    case alreadySaved(String)
    case failed(String)

    var message: String {
        switch self {
        case .filled(let m), .alreadySaved(let m), .failed(let m): return m
        }
    }

    var icon: String {
        switch self {
        case .filled: return "checkmark.circle.fill"
        case .alreadySaved: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .filled: return Theme.emerald
        case .alreadySaved: return .orange
        case .failed: return .red
        }
    }
}

/// Live autocomplete under a Name field: a simple list of saved names with
/// the typed prefix (same NameSuggester filter the chat composer uses), so a
/// saved entry gets picked instead of a near-duplicate being created. Hides
/// itself once the field is empty or an exact saved name is selected (both
/// are NameSuggester behavior) — and renders nothing at all when there are
/// no matches.
struct CatalogNameSuggestions: View {
    var suggestions: [String]
    var icon: String
    var onPick: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onPick(suggestion)
                    } label: {
                        Label {
                            Text(suggestion)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: icon)
                                .foregroundStyle(Theme.emerald)
                        }
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("catalogSuggestion_\(suggestion)")
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.pale))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.emerald.opacity(0.25), lineWidth: 1))
            .padding(.top, 4)
        }
    }
}

/// The shared paste box + Fill from text button + photo/camera menu used by
/// both catalog forms. Every path funnels into the form's one `onFillText`
/// handler, so typed/pasted text and OCR'd photos behave identically.
struct CatalogFillSection: View {
    var note: CatalogFillOutcome?
    var onFillText: (String) -> Void
    var onPhotoFailed: () -> Void

    @State private var pastedText = ""
    @State private var showLibraryPicker = false
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isReadingPhoto = false

    var body: some View {
        Section("Fill from photo or paste") {
            TextEditor(text: $pastedText)
                .frame(minHeight: 56)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.ink)
                .accessibilityLabel("Paste details here")
            Button {
                onFillText(pastedText)
            } label: {
                Label("Fill from text", systemImage: "text.badge.plus")
            }
            .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            photoMenu

            if isReadingPhoto {
                Label("Reading the photo…", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            if let note {
                Label(note.message, systemImage: note.icon)
                    .font(.caption)
                    .foregroundStyle(note.color)
            }
        }
    }

    /// Camera / photo-library entry — the same pickers chat uses. The camera
    /// option only appears on devices that actually have one.
    private var photoMenu: some View {
        Menu {
            Button {
                showLibraryPicker = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } label: {
            Label(isReadingPhoto ? "Reading photo…" : "Fill from Photo",
                  systemImage: isReadingPhoto ? "hourglass" : "camera.viewfinder")
        }
        .disabled(isReadingPhoto)
        .photosPicker(isPresented: $showLibraryPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                processPhoto(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    processPhoto(image)
                } else {
                    onPhotoFailed()
                }
                pickerItem = nil
            }
        }
    }

    /// OCRs the image on-device (Vision — nothing leaves the phone) and hands
    /// the recognized text through the same fill handler as a paste.
    private func processPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            onPhotoFailed()
            return
        }
        isReadingPhoto = true
        Task { @MainActor in
            let ocr = await OCRService.recognizeText(in: data)
            isReadingPhoto = false
            let text = ocr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                onPhotoFailed()
            } else {
                onFillText(text)
            }
        }
    }
}

private extension String {
    /// Blank from the user's perspective: empty, whitespace, or newlines —
    /// the "fill blank fields only" test for every auto-fill path.
    var isEffectivelyBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
