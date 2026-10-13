//
//  InvoicesView.swift
//  Billify
//
//  "Generate invoices" — every document the user has generated, newest first.
//  Tapping a row re-renders the PDF from its saved data (share / print from
//  there); swiping removes the record.
//

import SwiftUI

struct InvoicesView: View {
    @EnvironmentObject private var history: InvoiceHistoryStore
    @State private var selected: HistoryEntry?

    var body: some View {
        Group {
            if history.entries.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(history.entries) { entry in
                            row(entry)
                                .listRowBackground(Theme.surface)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { history.remove(entry) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("\(history.entries.count) saved document\(history.entries.count == 1 ? "" : "s")")
                            .textCase(.uppercase)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("Generate invoices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .sheet(item: $selected) { entry in
            GeneratedInvoiceView(data: entry.data, recordMode: .reopen)
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            selected = entry
        } label: {
            HStack(spacing: 14) {
                typeBadge(entry.invoiceType)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.buyerName.isEmpty ? "No buyer" : entry.buyerName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.invoiceNo.isEmpty ? "—" : "#\(entry.invoiceNo)")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.emerald)
                    }
                    HStack(spacing: 6) {
                        Text(entry.dateLabel.isEmpty ? "no date" : entry.dateLabel)
                        Text("·")
                        Text(entry.invoiceType.rawValue)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                }
                VStack(alignment: .trailing, spacing: 3) {
                    Text("₹\(inr(entry.total))")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text(entry.generatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func typeBadge(_ type: InvoiceType) -> some View {
        let icon: String
        switch type {
        case .taxInvoice: icon = "doc.text.fill"
        case .creditNote: icon = "arrow.uturn.backward.doc.fill"
        case .debitNote: icon = "doc.badge.plus"
        case .deliveryChallan: icon = "shippingbox.fill"
        }
        let tone: Theme.CardTone
        switch type {
        case .taxInvoice: tone = .tax
        case .creditNote: tone = .credit
        case .debitNote: tone = .debit
        case .deliveryChallan: tone = .delivery
        }
        return Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardGradient(tone)))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44))
                .foregroundStyle(Theme.emerald.opacity(0.7))
            Text("No invoices yet")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text("Every invoice you generate from the create cards\nwill be saved here and can be reopened as a PDF.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    private func inr(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = value == value.rounded() ? 0 : 2
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
