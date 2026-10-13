//
//  ChatView.swift
//  Billify
//
//  The guided document builder. Pushed from the home screen with a chosen
//  document type (Tax Invoice / Credit Note / Debit Note / Delivery Challan);
//  the conversation collects whatever fields are still missing.
//

import SwiftUI
import PhotosUI

struct ChatView: View {
    /// Document type this flow was started with (nil = let the chat decide).
    var initialType: InvoiceType? = nil

    @StateObject private var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool

    // Photo input (Method 1, spec §29)
    @State private var showLibraryPicker = false
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?

    init(initialType: InvoiceType? = nil) {
        self.initialType = initialType
        _viewModel = StateObject(wrappedValue: ChatViewModel(initialType: initialType))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().overlay(Color.green.opacity(0.15))
            nameSuggestionChips
            composer
        }
        .background(Theme.background)
        .navigationTitle(initialType?.rawValue ?? "🧾 Billify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message, draft: viewModel.draft)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                guard let last = viewModel.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Live autocomplete (saved buyer/product names) shown as a horizontal
    /// row of tappable chips just above the input bar — only while the chat is
    /// actually waiting on a name field and something is typed. Tapping one
    /// fills the field and sends immediately. The row collapses away entirely
    /// (no reserved space) when there's nothing to offer.
    @ViewBuilder
    private var nameSuggestionChips: some View {
        if !viewModel.nameSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.nameSuggestions, id: \.self) { name in
                        Button {
                            viewModel.applySuggestion(name)
                        } label: {
                            Label {
                                Text(name).lineLimit(1)
                            } icon: {
                                Image(systemName: viewModel.isAwaitingBuyerName
                                      ? "person.crop.circle.fill" : "shippingbox.fill")
                            }
                            .font(.system(size: 12))
                        }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.chip(false)))
                        .overlay(Capsule().strokeBorder(Theme.emerald.opacity(0.35), lineWidth: 1))
                        .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("nameSuggestions")
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            photoInputMenu

            TextField(initialType == nil ? "Type or paste details..." : "Type or paste \(initialType!.rawValue) details...",
                      text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.chip(false)))
                .focused($inputFocused)
                .lineLimit(1...5)
                .foregroundStyle(Theme.ink)
                .accessibilityIdentifier("composerField")

            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.emerald)
            }
            .accessibilityIdentifier("sendButton")
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    /// Paperclip → photo of the invoice to OCR (spec §29 Method 1). The camera
    /// entry only appears when the hardware/simulator actually has one; the
    /// library path uses SwiftUI's PhotosPicker (no permission prompt needed).
    private var photoInputMenu: some View {
        Menu {
            Button {
                showLibraryPicker = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 18))
                .foregroundStyle(Theme.inkSoft)
        }
        .accessibilityIdentifier("photoButton")
        .photosPicker(isPresented: $showLibraryPicker, selection: $pickerItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                viewModel.processPhoto(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.processPhoto(image)
                } else {
                    viewModel.photoFailedToLoad()
                }
                pickerItem = nil
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView()
    }
}
