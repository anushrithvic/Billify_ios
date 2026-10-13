import Foundation

struct CompanyInfo {
    var name: String
    var addressLines: [String]
    var phone: String
    var gstin: String

    var bankName: String
    var bankBranch: String
    var accountNo: String
    var ifscCode: String

    static let `default` = CompanyInfo(
        name: "ANUSH TRADERS",
        addressLines: [
            "6/24-A, DEVANGAPURAM, THERAMPALAYAM(PO)",
            "POGALUR VIA, METTUPALAYAM, COIMBATORE-641697",
            "TAMIL NADU"
        ],
        phone: "9894727918",
        gstin: "33AIMPM2628J1Z4",
        bankName: "STATE BANK OF INDIA",
        bankBranch: "ANNUR",
        accountNo: "37762446444",
        ifscCode: "SBIN0015218"
    )
}
