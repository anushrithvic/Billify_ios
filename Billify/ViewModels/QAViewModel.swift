//
//  QAViewModel.swift
//  Billify
//
//  Transcript + routing for the "Ask Billify" assistant. Answers come from
//  InvoiceQAEngine over the saved invoice history.
//

import Foundation
import Combine

@MainActor
final class QAViewModel: ObservableObject {

    struct QAMessage: Identifiable, Equatable {
        enum Sender: Equatable { case user, billify }
        let id: UUID = UUID()
        let sender: Sender
        let text: String
    }

    /// Questions worth offering as one-tap chips on the QA screen.
    static let suggestedQuestions = [
        "How many invoices have I made?",
        "Who are my customers?",
        "How much have I billed in total?",
        "What should my next invoice number be?"
    ]

    @Published private(set) var messages: [QAMessage] = []
    @Published var inputText: String = ""

    private let history: InvoiceHistoryStore

    init(history: InvoiceHistoryStore) {
        self.history = history
        messages.append(QAMessage(sender: .billify, text: InvoiceQAEngine.helpText))
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(QAMessage(sender: .user, text: text))
        inputText = ""

        let answer = InvoiceQAEngine.answer(text, entries: history.entries)
        messages.append(QAMessage(sender: .billify, text: answer))
    }

    func ask(_ question: String) {
        inputText = ""
        messages.append(QAMessage(sender: .user, text: question))
        let answer = InvoiceQAEngine.answer(question, entries: history.entries)
        messages.append(QAMessage(sender: .billify, text: answer))
    }
}
