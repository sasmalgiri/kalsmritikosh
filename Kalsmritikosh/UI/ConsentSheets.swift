//
//  ConsentSheets.swift
//  Kalsmritikosh
//
//  The three permission sheets of the main window, as one modifier: O-5 (nothing goes online without the
//  outbound sheet), plan A (once per case, no case document goes to the AI without it) and AI-36 (once
//  per import). Moved out of KalsmritikoshApp's modifier chain, which grew past what the CI type-checker
//  (Xcode 26) resolves in time.
//

import SwiftUI

struct ConsentSheets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .sheet(item: outbound) { preview in OutboundConsentSheet(preview: preview) }
            .sheet(item: caseRead) { request in CaseReadConsentSheet(request: request) }
            .sheet(item: importAI) { request in ImportAIConsentSheet(request: request) }
            .sheet(item: archiveQuestion) { request in ArchiveQuestionConsentSheet(request: request) }
    }

    /// AI split AI-49 — once per question asked outside a case.
    private var archiveQuestion: Binding<ArchiveQuestionConsentRequest?> {
        Binding(get: { ArchiveQuestionConsent.shared.pending },
                set: { if $0 == nil, ArchiveQuestionConsent.shared.pending != nil { ArchiveQuestionConsent.shared.resolve(allow: false) } })
    }

    private var outbound: Binding<OutboundPreview?> {
        Binding(get: { OutboundConsent.shared.pending },
                set: { if $0 == nil, OutboundConsent.shared.pending != nil { OutboundConsent.shared.resolve(allow: false) } })
    }

    private var caseRead: Binding<CaseReadConsentRequest?> {
        Binding(get: { CaseReadConsent.shared.pending },
                set: { if $0 == nil, CaseReadConsent.shared.pending != nil { CaseReadConsent.shared.resolve(allow: false) } })
    }

    private var importAI: Binding<ImportAIConsentRequest?> {
        Binding(get: { ImportAIConsent.shared.pending },
                set: { if $0 == nil, ImportAIConsent.shared.pending != nil { ImportAIConsent.shared.resolve(allow: false) } })
    }
}
