//
//  Party.swift
//  Billify
//
//  Buyer and Shipping share an identical shape in the original app
//  (name + GSTIN + 4 address lines, spec §6–7), so they're modeled once here.
//

import Foundation

struct Party: Codable, Equatable {
    var name: String = ""
    var gstin: String = ""
    var address: [String] = ["", "", "", ""]   // Address_1...Address_4

    var addressJoined: String {
        address.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: ", ")
    }

    var isComplete: Bool {
        !name.isEmpty && !gstin.isEmpty && !address[0].isEmpty
    }
}

struct Transport: Codable, Equatable {
    var transporter: String = ""
    var vehicleNo: String = ""
    var lrNo: String = ""
    var gstin: String = ""

    /// All transport fields are optional (spec §41), so nothing is "required" here.
    var isEmpty: Bool {
        transporter.isEmpty && vehicleNo.isEmpty && lrNo.isEmpty && gstin.isEmpty
    }
}
