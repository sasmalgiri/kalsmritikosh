//
//  AppLockOverlay.swift
//  Kalsmritikosh
//
//  W2-7 — while locked, cover the whole window with the unlock screen.
//

import SwiftUI

struct AppLockOverlay: ViewModifier {
    @State private var lock = AppLock.shared

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: lock.locked ? 24 : 0)
                .allowsHitTesting(!lock.locked)
            if lock.locked {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").scaledFont(40, relativeTo: .largeTitle).foregroundStyle(.secondary)
                    Text("Investigations Made Easy is locked").font(.title2.bold())
                    Button("Unlock") { Task { await lock.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    if let e = lock.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .task { lock.start() }
    }
}

extension View {
    func appLockOverlay() -> some View { modifier(AppLockOverlay()) }
}
