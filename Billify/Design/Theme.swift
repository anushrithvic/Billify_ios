//
//  Theme.swift
//  Billify
//
//  Billify's green design system. The whole app is built from a single
//  emerald/forest family so every screen reads as one product, with adaptive
//  variants that keep contrast in both light and dark mode:
//
//    forest / deepGreen   → headers, hero, primary buttons (ink)
//    emerald / jade       → interactive accents, selected states
//    mint / sage / pale   → washes, cards, backgrounds (paper)
//    cream                → text that must sit on forest
//
import SwiftUI
import UIKit

enum Theme {

    // MARK: Ink greens (dark, high contrast)

    /// Deepest green — the app's "black".
    static let deepGreen = Color(red: 0.035, green: 0.18, blue: 0.125)
    static let forest = Color(red: 0.055, green: 0.28, blue: 0.185)
    static let pine = Color(red: 0.07, green: 0.37, blue: 0.245)

    // MARK: Action greens (mid)

    static let emerald = Color(red: 0.10, green: 0.62, blue: 0.42)
    static let jade = Color(red: 0.16, green: 0.74, blue: 0.52)

    // MARK: Paper greens (light)

    static let mint = Color(red: 0.52, green: 0.83, blue: 0.68)
    static let sage = Color(red: 0.90, green: 0.95, blue: 0.90)
    static let pale = Color(red: 0.965, green: 0.985, blue: 0.965)

    // MARK: Support colours

    /// Warm off-white used for text/accents on dark greens.
    static let cream = Color(red: 0.985, green: 0.97, blue: 0.90)

    // MARK: Adaptive surfaces

    /// Page background — light sage paper by day, near-black green at night.
    static let background = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.075, blue: 0.06, alpha: 1)
            : UIColor(red: 0.945, green: 0.97, blue: 0.945, alpha: 1)
    })

    /// Card / sheet surface.
    static let surface = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.14, blue: 0.11, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })

    /// Primary text colour (adaptive).
    static let ink = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.90, green: 0.95, blue: 0.92, alpha: 1)
            : UIColor(red: 0.05, green: 0.16, blue: 0.12, alpha: 1)
    })

    /// Subtle text (adaptive).
    static let inkSoft = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.68, green: 0.78, blue: 0.73, alpha: 1)
            : UIColor(red: 0.30, green: 0.42, blue: 0.36, alpha: 1)
    })

    /// The app-wide accent — everything interactive picks this up via .tint().
    static let accent = jade

    // MARK: Gradients

    /// Hero band behind the home header.
    static let heroGradient = LinearGradient(
        colors: [deepGreen, forest, pine],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Card gradient accents — one per document type so cards feel distinct
    /// while staying inside the green family.
    static func cardGradient(_ tone: CardTone) -> LinearGradient {
        switch tone {
        case .tax: return LinearGradient(colors: [forest, emerald], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .credit: return LinearGradient(colors: [pine, jade], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .debit: return LinearGradient(colors: [deepGreen, pine], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .delivery: return LinearGradient(colors: [emerald, mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .history: return LinearGradient(colors: [forest, pine], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ask: return LinearGradient(colors: [deepGreen, jade], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    enum CardTone {
        case tax, credit, debit, delivery, history, ask
    }

    // MARK: Helpers

    /// Capsule-shaped secondary control on a green background (e.g. quick chips).
    static func chip(_ active: Bool) -> Color {
        active ? emerald : Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.22, blue: 0.17, alpha: 1)
                : UIColor(red: 0.88, green: 0.94, blue: 0.89, alpha: 1)
        })
    }
}

/// Rounded-rectangle card surface with a soft green-tinted shadow — used by
/// every list row / summary card so they share one look.
struct GreenCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.green.opacity(0.10), lineWidth: 1))
            .shadow(color: Color.green.opacity(0.10), radius: 6, x: 0, y: 2)
    }
}
