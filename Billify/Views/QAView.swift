//
//  QAView.swift
//  Billify
//
//  "Ask Billify" — a lightweight chat over saved invoices: totals, counts,
//  customers, specific documents, plus concept explanations (GSTIN, HSN,
//  e-way bill, credit vs debit notes).
//

import SwiftUI

struct QAView: View {
    @StateObject private var viewModel: QAViewModel
    @FocusState private var inputFocused: Bool

    init() {
        // The QA assistant reads the same shared history the app saves into.
        _viewModel = StateObject(wrappedValue: QAViewModel(history: .shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().overlay(Color.green.opacity(0.15))
            suggestions
            composer
        }
        .background(Theme.background)
        .navigationTitle("Ask Billify")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        bubble(message)
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

    private func bubble(_ message: QAViewModel.QAMessage) -> some View {
        HStack {
            if message.sender == .billify {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(LinearGradient(colors: [Theme.deepGreen, Theme.emerald],
                                                             startPoint: .top, endPoint: .bottom)))
            }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.sender == .user ? Theme.emerald : Theme.surface)
                .foregroundStyle(message.sender == .user ? .white : Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(message.sender == .billify ? Color.green.opacity(0.12) : .clear, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QAViewModel.suggestedQuestions, id: \.self) { question in
                    Button {
                        viewModel.ask(question)
                    } label: {
                        Text(question)
                            .font(.caption)
                            .foregroundStyle(Theme.forest)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.sage))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask about your invoices…", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.chip(false)))
                .focused($inputFocused)
                .lineLimit(1...4)
                .foregroundStyle(Theme.ink)

            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.emerald)
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }
}
