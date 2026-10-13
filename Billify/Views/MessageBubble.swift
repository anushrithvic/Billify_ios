//
//  MessageBubble.swift
//  Billify
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let draft: InvoiceData

    /// Upper bound for chat bubbles. Long pasted sentences made the previous
    /// HStack-with-Spacer layout negotiate an *unbounded* width for the
    /// wrapping Text, which sent SwiftUI into an infinite layout loop (the
    /// main thread spun in CA::Layer::layout_and_display_if_needed forever and
    /// the app froze). Capping the width makes the wrap decision stable.
    private var bubbleMaxWidth: CGFloat {
        message.sender == .user ? 300 : 330
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.sender == .billify { avatar }

            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 8) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleColor)
                    .foregroundStyle(bubbleText)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(message.sender == .billify ? Color.green.opacity(0.12) : .clear, lineWidth: 1))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: bubbleMaxWidth, alignment: message.sender == .user ? .trailing : .leading)

                if message.attachment == .invoicePreview {
                    InvoicePreviewCard(data: draft)
                        .frame(maxWidth: bubbleMaxWidth + 10)
                }

                if case let .image(photo) = message.attachment {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 200, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: bubbleMaxWidth + 10, alignment: message.sender == .user ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    private var bubbleColor: Color {
        message.sender == .user ? Theme.emerald : Theme.surface
    }

    private var bubbleText: Color {
        message.sender == .user ? .white : Theme.ink
    }

    @ViewBuilder
    private var avatar: some View {
        if message.sender == .billify {
            Image(systemName: "leaf.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(LinearGradient(colors: [Theme.forest, Theme.emerald],
                                                         startPoint: .top, endPoint: .bottom)))
        }
    }
}