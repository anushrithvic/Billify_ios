//
//  CatalogHelpersTests.swift
//  BillifyTests
//
//  Covers the two cores behind the Products & Buyers entry helpers:
//  NameSuggester (autocomplete shared by chat + forms) and FormFillEngine
//  (paste/photo-to-fill in the catalog forms).
//

import Testing
import Foundation
@testable import Billify

struct NameSuggesterTests {

    private let names = ["Radhika Mills", "Raja Textiles", "Ravi Textiles", "Anush Traders",
                         "ravi kumar", "Cotton Yarn", "Cotton Waste"]

    @Test func prefixMatchesCaseInsensitively() {
        let result = NameSuggester.suggestions(for: "Ra", in: names)
        #expect(result.contains("Radhika Mills"))
        #expect(result.contains("Raja Textiles"))
        #expect(!result.contains("Anush Traders"))
    }

    @Test func suggestionsAreSortedAlphabetically() {
        let result = NameSuggester.suggestions(for: "ra", in: names)
        #expect(result == ["Radhika Mills", "Raja Textiles", "ravi kumar", "Ravi Textiles"])
    }

    @Test func emptyTypedTextYieldsNothing() {
        #expect(NameSuggester.suggestions(for: "", in: names).isEmpty)
        #expect(NameSuggester.suggestions(for: "   ", in: names).isEmpty)
    }

    @Test func exactMatchIsExcluded() {
        // Tapping the only remaining suggestion would be a no-op; the row
        // disappearing IS the "already selected" signal.
        #expect(NameSuggester.suggestions(for: "ravi textiles", in: names).isEmpty)
    }

    @Test func resultsAreCappedAtSix() {
        let many = (1...10).map { "Mill \($0)" }
        #expect(NameSuggester.suggestions(for: "mill", in: many).count == NameSuggester.suggestionLimit)
    }

    @Test func noMatchYieldsNothing() {
        #expect(NameSuggester.suggestions(for: "zzz", in: names).isEmpty)
    }
}

@MainActor
struct FormFillEngineTests {

    private func makeMemory() -> MemoryStore {
        MemoryStore(defaults: UserDefaults(suiteName: "fill-engine-tests-\(UUID().uuidString)")!)
    }

    // MARK: Buyer targets

    @Test func letterheadStyleTextFillsBuyerFields() {
        let result = FormFillEngine.fill(
            from: """
            buyer : Anush Traders
            gstin 33AIMPM2628J1Z4
            address : 12 Bazaar Street, Coimbatore, Tamil Nadu
            """,
            memory: makeMemory())
        #expect(result.buyerName == "Anush Traders")
        #expect(result.buyerGstin == "33AIMPM2628J1Z4")
        #expect(result.buyerAddress.contains { $0.contains("Coimbatore") })
        #expect(result.duplicateBuyerName == nil)
    }

    @Test func productStyleTextFillsNameAndHsn() {
        let result = FormFillEngine.fill(from: "Cotton Yarn HSN 5205", memory: makeMemory())
        #expect(result.productName?.lowercased().contains("cotton yarn") == true)
        #expect(result.productHsn == "5205")
        #expect(result.buyerName == nil)
        #expect(result.buyerGstin == nil)
    }

    @Test func buyerTextPastedIntoProductFormDoesNotBecomeTheName() {
        // Cross-form misuse: a letterhead in the *product* form must not fill
        // the product name with buyer/address leftovers.
        let result = FormFillEngine.fill(
            from: "buyer : Anush Traders, address : 12 Bazaar Street, Coimbatore",
            memory: makeMemory())
        #expect(result.productName == nil)
    }

    @Test func savedGstinIsFlaggedAsDuplicate() {
        let memory = makeMemory()
        memory.upsertBuyer(originalName: nil, name: "Anush Traders", gstin: "33AIMPM2628J1Z4", address: [])
        let result = FormFillEngine.fill(
            from: "gstin 33AIMPM2628J1Z4 name Anush Traders", memory: memory)
        #expect(result.duplicateBuyerName == "Anush Traders")
    }

    @Test func duplicateCheckIgnoresTheRecordBeingEdited() {
        let memory = makeMemory()
        memory.upsertBuyer(originalName: nil, name: "Anush Traders", gstin: "33AIMPM2628J1Z4", address: [])
        let result = FormFillEngine.fill(
            from: "gstin 33AIMPM2628J1Z4", memory: memory, ignoringBuyerNamed: "Anush Traders")
        #expect(result.duplicateBuyerName == nil)
    }

    @Test func blankTextFillsNothing() {
        let result = FormFillEngine.fill(from: "   \n  ", memory: makeMemory())
        #expect(result.productName == nil && result.productHsn == nil)
        #expect(result.buyerName == nil && result.buyerGstin == nil)
        #expect(result.duplicateBuyerName == nil)
    }
}

@MainActor
struct ChatSuggestionTests {

    private func makeMemory() -> MemoryStore {
        let store = MemoryStore(defaults: UserDefaults(suiteName: "chat-suggest-\(UUID().uuidString)")!)
        store.remember(productName: "Cotton Yarn", hsn: "5205")
        store.remember(productName: "Cotton Waste", hsn: "5202")
        var buyer = Party(name: "Ravi Textiles")
        buyer.gstin = "33AIMPM2628J1Z4"
        store.remember(buyer: buyer)
        var other = Party(name: "Radhika Mills")
        other.gstin = "33AABCT1234F1Z5"
        store.remember(buyer: other)
        return store
    }

    private func type(_ vm: ChatViewModel, _ text: String) {
        vm.inputText = text
    }

    @Test func suggestionsOnlyShowWhileAwaitingANameField() {
        let vm = ChatViewModel(memory: makeMemory())

        // Fresh chat: waiting on document type — no name suggestions, no
        // matter what's typed.
        type(vm, "cotton")
        #expect(vm.nameSuggestions.isEmpty)

        // After the type is confirmed, the flow asks for the product name.
        type(vm, "tax invoice")
        vm.send()
        type(vm, "cot")
        #expect(vm.nameSuggestions.count == 2)

        // Answering moves past the product-name field.
        type(vm, "cotton yarn")
        vm.send()
        type(vm, "cot")
        #expect(vm.nameSuggestions.isEmpty) // now waiting on HSN
    }

    @Test func buyerNameSuggestionsComeFromSavedBuyers() {
        let vm = ChatViewModel(memory: makeMemory(), initialType: .taxInvoice)
        // Skip past the product questions to reach the buyer-name question.
        // "Cotton Yarn" is seeded in memory with HSN 5205, so the HSN auto-fills
        // and only 4 replies are needed to complete the product.
        for answer in ["cotton yarn", "100", "4000", "150"] {
            type(vm, answer)
            vm.send()
        }
        #expect(vm.isAwaitingBuyerName)

        type(vm, "rav")
        #expect(vm.nameSuggestions == ["Ravi Textiles"])
        type(vm, "rad")
        #expect(vm.nameSuggestions == ["Radhika Mills"])
    }

    @Test func tappingSuggestionSendsItLikeTypedInput() {
        let vm = ChatViewModel(memory: makeMemory(), initialType: .taxInvoice)
        type(vm, "cot")
        vm.applySuggestion("Cotton Yarn")

        #expect(vm.draft.products.first?.name == "Cotton Yarn")
        #expect(vm.inputText.isEmpty) // field cleared, same as a manual send
        #expect(vm.messages.contains { $0.sender == .user && $0.text == "Cotton Yarn" })
        // HSN auto-filled from memory, so the flow advanced past the name ask.
        #expect(vm.draft.products.first?.hsn == "5205")
    }

    @Test func applySuggestionIsIgnoredWhenNotAwaitingAName() {
        let vm = ChatViewModel(memory: makeMemory())
        type(vm, "tax invoice") // document-type question is pending
        vm.applySuggestion("Cotton Yarn")

        #expect(vm.draft.products.isEmpty)
        #expect(!vm.messages.contains { $0.sender == .user && $0.text == "Cotton Yarn" })
    }
}
