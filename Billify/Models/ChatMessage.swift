//
//  ChatMessage.swift
//  Billify
//

import Foundation
import UIKit

enum ChatSender: Equatable {
    case user
    case billify
}

/// Optional inline UI billify can attach to a message (e.g. quick-reply chips
/// for tax type, or the photo the user just attached for OCR).
enum ChatAttachment {
    case none
    case quickReplies([String])
    case invoicePreview            // renders a compact InvoicePreviewView inline
    case image(UIImage)            // the user's photo, shown as a thumbnail
}

extension ChatAttachment: Equatable {
    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.invoicePreview, .invoicePreview), (.image, .image):
            return true
        case let (.quickReplies(l), .quickReplies(r)):
            return l == r
        default:
            return false
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let sender: ChatSender
    var text: String
    var attachment: ChatAttachment = .none
    let timestamp: Date = Date()
}
