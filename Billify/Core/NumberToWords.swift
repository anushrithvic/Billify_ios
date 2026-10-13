//
//  NumberToWords.swift
//  Billify
//
//  Indian numbering system (Thousand/Lakh/Crore) — retained from original app.
//

import Foundation

enum NumberToWords {

    private static let ones = [
        "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine",
        "Ten", "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen",
        "Seventeen", "Eighteen", "Nineteen"
    ]

    private static let tens = [
        "", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"
    ]

    static func convert(_ number: Int) -> String {
        guard number > 0 else { return "Rupees Zero Only" }

        var n = number
        var parts: [String] = []

        let crore = n / 10_000_000
        n %= 10_000_000
        let lakh = n / 100_000
        n %= 100_000
        let thousand = n / 1_000
        n %= 1_000
        let hundred = n / 100
        n %= 100
        let remainder = n

        if crore > 0 { parts.append(twoDigitGroup(crore) + " Crore") }
        if lakh > 0 { parts.append(twoDigitGroup(lakh) + " Lakh") }
        if thousand > 0 { parts.append(twoDigitGroup(thousand) + " Thousand") }
        if hundred > 0 { parts.append(ones[hundred] + " Hundred") }
        if remainder > 0 {
            if !parts.isEmpty { parts.append("And") }
            parts.append(twoDigitGroup(remainder))
        }

        return "Rupees " + parts.joined(separator: " ") + " Only"
    }

    private static func twoDigitGroup(_ value: Int) -> String {
        if value < 20 {
            return ones[value]
        }
        let ten = value / 10
        let one = value % 10
        return one == 0 ? tens[ten] : "\(tens[ten]) \(ones[one])"
    }
}
