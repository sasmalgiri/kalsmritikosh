//
//  OnboardingTips.swift
//  Kalsmritikosh
//
//  First-run walkthrough via Apple's TipKit. Ordered TipGroup surfaces one
//  short, actionable tip at a time in the sidebar — Add files → Ask →
//  Convert → Insights — and each disappears once the user has done it.
//  Non-intrusive, system-styled, shown-state tracked on device.
//

import SwiftUI
#if canImport(TipKit)
import TipKit
#endif

#if canImport(TipKit)
@available(macOS 15.0, *)
struct AddSourceTip: Tip {
    var title: Text { Text("Add your files") }
    var message: Text? { Text("Open Sources and add a folder. Kalsmritikosh reads everything inside — PDFs, Office docs, images, email, audio — into your private knowledge base.") }
    var image: Image? { Image(systemName: "folder.badge.plus") }
}

@available(macOS 15.0, *)
struct AskTip: Tip {
    var title: Text { Text("Ask anything") }
    var message: Text? { Text("Ask questions in plain language. Every answer is grounded in your files and shows the sources it used.") }
    var image: Image? { Image(systemName: "sparkles") }
}

@available(macOS 15.0, *)
struct ConvertTip: Tip {
    var title: Text { Text("Convert files") }
    var message: Text? { Text("Turn any file into text, PDF, Word, Excel and more — one-shot, without adding it to your knowledge base.") }
    var image: Image? { Image(systemName: "arrow.right.doc.on.clipboard") }
}

@available(macOS 15.0, *)
struct InsightsTip: Tip {
    var title: Text { Text("Find the gaps") }
    var message: Text? { Text("Insights surfaces missing documents and conflicting facts across your archive — rule-based, no LLM.") }
    var image: Image? { Image(systemName: "lightbulb.max") }
}

@available(macOS 15.0, *)
enum Onboarding {
    /// Ordered so only one tip shows at a time, advancing as each is dismissed.
    static let group = TipGroup(.ordered) {
        AddSourceTip()
        AskTip()
        ConvertTip()
        InsightsTip()
    }
}
#endif
