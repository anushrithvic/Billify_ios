//
//  HomeView.swift
//  Billify
//
//  The app's landing screen: instead of dropping straight into a chat, Billify
//  opens on a launcher of green cards — create a Tax Invoice / Credit Note /
//  Debit Note / Delivery Challan, browse saved invoices, or ask questions
//  about past billing.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var history: InvoiceHistoryStore

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    createSection
                    toolsSection
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Billify")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Invoice studio")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.mint.opacity(0.9))
                }
                Spacer()
                Text("GST ready")
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.deepGreen)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.cream))
            }

            Text("Welcome back, \(CompanyInfo.default.name.components(separatedBy: " ").first ?? "")")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("What are we making today?")
                .font(.system(size: 14))
                .foregroundStyle(Theme.mint.opacity(0.85))

            statsRow
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.heroGradient)
        )
        .shadow(color: Theme.deepGreen.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat(history.entries.count, "Documents", "doc.on.doc")
            divider
            stat(totalBilled, "Total billed", "indianrupeesign.circle")
            divider
            stat(thisMonthCount, "This month", "calendar")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(Capsule().fill(.white.opacity(0.10)))
    }

    private func stat(_ value: Int, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.mint.opacity(0.9))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text(label).font(.system(size: 9.5)).foregroundStyle(Theme.mint.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 26)
    }

    private var totalBilled: Int {
        history.entries.reduce(0) { $0 + Int($1.total.rounded()) }
    }

    private var thisMonthCount: Int {
        let cal = Calendar.current
        return history.entries.filter {
            cal.isDate($0.generatedAt, equalTo: Date(), toGranularity: .month)
        }.count
    }

    // MARK: - Create cards

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Create a document", "Choose how you want to bill")
            LazyVGrid(columns: columns, spacing: 14) {
                NavigationLink { ChatView(initialType: .taxInvoice) } label: {
                    createCard(icon: "doc.text.fill", title: "Tax Invoice",
                               subtitle: "CGST / SGST or IGST", tone: .tax)
                }
                NavigationLink { ChatView(initialType: .creditNote) } label: {
                    createCard(icon: "arrow.uturn.backward.doc.fill", title: "Credit Note",
                               subtitle: "Reduce a previous bill", tone: .credit)
                }
                NavigationLink { ChatView(initialType: .debitNote) } label: {
                    createCard(icon: "doc.badge.plus", title: "Debit Note",
                               subtitle: "Add a charge to a bill", tone: .debit)
                }
                NavigationLink { ChatView(initialType: .deliveryChallan) } label: {
                    createCard(icon: "shippingbox.fill", title: "Delivery Challan",
                               subtitle: "Dispatch goods, no tax", tone: .delivery)
                }
            }
        }
    }

    private func createCard(icon: String, title: String, subtitle: String, tone: Theme.CardTone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 15.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Theme.cardGradient(tone)))
        .shadow(color: Theme.deepGreen.opacity(0.22), radius: 8, x: 0, y: 4)
        .buttonStyle(.plain)
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your invoices", "Saved on this device")
            VStack(spacing: 12) {
                NavigationLink { InvoicesView() } label: {
                    toolCard(icon: "clock.arrow.circlepath", tint: Theme.forest,
                             title: "Generate invoices",
                             subtitle: history.entries.isEmpty
                                ? "See and reopen every invoice you've made"
                                : "\(history.entries.count) saved · open, view or share the PDF",
                             chevron: true)
                }
                NavigationLink { QAView() } label: {
                    toolCard(icon: "sparkles", tint: Theme.deepGreen,
                             title: "Ask Billify",
                             subtitle: "Chat about past invoices, customers and GST doubts",
                             chevron: true)
                }
                NavigationLink { CatalogView() } label: {
                    toolCard(icon: "tray.full.fill", tint: Theme.pine,
                             title: "Products & Buyers",
                             subtitle: "Save HSN codes and buyer GST/address — reuse them on every invoice",
                             chevron: true)
                }
            }
        }
    }

    private func toolCard(icon: String, tint: Color, title: String, subtitle: String, chevron: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.75)],
                                                         startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft.opacity(0.6))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.green.opacity(0.10), lineWidth: 1))
        .shadow(color: Color.green.opacity(0.08), radius: 6, x: 0, y: 2)
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private var footer: some View {
        Text("Data stays on this device · \(CompanyInfo.default.gstin)")
            .font(.system(size: 11))
            .foregroundStyle(Theme.inkSoft.opacity(0.8))
            .frame(maxWidth: .infinity)
    }
}

#Preview {
    HomeView()
        .environmentObject(InvoiceHistoryStore(directory: FileManager.default.temporaryDirectory))
}
