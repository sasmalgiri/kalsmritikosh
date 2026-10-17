//
//  KalsmritikoshViewerApp.swift
//  KalsmritikoshViewer
//
//  Created by Shirshendu Sasmal on 15/10/26.
//

import SwiftUI

@main
struct KalsmritikoshViewerApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                SyncLibraryView()
                    .tabItem { Label("Your archive", systemImage: "arrow.triangle.2.circlepath") }
                ContentView()
                    .tabItem { Label("Snapshot", systemImage: "archivebox") }
            }
        }
    }
}
