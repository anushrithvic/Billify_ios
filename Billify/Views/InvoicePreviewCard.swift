import SwiftUI

struct InvoicePreviewCard: View {
    let data: InvoiceData
    @State private var isShowingGenerated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(data.invoiceType.rawValue.uppercased())
                .font(.caption.bold())
                .foregroundStyle(Theme.emerald)
                .tracking(1.2)

            row("Invoice No", data.invoiceDetails.invoiceNo)
            row("Date", data.invoiceDetails.date)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Buyer").font(.caption.bold()).foregroundStyle(.secondary)
                Text(data.buyer.name).font(.subheadline.bold())
                if !data.buyer.gstin.isEmpty {
                    Text("GSTIN: \(data.buyer.gstin)").font(.caption)
                }
                if !data.buyer.addressJoined.isEmpty {
                    Text(data.buyer.addressJoined).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !data.products.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Products").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(data.products) { product in
                        Text(product.summary).font(.caption)
                    }
                }
            }

            if data.invoiceType != .deliveryChallan {
                Divider()
                let calc = CalculationEngine.calculate(data)
                row("Taxable Value", currency(calc.taxableValue))
                if data.tax.type == .state {
                    row("CGST", currency(calc.cgst))
                    row("SGST", currency(calc.sgst))
                } else {
                    row("IGST", currency(calc.igst))
                }
                HStack {
                    Text("Grand Total").font(.caption.bold())
                    Spacer()
                    Text(currency(calc.grandTotal)).font(.subheadline.bold())
                }
                if !calc.amountInWords.isEmpty {
                    Text(calc.amountInWords)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            if !data.missingRequiredFields.isEmpty {
                Divider()
                Label("Missing: \(data.missingRequiredFields.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Divider()
                Button {
                    isShowingGenerated = true
                } label: {
                    Label("Generate PDF", systemImage: "doc.badge.plus")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.green.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: 320, alignment: .leading)
        .sheet(isPresented: $isShowingGenerated) {
            GeneratedInvoiceView(data: data)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).font(.caption.bold())
        }
    }

    private func currency(_ value: Double) -> String {
        "₹" + value.formattedTrim
    }
}
