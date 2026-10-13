//
//  BillifyApp.swift
//  Billify
//
//  Billify 2.0 — a conversational iOS invoice assistant.
//  Original desktop invoice logic being preserved and refactored;
//  see project spec §74 ("do not destroy the existing Billify logic").
//
//  The app opens on a home launcher (not directly into chat): green cards for
//  each document type, saved invoices, and the Ask Billify assistant.
//

import SwiftUI

@main
struct BillifyApp: App {
    /// One shared history store for the whole app: drafts save into it when a
    /// PDF is generated, the invoices list reads it, and Ask Billify answers
    /// questions from it.
    @StateObject private var history = InvoiceHistoryStore.shared

    /// One shared catalog of known products (name → HSN) and buyers (name →
    /// GSTIN + address), so the Products & Buyers screen and every chat
    /// session stay in sync live, not just after an app relaunch.
    @StateObject private var memory = MemoryStore.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(history)
                .environmentObject(memory)
                .tint(Theme.accent)
        }
    }
}
