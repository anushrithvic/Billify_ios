//
//  MemoryTests.swift
//  BillifyTests
//
//  Covers Billify's product/buyer memory: persistence across launches,
//  fuzzy name matching, merge-on-upsert, and the chat auto-fill behavior
//  (no re-asking for known HSN codes, GSTINs and addresses).
//

import Testing
import Foundation
@testable import Billify

private func makeSuite() -> UserDefaults {
    UserDefaults(suiteName: "memory-tests-\(UUID().uuidString)")!
}

@MainActor
struct MemoryStoreTests {

    @Test func productLearnedOnceIsPersisted() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        store.remember(productName: "Cotton Yarn", hsn: "5205")

        // A fresh store over the same defaults == a fresh app launch.
        let reloaded = MemoryStore(defaults: suite)
        #expect(reloaded.hsn(forProductNamed: "cotton yarn") == "5205")
    }

    @Test func upsertKeepsSingleEntry() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        store.remember(productName: "Cotton Yarn", hsn: "5205")
        store.remember(productName: "Cotton Yarn", hsn: "5201")
        #expect(store.products.count == 1)
        #expect(store.hsn(forProductNamed: "cotton yarn") == "5201")
    }

    @Test func productLookupIsFuzzy() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        store.remember(productName: "cotton yarn", hsn: "5205")
        #expect(store.hsn(forProductNamed: "Combed Cotton Yarn") == "5205")
        #expect(store.hsn(forProductNamed: "cotton yarn 40s") == "5205")
        #expect(store.hsn(forProductNamed: "sugar") == nil)
    }

    @Test func buyerMergesPartialRecords() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        var withAddress = Party(name: "SRI KUMARAN MILLS")
        withAddress.address = ["SF NO 114/2, PAPPAMPALAYAM", "TIRUPUR - 641604", "TAMIL NADU", ""]
        store.remember(buyer: withAddress)

        var withGstin = Party(name: "sri kumaran mills")
        withGstin.gstin = "33AABCT1234F1Z5"
        store.remember(buyer: withGstin)

        #expect(store.buyers.count == 1)
        let known = store.buyer(named: "SRI KUMARAN MILLS")
        #expect(known?.gstin == "33AABCT1234F1Z5")
        #expect(known?.address[1].contains("TIRUPUR") == true)
    }

    @Test func buyerNameWithCompanySuffixStillMatches() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        store.remember(buyer: Party(name: "Sri Kumaran Mills", gstin: "33AABCT1234F1Z5", address: ["Tirupur"]))
        let known = store.buyer(named: "Sri Kumaran Mills Pvt Ltd")
        #expect(known?.gstin == "33AABCT1234F1Z5")
    }

    @Test func learnFromInvoiceSweepsProductsAndBuyer() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        var data = InvoiceData()
        var product = Product()
        product.name = "Cotton Waste"
        product.hsn = "5202"
        data.products = [product]
        data.buyer.name = "SRI KUMARAN MILLS"
        data.buyer.gstin = "33AABCT1234F1Z5"
        store.learn(from: data)
        #expect(store.hsn(forProductNamed: "cotton waste") == "5202")
        #expect(store.buyer(named: "SRI KUMARAN MILLS") != nil)
    }
}

@MainActor
struct ChatMemoryFlowTests {

    private func makeViewModel(prefillProduct: Bool = false, prefillBuyer: Bool = false) -> (ChatViewModel, MemoryStore) {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        if prefillProduct {
            store.remember(productName: "Cotton Yarn", hsn: "5205")
        }
        if prefillBuyer {
            var buyer = Party(name: "SRI KUMARAN MILLS")
            buyer.gstin = "33AABCT1234F1Z5"
            buyer.address = ["SF NO 114/2, PAPPAMPALAYAM", "TIRUPUR - 641604", "TAMIL NADU", ""]
            store.remember(buyer: buyer)
        }
        return (ChatViewModel(memory: store), store)
    }

    private func say(_ vm: ChatViewModel, _ text: String) {
        vm.inputText = text
        vm.send()
    }

    private func lastMessage(_ vm: ChatViewModel) -> String {
        vm.messages.last?.text ?? ""
    }

    @Test func knownProductSkipsHsnQuestion() {
        let (vm, _) = makeViewModel(prefillProduct: true)
        say(vm, "create a tax invoice")
        say(vm, "cotton yarn")

        #expect(vm.draft.products.first?.name == "cotton yarn")
        #expect(vm.draft.products.first?.hsn == "5205")
        #expect(vm.messages.contains { $0.text.contains("set HSN **5205**") })
        // Next question is quantity, not HSN.
        #expect(lastMessage(vm).contains("How many"))
        #expect(!lastMessage(vm).contains("HSN"))
    }

    @Test func newProductIsLearnedAndRememberedNextTime() {
        let suite = makeSuite()
        let store = MemoryStore(defaults: suite)
        let vm = ChatViewModel(memory: store)

        say(vm, "create a tax invoice")
        say(vm, "cotton waste")        // unknown → asks for HSN
        #expect(lastMessage(vm).contains("HSN"))
        say(vm, "5202")                // answered, learned
        #expect(store.hsn(forProductNamed: "cotton waste") == "5202")

        // A second chat session on the same defaults auto-fills now.
        let vm2 = ChatViewModel(memory: MemoryStore(defaults: suite))
        say(vm2, "create a tax invoice")
        say(vm2, "cotton waste")
        #expect(vm2.draft.products.first?.hsn == "5202")
        #expect(vm2.messages.contains { $0.text.contains("set HSN **5202**") })
    }

    @Test func knownBuyerSkipsGstinAndAddressQuestions() {
        let (vm, _) = makeViewModel(prefillProduct: true, prefillBuyer: true)
        say(vm, "create a tax invoice")
        // Fill a product so the flow reaches the buyer questions.
        say(vm, "cotton yarn")
        say(vm, "100 bales")
        say(vm, "4000 kgs")
        say(vm, "150")
        #expect(lastMessage(vm).contains("buyer's name"))

        say(vm, "sri kumaran mills")
        #expect(vm.draft.buyer.name.lowercased().contains("sri kumaran"))
        #expect(vm.draft.buyer.gstin == "33AABCT1234F1Z5")
        #expect(vm.draft.buyer.address[0].contains("114/2"))
        // The very next question must be the invoice number, not GSTIN/address.
        #expect(lastMessage(vm).contains("invoice number"))
    }

    @Test func buyerEnteredFromScratchIsLearned() {
        let (vm, store) = makeViewModel(prefillProduct: true)
        say(vm, "create a tax invoice")
        say(vm, "cotton yarn")
        say(vm, "100 bales")
        say(vm, "4000 kgs")
        say(vm, "150")
        say(vm, "ravi textiles")
        say(vm, "33AIMPM2628J1Z4")
        say(vm, "SF 12, TIRUPUR")
        #expect(store.buyer(named: "ravi textiles")?.gstin == "33AIMPM2628J1Z4")
    }
}
