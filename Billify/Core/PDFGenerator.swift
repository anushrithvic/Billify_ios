//
//  PDFGenerator.swift
//  Billify
//
//  Ports the ORIGINAL FPDF layout from the Tkinter app's
//  generate_invoice()/generate_credit_note()/generate_delivery_note()
//  functions as closely as possible — same box positions, same borders, same
//  section order — rather than a redesigned layout (spec §50: preserve the
//  existing PDF design; only the input system changes).
//
//  All coordinates below are transcribed directly from the original code's
//  pdf.rect(x, y, w, h) calls, which are in millimetres on an A4 page,
//  matching FPDF('P', 'mm', 'A4'). UIGraphicsPDFRenderer uses the same
//  top-left-origin, y-down coordinate convention FPDF does, so no axis flip
//  is needed — coordinates convert 1:1 via a mm-to-points scale factor.
//
//  Unlike FPDF's flowing cursor (which let text drift past box borders in
//  the original app), every text run here is placed *inside* the box that
//  contains it: labels/values are inset from the border, table cells line up
//  with the drawn columns, and money values right-align to their column's
//  inner edge. Long values wrap instead of spilling over the next box.
//

import UIKit

enum PDFGenerator {

    // MARK: - Page geometry

    private static let mmToPt: CGFloat = 2.834645669
    private static let pageWidthMM: CGFloat = 210
    private static let pageHeightMM: CGFloat = 297
    private static var pageWidth: CGFloat { pageWidthMM * mmToPt }
    private static var pageHeight: CGFloat { pageHeightMM * mmToPt }

    private static func pt(_ mm: CGFloat) -> CGFloat { mm * mmToPt }
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: pt(x), y: pt(y), width: pt(w), height: pt(h))
    }

    // MARK: - Fonts (matching the original's Arial/Helvetica bold sizes)

    private static let titleFont = UIFont.boldSystemFont(ofSize: 15)
    private static let companyNameFont = UIFont.boldSystemFont(ofSize: 25) // original used Arial bold 25
    private static let companyAddressFont = UIFont.boldSystemFont(ofSize: 12)
    private static let sectionHeaderFont = UIFont.boldSystemFont(ofSize: 12)
    private static let labelFont = UIFont.boldSystemFont(ofSize: 10)
    private static let bodyFont = UIFont.boldSystemFont(ofSize: 10)
    private static let smallBodyFont = UIFont.systemFont(ofSize: 9)
    private static let tableHeaderFont = UIFont.boldSystemFont(ofSize: 10)
    private static let tableBodyFont = UIFont.boldSystemFont(ofSize: 10)
    private static let smallFont = UIFont.systemFont(ofSize: 8)
    private static let declarationHeaderFont = UIFont.systemFont(ofSize: 12) // underlined in original

    // MARK: - Entry point

    static func generate(_ data: InvoiceData, company: CompanyInfo = .default) -> (fileName: String, pdfData: Data) {
        let calc = CalculationEngine.calculate(data)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let pdfData = renderer.pdfData { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            cg.setLineWidth(0.6 * mmToPt)
            cg.setStrokeColor(UIColor.black.cgColor)

            drawBorders(for: data.invoiceType, in: cg)
            drawTitle(for: data.invoiceType)
            drawCompanyHeader(company: company)
            drawInvoiceAndTransportMeta(data)
            drawBuyerAndShippingLabels(data)
            drawBuyerAndShippingDetail(data)
            drawProductTableHeader(data)
            drawProductRow(data)
            drawTotalRow(calc)
            drawBankDetails(company: company)
            drawTaxBreakdown(data, calc: calc, in: cg)
            drawAmountInWords(calc)
            drawDeclaration(company: company)
        }

        let safeInvoiceNo = data.invoiceDetails.invoiceNo.isEmpty ? "draft" : data.invoiceDetails.invoiceNo
        return ("invoice_\(safeInvoiceNo).pdf", pdfData)
    }

    // MARK: - Borders (exact rects from the original, converted mm -> pt)

    private static func drawBorders(for type: InvoiceType, in cg: CGContext) {
        let titleBox = type == .deliveryChallan ? rect(75, 5, 60, 10) : rect(80, 5, 50, 10)
        stroke(titleBox, in: cg)

        stroke(rect(5, 15, 200, 50), in: cg)
        stroke(rect(5, 65, 100, 30), in: cg)
        stroke(rect(105, 65, 100, 30), in: cg)
        stroke(rect(5, 95, 100, 10), in: cg)
        stroke(rect(105, 95, 100, 10), in: cg)
        stroke(rect(5, 105, 100, 50), in: cg)
        stroke(rect(105, 105, 100, 50), in: cg)

        for col in tableColumns {
            stroke(rect(col.x, 155, col.w, 10), in: cg)
        }
        for col in tableColumns {
            stroke(rect(col.x, 165, col.w, 30), in: cg)
        }
        for col in tableColumns {
            stroke(rect(col.x, 195, col.w, 8), in: cg)
        }

        stroke(rect(5, 203, 100, 45), in: cg)
        stroke(rect(105, 203, 100, 45), in: cg)
        stroke(rect(5, 248, 200, 10), in: cg)
        stroke(rect(105, 258, 100, 35), in: cg)
        stroke(rect(5, 258, 100, 35), in: cg)

        line(from: (105, 211.75), to: (205, 211.75), in: cg)
        line(from: (105, 220.50), to: (205, 220.50), in: cg)
        line(from: (105, 229.25), to: (205, 229.25), in: cg)
        line(from: (105, 238.00), to: (205, 238.00), in: cg)
        line(from: (165, 203.00), to: (165, 248.00), in: cg)
    }

    private static let tableColumns: [(x: CGFloat, w: CGFloat)] = [
        (5, 10), (15, 65), (80, 25), (105, 20), (125, 20), (145, 20), (165, 40)
    ]

    // MARK: - Title & company header

    private static func drawTitle(for type: InvoiceType) {
        let title: String
        let box: CGRect
        switch type {
        case .taxInvoice: title = "TAX INVOICE"; box = rect(80, 5, 50, 10)
        case .creditNote: title = "CREDIT NOTE"; box = rect(80, 5, 50, 10)
        case .debitNote: title = "DEBIT NOTE"; box = rect(80, 5, 50, 10)
        case .deliveryChallan: title = "DELIVERY CHALLAN"; box = rect(75, 5, 60, 10)
        }
        drawCentered(title, in: box, font: titleFont)
    }

    private static func drawCompanyHeader(company: CompanyInfo) {
        let box = rect(5, 15, 200, 50)
        let contentWidth = box.width - pt(6)
        let centerX = box.minX
        var y: CGFloat = box.minY + pt(4)

        drawText(company.name, at: CGPoint(x: centerX, y: y), width: contentWidth, font: companyNameFont, alignment: .center)
        y += textHeight(company.name, width: contentWidth, font: companyNameFont) + pt(2)

        // Address lines, with the phone glued to the last one exactly like the
        // original: "TAMIL NADU. PH | 9894727918 |" (then GST TIN below).
        var lines = company.addressLines
        if !lines.isEmpty, !lines[lines.count - 1].localizedCaseInsensitiveContains("ph") {
            let last = lines[lines.count - 1]
            let separator = last.hasSuffix(".") || last.hasSuffix("|") ? " " : ". "
            lines[lines.count - 1] = last + separator + "PH | \(company.phone) |"
        }

        let addressFont = companyAddressFont
        for (i, line) in lines.enumerated() {
            let height = textHeight(line, width: contentWidth, font: addressFont)
            drawText(line, at: CGPoint(x: centerX, y: y), width: contentWidth, font: addressFont, alignment: .center)
            y += height
            if i == 0 { y += pt(0.8) } else if i < lines.count - 1 { y += pt(0.5) }
        }

        // Same format as the original PDF: "GST TIN:33AIMPM2628J1Z4".
        drawText("GST TIN:\(company.gstin)", at: CGPoint(x: centerX, y: y), width: contentWidth, font: addressFont, alignment: .center)
    }

    // MARK: - Invoice + transporter meta

    private static func drawInvoiceAndTransportMeta(_ data: InvoiceData) {
        let invoiceLabel: String
        switch data.invoiceType {
        case .creditNote: invoiceLabel = "CREDIT NOTE NO"
        case .debitNote: invoiceLabel = "DEBIT NOTE NO"
        default: invoiceLabel = "INVOICE"
        }

        // Left box (x 5..105): INVOICE / DATE / EWAY BILL NO — three rows.
        var ly: CGFloat = 66.5
        drawLabelColon(invoiceLabel, data.invoiceDetails.invoiceNo, xMM: 8, yMM: ly, labelWidthMM: 37, valueWidthMM: 57)
        ly += 9.5
        drawLabelColon("DATE", data.invoiceDetails.date, xMM: 8, yMM: ly, labelWidthMM: 37, valueWidthMM: 57)
        ly += 9.5
        drawLabelColon("EWAY BILL NO", data.invoiceDetails.ewayBill, xMM: 8, yMM: ly, labelWidthMM: 37, valueWidthMM: 57)

        // Right box (x 105..205): TRANSPORTER / VEHICLE NO / LR NO / GSTIN.
        var ry: CGFloat = 66.5
        drawLabelColon("TRANSPORTER", data.transport.transporter, xMM: 108, yMM: ry, labelWidthMM: 47, valueWidthMM: 47)
        ry += 7.4
        drawLabelColon("VEHICLE NO", data.transport.vehicleNo, xMM: 108, yMM: ry, labelWidthMM: 47, valueWidthMM: 47)
        ry += 7.4
        drawLabelColon("LR NO", data.transport.lrNo, xMM: 108, yMM: ry, labelWidthMM: 47, valueWidthMM: 47)
        ry += 7.4
        drawLabelColon("TRANSPORTER'S GSTIN", data.transport.gstin, xMM: 108, yMM: ry, labelWidthMM: 47, valueWidthMM: 47)
    }

    private static func drawLabelColon(_ label: String, _ value: String, xMM: CGFloat, yMM: CGFloat, labelWidthMM: CGFloat, valueWidthMM: CGFloat) {
        drawText(label, atMM: (xMM, yMM), widthMM: labelWidthMM, font: labelFont)
        drawText(":", atMM: (xMM + labelWidthMM, yMM), widthMM: 3, font: labelFont)
        drawText(value.isEmpty ? "-" : value, atMM: (xMM + labelWidthMM + 3, yMM), widthMM: valueWidthMM, font: smallBodyFont)
    }

    // MARK: - Buyer / shipping

    private static func drawBuyerAndShippingLabels(_ data: InvoiceData) {
        drawText("BUYER ( Bill to: )", atMM: (8, 96.2), widthMM: 92, font: sectionHeaderFont)
        let shippingLabel = data.shippingSameAsBuyer ? "Shipping Address : (Same as Buyer)" : "Shipping Address :"
        drawText(shippingLabel, atMM: (108, 96.2), widthMM: 92, font: sectionHeaderFont)
    }

    private static func drawBuyerAndShippingDetail(_ data: InvoiceData) {
        let shipping = data.effectiveShipping
        let leftXMM: CGFloat = 8
        let rightXMM: CGFloat = 108
        let widthMM: CGFloat = 94

        // Six stacked lines (name, 4 address lines, GSTIN) inside a 50mm box.
        let lines = zipBuyerLines(buyer: data.buyer, shipping: shipping)
        let totalLines = max(lines.left.count, lines.right.count)
        let insetTop: CGFloat = 106.5
        let bottom: CGFloat = 155
        let pitch = min(8.6, (bottom - insetTop) / CGFloat(totalLines))

        for i in 0..<lines.left.count {
            drawText(lines.left[i].0, atMM: (leftXMM, insetTop + pitch * CGFloat(i)),
                    widthMM: widthMM, font: lines.left[i].1)
        }
        for i in 0..<lines.right.count {
            drawText(lines.right[i].0, atMM: (rightXMM, insetTop + pitch * CGFloat(i)),
                    widthMM: widthMM, font: lines.right[i].1)
        }
    }

    private static func zipBuyerLines(buyer: Party, shipping: Party) -> (left: [(String, UIFont)], right: [(String, UIFont)]) {
        // Mirrors the original app: name, up to four address lines, GSTIN.
        // Empty values print as blank lines (the original never showed dashes).
        func stack(_ party: Party) -> [(String, UIFont)] {
            var rows: [(String, UIFont)] = [(party.name, labelFont)]
            for line in party.address where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append((line, smallBodyFont))
            }
            rows.append((party.gstin.isEmpty ? "" : "GSTIN : " + party.gstin, smallBodyFont))
            return rows
        }
        return (stack(buyer), stack(shipping))
    }

    // MARK: - Product table

    private static func drawProductTableHeader(_ data: InvoiceData) {
        // Labels mirror the original (and printed sample): "HSN.CODE", "NO.OF".
        let titles = ["", "PRODUCT", "HSN.CODE", "NO.OF", "NO.OF", "RATE PER", "TOTAL VALUE"]
        let unit = data.products.first?.unit.rawValue ?? "BAGES"
        let subLabels = ["", "", "", unit, "KGS", "KG", ""]

        for (i, col) in tableColumns.enumerated() where !titles[i].isEmpty {
            let alignment: NSTextAlignment = i == 6 ? .right : .left
            drawText(titles[i], atMM: (col.x + 2, 155.7), widthMM: col.w - 4, font: tableHeaderFont, alignment: alignment, maxLines: 1)
            if !subLabels[i].isEmpty {
                drawText(subLabels[i], atMM: (col.x + 2, 160.2), widthMM: col.w - 4, font: smallFont, alignment: alignment, maxLines: 1)
            }
        }
    }

    private static func drawProductRow(_ data: InvoiceData) {
        // First product on the main row band (165..195). Subsequent products
        // stack beneath it, aligned to the same columns.
        var yMM: CGFloat = 166.8
        if let product = data.products.first {
            yMM = drawProductLine(product, index: 1, atY: yMM)
        }

        if data.invoiceType.referencesOriginalInvoice, yMM < 194.5 {
            let ref = "( Original Invoice No. \(data.invoiceDetails.originalInvoiceNo) & Date \(data.invoiceDetails.originalInvoiceDate) )"
            drawText(ref, atMM: (17, yMM), widthMM: 63, font: smallFont, maxLines: 1)
            yMM += 5.8
        }

        for product in data.products.dropFirst() where yMM < 194.5 {
            let name = "   \(product.name)   HSN: \(product.hsn)   \(product.quantity ?? 0) \(product.unit.rawValue)"
            let values = "   \(product.weightKg?.formattedTrim ?? "-") KG   ₹\(product.ratePerKg?.formattedTrim ?? "-")/KG   = ₹\((product.totalValue ?? 0).formattedTrim)"
            drawText(name + values, atMM: (17, yMM), widthMM: 186, font: smallFont, maxLines: 1)
            yMM += 5.8
        }
    }

    /// Draws one product across the seven table columns. Returns the y (mm)
    /// where the next line of content may start.
    @discardableResult
    private static func drawProductLine(_ product: Product, index: Int, atY yMM: CGFloat) -> CGFloat {
        let nameColumn = tableColumns[1]
        let name = product.name.isEmpty ? "-" : product.name
        let hsn = product.hsn.isEmpty ? "-" : product.hsn
        let qty = product.quantity.map { String($0) } ?? "-"
        let weight = product.weightKg?.formattedTrim ?? "-"
        // Printed values are plain digits, exactly like the original PDF.
        let rate = product.ratePerKg.map { $0.formattedTrim } ?? "-"
        let total = product.totalValue?.formattedTrim ?? "-"

        drawText("\(index).", atMM: (tableColumns[0].x + 1.5, yMM), widthMM: tableColumns[0].w - 3, font: tableBodyFont, maxLines: 1)
        // Product name can wrap to a second line within its wide column.
        let nameWidthPt = pt(nameColumn.w - 4)
        let nameHeightPt = min(
            textHeight(name, width: nameWidthPt, font: tableBodyFont),
            tableBodyFont.lineHeight * 2)
        drawText(name, atMM: (nameColumn.x + 2, yMM), widthMM: nameColumn.w - 4, font: tableBodyFont, maxLines: 2)
        drawText(hsn, atMM: (tableColumns[2].x + 2, yMM), widthMM: tableColumns[2].w - 4, font: tableBodyFont, maxLines: 1)
        drawText(qty, atMM: (tableColumns[3].x + 2, yMM), widthMM: tableColumns[3].w - 4, font: tableBodyFont, maxLines: 1)
        drawText(weight, atMM: (tableColumns[4].x + 2, yMM), widthMM: tableColumns[4].w - 4, font: tableBodyFont, maxLines: 1)
        drawText(rate, atMM: (tableColumns[5].x + 2, yMM), widthMM: tableColumns[5].w - 4, font: tableBodyFont, maxLines: 1)
        drawText(total, atMM: (tableColumns[6].x + 2, yMM), widthMM: tableColumns[6].w - 4, font: tableBodyFont, alignment: .right, maxLines: 1)

        return yMM + nameHeightPt / mmToPt + 2.2
    }

    private static func drawTotalRow(_ calc: InvoiceCalculation) {
        let yMM: CGFloat = 195.9
        drawText("TOTAL", atMM: (17, yMM), widthMM: 61, font: tableHeaderFont, maxLines: 1)
        drawText(calc.taxableValue.formattedTrim, atMM: (167, yMM), widthMM: 36, font: tableHeaderFont, alignment: .right, maxLines: 1)
    }

    // MARK: - Bank details & tax panel

    private static func drawBankDetails(company: CompanyInfo) {
        let rows = [
            "COMPANY BANK DETAIL'S:",
            "BANK NAME  : \(company.bankName)",
            "BANK BRANCH: \(company.bankBranch)",
            "ACCOUNT NO : \(company.accountNo)",
            "IFSC CODE  : \(company.ifscCode)"
        ]
        let fonts: [UIFont] = [sectionHeaderFont, bodyFont, bodyFont, bodyFont, bodyFont]
        let startYMM: CGFloat = 205.5
        let pitch: CGFloat = 9.2
        for (i, row) in rows.enumerated() {
            drawText(row, atMM: (8, startYMM + pitch * CGFloat(i)), widthMM: 94, font: fonts[i], maxLines: 1)
        }
    }

    private static func drawTaxBreakdown(_ data: InvoiceData, calc: InvoiceCalculation, in cg: CGContext) {
        let isDeliveryChallan = data.invoiceType == .deliveryChallan
        let halfRate = data.tax.rate / 2.0

        // Row bands in the right box (105..205), split by the lines at 211.75…238.
        let rows: [(label: String, value: String)] = [
            ("AMOUNT BEFORE TAX", calc.taxableValue.formattedTrim),
            ("CGST \(halfRate.formattedTrim)%", isDeliveryChallan || data.tax.type != .state ? "-" : calc.cgst.formattedTrim),
            ("SGST \(halfRate.formattedTrim)%", isDeliveryChallan || data.tax.type != .state ? "-" : calc.sgst.formattedTrim),
            ("IGST \(data.tax.rate.formattedTrim)%", isDeliveryChallan || data.tax.type != .national ? "-" : calc.igst.formattedTrim),
            ("GRAND TOTAL", calc.grandTotal.formattedTrim)
        ]
        let rowTops: [CGFloat] = [203.0, 211.75, 220.5, 229.25, 238.0]
        let rowBottoms: [CGFloat] = [211.75, 220.5, 229.25, 238.0, 248.0]
        let labelWidthMM: CGFloat = 55
        let valueWidthMM: CGFloat = 34

        for (i, row) in rows.enumerated() {
            let midY = rowTops[i] + (rowBottoms[i] - rowTops[i]) / 2
            // Bold font sits slightly low when drawn from its top edge; nudge up
            // by half a line for true vertical centering.
            let yMM = midY - 1.4
            let font: UIFont = i == 4 ? labelFont : smallBodyFont
            drawText(row.label, atMM: (108, yMM), widthMM: labelWidthMM, font: font, maxLines: 1)
            drawText(row.value, atMM: (168, yMM), widthMM: valueWidthMM, font: font, alignment: .right, maxLines: 1)
        }
    }

    private static func drawAmountInWords(_ calc: InvoiceCalculation) {
        drawText("AMOUNT IN WORDS :", atMM: (8, 250.2), widthMM: 40, font: labelFont, maxLines: 1)
        // The original printed the words in bold; long Indian-numbering amounts
        // ("Rupees Ten Crore…") can outgrow one line, so step the size down to 9
        // then 8 pt (still bold) until the whole phrase fits.
        let widthPt = pt(156)
        var font = bodyFont
        while font.pointSize > 7 {
            let textWidth = (calc.amountInWords as NSString).size(withAttributes: [.font: font]).width
            if textWidth <= widthPt { break }
            font = UIFont.boldSystemFont(ofSize: font.pointSize - 1)
        }
        drawText(calc.amountInWords, atMM: (48, 249.2), widthMM: 156, font: font, maxLines: 1)
    }

    private static func drawDeclaration(company: CompanyInfo) {
        let leftXMM: CGFloat = 8
        let rightXMM: CGFloat = 108
        let widthMM: CGFloat = 96

        drawText("Declaration", atMM: (leftXMM, 260.2), widthMM: 60, font: declarationHeaderFont, maxLines: 1)
        // Signatory label sits at the top-left of the right-hand box, matching
        // the original layout ("For ANUSH TRADERS"), not flush to the right edge.
        drawText("For \(company.name)", atMM: (rightXMM, 260.2), widthMM: widthMM, font: labelFont, alignment: .left, maxLines: 1)

        let lines = [
            "We declare that this invoice shows the",
            "actual price of the goods described and",
            "that all particulars are true and correct."
        ]
        var yMM: CGFloat = 269.5
        for line in lines {
            drawText(line, atMM: (leftXMM, yMM), widthMM: 190, font: smallBodyFont, maxLines: 1)
            yMM += 5.6
        }

        yMM += 2.5
        drawText("THIS IS A COMPUTER GENERATED INVOICE", atMM: (leftXMM, yMM), widthMM: 95, font: smallFont, maxLines: 1)
        drawText("Authorised Signatory", atMM: (rightXMM, yMM), widthMM: widthMM, font: smallBodyFont, alignment: .right, maxLines: 1)
    }

    // MARK: - Low-level drawing helpers

    private static func textHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return rect.height
    }

    /// Draws text vertically centered inside a box.
    private static func drawCentered(_ text: String, in box: CGRect, font: UIFont) {
        let height = textHeight(text, width: box.width - 4, font: font)
        let y = box.minY + max(0, (box.height - height) / 2)
        drawText(text, at: CGPoint(x: box.minX, y: y), width: box.width, font: font, alignment: .center, maxLines: 1)
    }

    private static func drawText(
        _ text: String,
        atMM point: (CGFloat, CGFloat),
        widthMM: CGFloat,
        font: UIFont,
        alignment: NSTextAlignment = .left,
        maxLines: Int = 0
    ) {
        drawText(text, at: CGPoint(x: pt(point.0), y: pt(point.1)), width: pt(widthMM), font: font,
                 color: .black, alignment: alignment, maxLines: maxLines)
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        width: CGFloat,
        font: UIFont,
        color: UIColor = .black,
        alignment: NSTextAlignment = .left,
        maxLines: Int = 0
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        // Height must fit the actual glyphs: the old fixed 20 pt frame clipped
        // larger text (e.g. the 25 pt company name lost its lower half).
        let height: CGFloat = maxLines > 0
            ? font.lineHeight * CGFloat(maxLines)
            : textHeight(text, width: max(width, 1), font: font)
        let drawRect = CGRect(x: point.x, y: point.y, width: max(width, 1), height: height)
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
    }

    private static func stroke(_ rect: CGRect, in cg: CGContext) {
        cg.stroke(rect)
    }

    private static func line(from: (CGFloat, CGFloat), to: (CGFloat, CGFloat), in cg: CGContext) {
        cg.move(to: CGPoint(x: pt(from.0), y: pt(from.1)))
        cg.addLine(to: CGPoint(x: pt(to.0), y: pt(to.1)))
        cg.strokePath()
    }
}
