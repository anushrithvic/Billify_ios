import SwiftUI

/// Shows a final editable review of the invoice BEFORE the PDF is made, then
/// generates on confirm. Bulk extraction is never perfect, so this is the
/// safety net: every field lands here for a human glance (and quick fix)
/// before anything reaches a PDF.
struct GeneratedInvoiceView: View {
    let data: InvoiceData

    /// `.create` (default): coming from the drafting flow — review first, then
    /// save/refresh the history entry. `.reopen`: viewing a saved invoice
    /// again — skip review, never create a duplicate or bump its position.
    var recordMode: RecordMode = .create

    enum RecordMode {
        case create, reopen
    }

    enum Phase {
        case review, pdf
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var history: InvoiceHistoryStore
    @State private var phase: Phase
    @State private var editable: InvoiceData
    @State private var pdfData: Data?
    @State private var fileName: String = "invoice.pdf"
    @State private var isShowingShareSheet = false
    @State private var tempFileURL: URL?
    @State private var didRecord = false

    init(data: InvoiceData, recordMode: RecordMode = .create) {
        self.data = data
        self.recordMode = recordMode
        var initial = data
        // The date always shows something sensible here — today, by default —
        // rather than an empty field; this is the one place it's meant to be
        // changed, so defaulting it here (never re-asking in chat) is enough.
        if recordMode == .create && initial.invoiceDetails.date.isEmpty {
            initial.invoiceDetails.date = BulkTextExtractor.todayString()
        }
        _editable = State(initialValue: initial)
        _phase = State(initialValue: recordMode == .reopen ? .pdf : .review)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .review:
                    reviewForm
                case .pdf:
                    if let pdfData {
                        PDFPreviewView(data: pdfData)
                    } else {
                        ProgressView("Generating invoice…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle(phase == .review ? "Review before generating" : fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .pdf {
                        Button {
                            isShowingShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(pdfData == nil)
                    }
                }
            }
            .sheet(isPresented: $isShowingShareSheet) {
                if let tempFileURL {
                    ShareSheet(items: [tempFileURL])
                }
            }
            .onAppear {
                if phase == .pdf { generate() }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Review phase

    private var reviewForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                buyerCard
                productsCard
                documentCard
                transportCard
                if editable.invoiceType != .deliveryChallan {
                    totalsCard
                }

                if !editable.missingRequiredFields.isEmpty {
                    Label("Still missing: \(editable.missingRequiredFields.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    phase = .pdf
                    generate()
                } label: {
                    Label(editable.missingRequiredFields.isEmpty
                          ? "Confirm & Generate PDF"
                          : "Generate anyway",
                          systemImage: "doc.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.emerald)
            }
            .padding(16)
        }
        .background(Theme.background)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editable.invoiceType.rawValue.uppercased())
                    .font(.headline)
                    .foregroundStyle(Theme.emerald)
                    .tracking(1)
                Spacer()
                if editable.invoiceType != .deliveryChallan {
                    Picker("Tax", selection: $editable.tax.type) {
                        ForEach(TaxType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                }
            }
            Text("Check every field below — tap any value to fix it. Nothing is generated until you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var buyerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Buyer", systemImage: "person.crop.rectangle")
            field("Buyer name", $editable.buyer.name, prompt: "e.g. Sri Kumaran Mills")
            field("GSTIN", $editable.buyer.gstin, prompt: "e.g. 33AIMPM2628J1Z4")
            ForEach(0..<4, id: \.self) { i in
                field("Address line \(i + 1)", $editable.buyer.address[i], prompt: "Address line \(i + 1)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var productsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Products", systemImage: "shippingbox")
            ForEach(editable.products.indices, id: \.self) { i in
                productRow(i)
            }
            Button {
                editable.products.append(Product())
            } label: {
                Label("Add product", systemImage: "plus.circle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.emerald)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func productRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Product \(i + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if editable.products.count > 1 {
                    Button(role: .destructive) {
                        editable.products.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            field("Product name", $editable.products[i].name, prompt: "e.g. cotton lint")
            HStack(spacing: 10) {
                field("HSN code", $editable.products[i].hsn, prompt: "5205")
                Picker("Unit", selection: $editable.products[i].unit) {
                    ForEach(ProductUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            HStack(spacing: 10) {
                field("Quantity", numericBinding($editable.products[i].quantity), prompt: "e.g. 30")
                field("Weight (KG)", numericBinding($editable.products[i].weightKg), prompt: "e.g. 4000")
            }
            field("Rate per KG (₹)", numericBinding($editable.products[i].ratePerKg), prompt: "e.g. 150")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.chip(false)))
    }

    private var documentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Document", systemImage: "doc.text")
            HStack(spacing: 10) {
                field("Invoice / Document No.", $editable.invoiceDetails.invoiceNo, prompt: "e.g. 23")
                field("Date", $editable.invoiceDetails.date, prompt: "dd-MM-yyyy")
            }
            field("E-way bill", $editable.invoiceDetails.ewayBill, prompt: "Optional — 12 digits")
            if editable.invoiceType.referencesOriginalInvoice {
                HStack(spacing: 10) {
                    field("Original invoice no.", $editable.invoiceDetails.originalInvoiceNo, prompt: "e.g. 17")
                    field("Original date", $editable.invoiceDetails.originalInvoiceDate, prompt: "dd-MM-yyyy")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Transport (optional)", systemImage: "truck.box")
            HStack(spacing: 10) {
                field("Vehicle no.", $editable.transport.vehicleNo, prompt: "TN38AB1234")
                field("Transporter", $editable.transport.transporter, prompt: "Name")
            }
            HStack(spacing: 10) {
                field("LR no.", $editable.transport.lrNo, prompt: "Optional")
                field("Transporter GSTIN", $editable.transport.gstin, prompt: "Optional")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var totalsCard: some View {
        let calc = CalculationEngine.calculate(editable)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Totals", systemImage: "sum")
            row("Taxable value", "₹\(calc.taxableValue.formattedTrim)")
            if editable.tax.type == .state {
                row("CGST", "₹\(calc.cgst.formattedTrim)")
                row("SGST", "₹\(calc.sgst.formattedTrim)")
            } else {
                row("IGST", "₹\(calc.igst.formattedTrim)")
            }
            Divider().overlay(Color.green.opacity(0.2))
            HStack {
                Text("Grand total").font(.subheadline.bold())
                Spacer()
                Text("₹\(calc.grandTotal.formattedTrim)").font(.subheadline.bold())
                    .foregroundStyle(Theme.emerald)
            }
            if !calc.amountInWords.isEmpty {
                Text(calc.amountInWords)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Small building blocks

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.bold())
            .foregroundStyle(Theme.ink)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.15), lineWidth: 1)
            )
    }

    private func field(_ label: String, _ value: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            TextField(prompt, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .autocorrectionDisabled()
        }
    }

    private func numericBinding(_ value: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map { $0.formattedTrim } ?? "" },
            set: { value.wrappedValue = Double($0) }
        )
    }

    private func numericBinding(_ value: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0) }
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.bold())
        }
    }

    // MARK: - PDF generation

    private func generate() {
        guard pdfData == nil else { return }
        let result = PDFGenerator.generate(editable)
        pdfData = result.pdfData
        fileName = result.fileName

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(result.fileName)
        try? result.pdfData.write(to: url)
        tempFileURL = url

        // Save into local history once per presentation. A document being
        // drafted (create) refreshes its entry; a reopen never duplicates.
        guard !didRecord else { return }
        didRecord = true
        let fingerprint = InvoiceHistoryStore.fingerprint(of: editable)
        let alreadySaved = history.entries.contains { $0.id == fingerprint }
        if recordMode == .create || !alreadySaved {
            history.record(editable)
        }
    }
}