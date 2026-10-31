//
//  AppPrinting.swift
//  Kalsmritikosh
//
//  UI journey run d (2026-10-30, D-5): the sandboxed app has no `com.apple.security.print`
//  entitlement, so `NSPrintOperation.run()` is refused by macOS with its own alert and the app then
//  called that a user cancel. Every Print button goes through here: when the process is not entitled
//  to print, the person is told so plainly (export the file, print it elsewhere) and nothing is
//  recorded; when it is, the same frozen text is printed and the outcome reported truthfully.
//  Whether to add the print entitlement is the owner's decision (recorded in the owner action sheet).
//

import Foundation
#if os(macOS)
import AppKit
import Security
#endif

@MainActor
enum AppPrinting {
    enum Outcome: Equatable { case printed, cancelled, notAvailable }

    static let unavailableMessage = "Printing is not available in this build: the app is not entitled to print from the sandbox. Export the document and print it from another app. Nothing was recorded."

    /// True when this process may print: not sandboxed, or sandboxed with the print entitlement.
    static let isEntitled: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let sandboxed = (SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool) ?? false
        guard sandboxed else { return true }
        return (SecTaskCopyValueForEntitlement(task, "com.apple.security.print" as CFString, nil) as? Bool) ?? false
        #else
        return false
        #endif
    }()

    /// Print `text` through the system print dialog. Returns what happened; the caller records a
    /// release only for `.printed`.
    @discardableResult
    static func run(text: String, jobTitle: String, monospace: Bool = true, fontSize: CGFloat = 9) -> Outcome {
        #if os(macOS)
        guard isEntitled else {
            let alert = NSAlert()
            alert.messageText = "Printing is not available"
            alert.informativeText = unavailableMessage
            alert.runModal()
            return .notAvailable
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        view.string = text
        view.font = monospace ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize + 2)
        let op = NSPrintOperation(view: view)
        op.jobTitle = jobTitle
        return op.run() ? .printed : .cancelled
        #else
        return .notAvailable
        #endif
    }
}
